import Foundation
import SwiftData

@Model
final class Person {
    var name: String = ""
    var nickname: String = ""
    var relationshipToMe: String = ""
    var categoryRaw: String = PersonCategory.friend.rawValue
    var closeness: Int = 3
    var priority: Int = 3
    var birthday: Date?
    var lastContactedAt: Date?
    var lastMetAt: Date?
    var lastMessagedAt: Date?
    var lastCalledAt: Date?
    var isArchived: Bool = false
    var checkInCadenceDays: Int?
    var notes: String = ""
    var personalityNotes: String = ""
    var interests: [String] = []
    var dislikes: [String] = []
    var familyMembers: [String] = []
    var schoolOrWork: String = ""
    var location: String = ""
    var contactMethods: [ContactMethod] = []
    var tags: [String] = []
    @Attribute(.externalStorage) var avatarData: Data?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    // MARK: AI feature caches
    // Both caches persist so re-opening a contact never re-triggers an API
    // call on its own — regeneration only happens when the user explicitly
    // taps refresh.

    /// Suggestions from the last "Suggest with AI" run. Regenerated only on
    /// explicit refresh, same pattern as `contactMethods` below.
    var cachedGiftSuggestions: [GiftSuggestion] = []

    /// The last generated relationship summary (AI-written, or the
    /// deterministic local fallback when AI is unavailable/unconfigured).
    var cachedAISummary: String = ""
    var aiSummaryGeneratedAt: Date?
    /// True when `cachedAISummary` is the deterministic local fallback
    /// rather than a real AI-generated summary.
    var aiSummaryIsFallback: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \GiftIdea.person)
    var giftIdeas: [GiftIdea] = []
    @Relationship(deleteRule: .cascade, inverse: \Reminder.person)
    var reminders: [Reminder] = []
    @Relationship(deleteRule: .cascade, inverse: \ImportantDate.person)
    var importantDates: [ImportantDate] = []
    @Relationship(deleteRule: .nullify, inverse: \Interaction.people)
    var interactions: [Interaction] = []
    @Relationship(deleteRule: .nullify, inverse: \Event.attendees)
    var events: [Event] = []
    @Relationship(deleteRule: .nullify, inverse: \VoiceNote.people)
    var voiceNotes: [VoiceNote] = []

    init(
        name: String,
        nickname: String = "",
        relationshipToMe: String = "",
        category: PersonCategory = .friend,
        closeness: Int = 3,
        priority: Int = 3,
        birthday: Date? = nil
    ) {
        self.name = name
        self.nickname = nickname
        self.relationshipToMe = relationshipToMe
        self.categoryRaw = category.rawValue
        self.closeness = closeness
        self.priority = priority
        self.birthday = birthday
        self.createdAt = .now
        self.updatedAt = .now
    }

    var category: PersonCategory {
        get { PersonCategory(rawValue: categoryRaw) ?? .friend }
        set { categoryRaw = newValue.rawValue }
    }

    var displayName: String { name.isEmpty ? nickname : name }

    var firstName: String { name.components(separatedBy: " ").first ?? name }

    var status: RelationshipStatus { RelationshipHealth.status(for: self) }

    var nextBirthday: Date? { birthday?.nextYearlyOccurrence }

    var sortedInteractions: [Interaction] {
        interactions.sorted { $0.date > $1.date }
    }

    var openReminders: [Reminder] {
        reminders.filter { !$0.completed }.sorted { $0.dueDate < $1.dueDate }
    }

    var openGiftIdeas: [GiftIdea] {
        giftIdeas.filter { $0.status != .given }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Update the relevant "last..." fields for an interaction of the given type.
    /// Only ever nudges forward — correct for logging a brand-new
    /// interaction, but can't walk a field backward or drop it if the
    /// interaction responsible for the current value is later edited or
    /// deleted. Use `recomputeContactDates()` for those cases.
    func markContacted(type: InteractionType, date: Date) {
        if lastContactedAt == nil || date > lastContactedAt! { lastContactedAt = date }
        switch type {
        case .inPerson, .event:
            if lastMetAt == nil || date > lastMetAt! { lastMetAt = date }
        case .call, .videoCall:
            if lastCalledAt == nil || date > lastCalledAt! { lastCalledAt = date }
        case .message, .socialMedia, .email:
            if lastMessagedAt == nil || date > lastMessagedAt! { lastMessagedAt = date }
        case .favor, .intro, .voiceNote, .other:
            break
        }
        updatedAt = .now
    }

    /// Recomputes the "last contacted" family of fields from every
    /// currently-logged interaction, from scratch — unlike `markContacted`,
    /// this can also move a field *earlier* or clear it entirely. Call this
    /// (instead of `markContacted`) whenever an existing interaction's date
    /// or type changes, or an interaction is deleted, so the People list's
    /// "last contacted" display and status badge never keep pointing at an
    /// interaction that no longer supports that date.
    func recomputeContactDates() {
        lastContactedAt = interactions.map(\.date).max()
        lastMetAt = interactions.filter { $0.type == .inPerson || $0.type == .event }.map(\.date).max()
        lastCalledAt = interactions.filter { $0.type == .call || $0.type == .videoCall }.map(\.date).max()
        lastMessagedAt = interactions.filter { $0.type == .message || $0.type == .socialMedia || $0.type == .email }.map(\.date).max()
        updatedAt = .now
    }

    /// Applies a closeness delta (from `ClosenessScoring`), clamped to the
    /// 1...5 scale. Pass a negative delta to undo a previously-applied one
    /// (e.g. when an interaction is edited or deleted) so the score never
    /// drifts out of sync with what's actually on the timeline.
    @discardableResult
    func adjustCloseness(by delta: Int) -> Int {
        guard delta != 0 else { return 0 }
        let before = closeness
        closeness = min(5, max(1, closeness + delta))
        return closeness - before
    }

    func addInterests(_ new: [String]) {
        for item in new where !interests.contains(where: { $0.caseInsensitiveCompare(item) == .orderedSame }) {
            interests.append(item)
        }
    }
}
