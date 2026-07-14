import Foundation

/// Parses the JSON files inside an Instagram "Download Your Information"
/// export: message threads, followers, and following lists. Pure and
/// stateless: bytes in, DTOs out. Nothing here touches SwiftData or the
/// network.
enum InstagramExportParser {

    // MARK: DTOs

    struct Message {
        let sender: String
        let date: Date
        let text: String
    }

    struct Thread {
        /// Thread title as Instagram exported it, usually the other
        /// person's display name for DMs, or a group chat name.
        let title: String
        let participants: [String]
        let messages: [Message]
    }

    struct FollowerLists {
        var followers: [String] = []
        var following: [String] = []
        var followerFiles: Set<String> = []
        var followingFiles: Set<String> = []
    }

    struct Export {
        var threads: [Thread] = []
        var followerLists = FollowerLists()

        /// The export owner's display name, inferred as the participant who
        /// appears in the most threads (the owner is in every DM thread by
        /// definition; no single JSON file reliably carries this).
        var ownerName: String? {
            var counts: [String: Int] = [:]
            for thread in threads {
                for participant in Set(thread.participants) {
                    counts[participant, default: 0] += 1
                }
            }
            guard threads.count >= 2 else { return nil }
            return counts.filter { $0.value >= max(2, threads.count / 2) }
                .max { $0.value < $1.value }?.key
        }
    }

    // MARK: Entry routing

    /// Whether a zip entry path is one this parser wants. Path prefixes
    /// changed across export format versions ("messages/inbox/..." vs
    /// "your_instagram_activity/messages/inbox/..."), so match on stable
    /// fragments instead of full paths.
    static func isRelevantEntry(_ path: String) -> Bool {
        let lower = path.lowercased()
        guard lower.hasSuffix(".json") else { return false }
        if lower.contains("/inbox/") && lower.contains("message_") { return true }
        if lower.contains("followers_and_following/") {
            let file = (lower as NSString).lastPathComponent
            return file.hasPrefix("followers") || file.hasPrefix("following")
        }
        return false
    }

    /// Folds one relevant JSON file into the export being assembled.
    static func ingest(path: String, data: Data, into export: inout Export) {
        let lower = path.lowercased()
        let file = (lower as NSString).lastPathComponent
        if lower.contains("/inbox/") && file.hasPrefix("message_") {
            if let thread = parseThread(data) {
                export.threads.append(thread)
            }
        } else if file.hasPrefix("followers") {
            export.followerLists.followers.append(contentsOf: parseUsernameList(data, arrayKey: nil))
            export.followerLists.followerFiles.insert(lower)
        } else if file.hasPrefix("following") {
            export.followerLists.following.append(contentsOf: parseUsernameList(data, arrayKey: "relationships_following"))
            export.followerLists.followingFiles.insert(lower)
        }
    }

    // MARK: Messages

    private struct WireThread: Decodable {
        struct Participant: Decodable { let name: String }
        struct WireMessage: Decodable {
            let sender_name: String?
            let timestamp_ms: Double?
            let content: String?
        }

        let title: String?
        let participants: [Participant]?
        let messages: [WireMessage]?
    }

    static func parseThread(_ data: Data) -> Thread? {
        guard let wire = try? JSONDecoder().decode(WireThread.self, from: data) else { return nil }
        let participants = (wire.participants ?? []).map { fixMojibake($0.name) }
        let messages: [Message] = (wire.messages ?? []).compactMap { message in
            guard let sender = message.sender_name,
                  let timestamp = message.timestamp_ms,
                  let content = message.content, !content.isEmpty else { return nil }
            let text = fixMojibake(content)
            // Instagram represents likes/reactions and "sent an attachment"
            // as content too; skip the pure-noise ones.
            if text.hasSuffix("sent an attachment.") || text.hasSuffix("to your message") { return nil }
            return Message(
                sender: fixMojibake(sender),
                date: Date(timeIntervalSince1970: timestamp / 1000),
                text: text
            )
        }
        guard !messages.isEmpty || !participants.isEmpty else { return nil }
        return Thread(
            title: fixMojibake(wire.title ?? ""),
            participants: participants,
            messages: messages.sorted { $0.date < $1.date }
        )
    }

    // MARK: Followers / following

    private struct WireRelationship: Decodable {
        struct StringListItem: Decodable {
            let value: String?
            let timestamp: Double?
        }
        let string_list_data: [StringListItem]?
    }

    /// `followers_N.json` is normally a bare array while `following.json`
    /// normally wraps it under `relationships_following`. Meta has shipped
    /// both shapes for both lists, so accept the requested wrapper, the two
    /// known relationship wrappers, or a bare array. Also flatten every
    /// `string_list_data` item: assuming one item per relationship silently
    /// under-counts exports that group several usernames in one object.
    static func parseUsernameList(_ data: Data, arrayKey: String?) -> [String] {
        let relationships: [WireRelationship]
        if let decoded = try? JSONDecoder().decode([WireRelationship].self, from: data) {
            relationships = decoded
        } else if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let keys = [arrayKey, "relationships_followers", "relationships_following"].compactMap { $0 }
            guard let rawArray = keys.compactMap({ object[$0] }).first,
                  let arrayData = try? JSONSerialization.data(withJSONObject: rawArray),
                  let decoded = try? JSONDecoder().decode([WireRelationship].self, from: arrayData) else { return [] }
            relationships = decoded
        } else {
            return []
        }
        return Array(Set(relationships.flatMap { relationship in
            (relationship.string_list_data ?? []).compactMap(\.value)
        }
            .map { fixMojibake($0).lowercased() }
            .filter { !$0.isEmpty }))
    }

    // MARK: Encoding fix

    /// Meta's export writes JSON with UTF-8 bytes escaped as if they were
    /// Latin-1 code points ("CafÃ©" instead of "Café"). If every
    /// scalar fits in a byte and those bytes form valid UTF-8, reinterpret;
    /// otherwise the string was fine as-is.
    static func fixMojibake(_ string: String) -> String {
        guard string.unicodeScalars.contains(where: { $0.value > 0x7F }) else { return string }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(string.unicodeScalars.count)
        for scalar in string.unicodeScalars {
            guard scalar.value <= 0xFF else { return string }
            bytes.append(UInt8(scalar.value))
        }
        return String(bytes: bytes, encoding: .utf8) ?? string
    }
}
