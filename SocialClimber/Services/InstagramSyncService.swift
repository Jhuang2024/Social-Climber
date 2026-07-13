import Foundation
import SwiftData

/// Orchestrates one Instagram sync: pulls the newest export zip(s) from
/// Google Drive, parses followers/following and message threads, records a
/// follower snapshot + follow/unfollow events immediately (they're plain
/// facts), and returns message-thread candidates for the user to review
/// before anything touches People or the timeline.
@MainActor
@Observable
final class InstagramSyncService {
    static let shared = InstagramSyncService()

    nonisolated static let folderDefaultsKey = "instagramDriveFolder"
    nonisolated static let lastSyncDefaultsKey = "instagramLastSyncAt"
    /// With no previous sync, only messages from the last N days are
    /// offered — a first sync shouldn't dump years of DM history into the
    /// review sheet.
    private static let firstSyncWindowDays = 30
    /// Snapshots beyond this count are pruned oldest-first; events derived
    /// from them are kept forever.
    private static let maxSnapshots = 60

    private(set) var isSyncing = false
    private(set) var progressText = ""

    private init() {}

    var lastSyncAt: Date? {
        let raw = UserDefaults.standard.double(forKey: Self.lastSyncDefaultsKey)
        return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
    }

    // MARK: Result types

    /// One conversation found in the export with messages newer than the
    /// last sync, waiting for user review. `matchedPerson` is the app's
    /// best guess; the review sheet lets the user change or clear it.
    struct ThreadCandidate: Identifiable {
        let id = UUID()
        let title: String
        /// The other participant's name (empty for unmatched group chats).
        let otherParticipant: String
        let messages: [InstagramExportParser.Message]
        var matchedPerson: Person?

        var latestDate: Date { messages.map(\.date).max() ?? .now }

        /// The conversation rendered as plain "Name: text" lines — what
        /// gets AI-extracted and stored as the interaction's raw import
        /// text, same shape as a pasted chat.
        var digestText: String {
            messages.map { "\($0.sender): \($0.text)" }.joined(separator: "\n")
        }
    }

    struct SyncResult {
        var newFollowers: [String] = []
        var lostFollowers: [String] = []
        var threads: [ThreadCandidate] = []
        var followerCount = 0
        var followingCount = 0
        /// True when the export contained no follower lists (e.g. the
        /// scheduled export was configured to include only messages).
        var hadFollowerData = false
    }

    // MARK: Sync

