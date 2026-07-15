import Foundation

/// One attributed line of a recorded conversation: who said it and what they
/// said. On-device speech recognition produces no speaker labels, so this is
/// inferred by the AI from the transcript given the known participants (the
/// people you picked before recording, plus you, the narrator). It's a
/// best-effort reading aid for understanding "who said what", never a source of
/// facts on its own; attribution of facts to people still flows through
/// `attributedFacts`.
struct ConversationLine: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    /// The speaker's display name: a picked participant's name, or "Me" for the
    /// narrator. Kept as free text so an unrecognised speaker degrades to a
    /// plain label rather than being dropped.
    var speaker: String
    var text: String

    init(id: UUID = UUID(), speaker: String, text: String) {
        self.id = id
        self.speaker = speaker
        self.text = text
    }

    enum CodingKeys: String, CodingKey { case id, speaker, text }

    /// Decodes defensively: AI/cached payloads won't carry an `id`, so one is
    /// generated, and either field may be missing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        speaker = (try? c.decode(String.self, forKey: .speaker)) ?? ""
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
    }

    /// True for a line the narrator (the app's user) spoke.
    var isNarrator: Bool {
        let s = speaker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return s == "me" || s == "i" || s == "narrator"
    }
}