    func sync(people: [Person], context: ModelContext) async throws -> SyncResult {
        guard !isSyncing else { throw GoogleDriveError.requestFailed }
        isSyncing = true
        defer { isSyncing = false; progressText = "" }

        progressText = "Looking for the latest export in Drive…"
        let folderName = UserDefaults.standard.string(forKey: Self.folderDefaultsKey) ?? ""
        let files = try await GoogleDriveService.shared.latestInstagramExportFiles(folderName: folderName)
        guard !files.isEmpty else { throw GoogleDriveError.noExportFound }

        var localURLs: [URL] = []
        defer { for url in localURLs { try? FileManager.default.removeItem(at: url) } }
        for (index, file) in files.enumerated() {
            progressText = "Downloading export (\(index + 1) of \(files.count))…"
            localURLs.append(try await GoogleDriveService.shared.downloadToTemporaryFile(fileID: file.id))
        }

        // Unzipping and JSON parsing are CPU-bound — keep them off the main
        // actor so the UI stays responsive during a big export.
        progressText = "Reading export…"
        let urls = localURLs
        let export = try await Task.detached(priority: .userInitiated) {
            var export = InstagramExportParser.Export()
            for url in urls {
                let reader = try ZipArchiveReader(url: url)
                defer { reader.close() }
                for entry in reader.entries where InstagramExportParser.isRelevantEntry(entry.name) {
                    guard let data = try? reader.data(for: entry) else { continue }
                    InstagramExportParser.ingest(path: entry.name, data: data, into: &export)
                }
            }
            return export
        }.value

        progressText = "Comparing followers…"
        var result = SyncResult()
        applyFollowerDiff(export: export, into: &result, context: context)

        progressText = "Collecting new messages…"
        buildThreadCandidates(export: export, people: people, into: &result)

        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: Self.lastSyncDefaultsKey)
        try? context.save()
        return result
    }

    // MARK: Follower diff

    private func applyFollowerDiff(export: InstagramExportParser.Export, into result: inout SyncResult, context: ModelContext) {
        let followers = Set(export.followerLists.followers)
        let following = Set(export.followerLists.following)
        guard !followers.isEmpty || !following.isEmpty else { return }
        result.hadFollowerData = true
        result.followerCount = followers.count
        result.followingCount = following.count

        let previous = (try? context.fetch(
            FetchDescriptor<FollowerSnapshot>(sortBy: [SortDescriptor(\.takenAt, order: .reverse)])
        )) ?? []

        if let last = previous.first {
            let lastFollowers = Set(last.followerUsernames)
            let lastFollowing = Set(last.followingUsernames)
            let gained = followers.subtracting(lastFollowers).sorted()
            let lost = lastFollowers.subtracting(followers).sorted()
            let startedFollowing = following.subtracting(lastFollowing).sorted()
            let stoppedFollowing = lastFollowing.subtracting(following).sorted()

            result.newFollowers = gained
            result.lostFollowers = lost
            for username in gained { context.insert(FollowerEvent(username: username, kind: .gainedFollower)) }
            for username in lost { context.insert(FollowerEvent(username: username, kind: .lostFollower)) }
            for username in startedFollowing { context.insert(FollowerEvent(username: username, kind: .startedFollowing)) }
            for username in stoppedFollowing { context.insert(FollowerEvent(username: username, kind: .stoppedFollowing)) }
        }

        context.insert(FollowerSnapshot(
            followerUsernames: followers.sorted(),
            followingUsernames: following.sorted()
        ))

        // Prune oldest snapshots beyond the cap (events derived from them
        // stay — they're the durable history).
        let excess = previous.count + 1 - Self.maxSnapshots
        if excess > 0 {
            for snapshot in previous.suffix(excess) {
                context.delete(snapshot)
            }
        }
    }

    // MARK: Thread candidates

    private func buildThreadCandidates(export: InstagramExportParser.Export, people: [Person], into result: inout SyncResult) {
        let cutoff = lastSyncAt
            ?? Calendar.current.date(byAdding: .day, value: -Self.firstSyncWindowDays, to: .now)
            ?? .distantPast
        let owner = export.ownerName

        for thread in export.threads {
            let fresh = thread.messages.filter { $0.date > cutoff }
            guard !fresh.isEmpty else { continue }
            // Skip threads where the only new activity is the owner talking
            // to themselves (notes-to-self threads exist).
            let others = Set(thread.participants).subtracting([owner].compactMap { $0 })
            let otherParticipant = others.count == 1 ? (others.first ?? "") : ""
            let displayTitle = thread.title.isEmpty ? (otherParticipant.isEmpty ? "Group chat" : otherParticipant) : thread.title

            result.threads.append(ThreadCandidate(
                title: displayTitle,
                otherParticipant: otherParticipant,
                messages: fresh,
                matchedPerson: match(nameOrUsername: otherParticipant.isEmpty ? displayTitle : otherParticipant, people: people)
            ))
        }
        result.threads.sort { $0.latestDate > $1.latestDate }
    }

    /// Best-effort match of an export participant to an existing Person:
    /// explicit Instagram username first, then an "Instagram" contact
    /// method, then plain name/nickname equality.
    func match(nameOrUsername: String, people: [Person]) -> Person? {
        let needle = normalize(nameOrUsername)
        guard !needle.isEmpty else { return nil }
        if let byUsername = people.first(where: { normalize($0.instagramUsername) == needle }) {
            return byUsername
        }
        if let byContactMethod = people.first(where: { person in
            person.contactMethods.contains {
                $0.label.localizedCaseInsensitiveContains("instagram") && normalize($0.value) == needle
            }
        }) {
            return byContactMethod
        }
        return people.first {
            normalize($0.name) == needle || (!$0.nickname.isEmpty && normalize($0.nickname) == needle)
        }
    }

    private func normalize(_ value: String) -> String {
        value.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
    }

    // MARK: Apply

    /// Applies one approved thread candidate: runs the conversation through
    /// the same extraction pipeline voice notes use, logs an imported
    /// Instagram interaction, updates the person's profile, and remembers
    /// the person's Instagram identity for future syncs.
    func apply(candidate: ThreadCandidate, to person: Person, context: ModelContext) async {
        let digest = candidate.digestText
        let outcome = await AIExtractionCoordinator.extract(
            from: digest,
            knownPeople: [person.displayName]
        )
        let interaction = ExtractionApplier.apply(
            outcome.extraction,
            to: [person],
            sourceText: digest,
            interactionType: .socialMedia,
            date: candidate.latestDate,
            quality: 3,
            options: .allApproved(for: outcome.extraction),
            context: context
        )
        interaction?.isImported = true
        interaction?.platform = .instagram
        interaction?.rawImportText = digest

        if person.instagramUsername.isEmpty, !candidate.otherParticipant.isEmpty {
            // Thread participants are display names, not handles — only
            // store it when it looks like a handle (no spaces).
            let normalized = normalize(candidate.otherParticipant)
            if !normalized.contains(" ") {
                person.instagramUsername = normalized
            }
        }
    }
}
