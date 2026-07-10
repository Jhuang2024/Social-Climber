import Foundation
import SwiftData

@Model
final class Person {
    /// Stable identity independent of SwiftData's internal
    /// `persistentModelID` (which isn't portable across export/backup
    /// restore). Capture provenance (`CapturedMemory`/`MemoryFact` person
    /// links) is keyed by this, not by name, so a rename after a capture is
    /// made but before it's processed can never break attribution.
    var uuid: UUID = UUID()
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
    // call on its own; regeneration only happens when the user explicitly
    // taps refresh.

    /// Suggestions from the last "Suggest with AI" run. Regenerated only on
    /// explicit refresh, same pattern as `contactMethods` below.
    var cachedGiftSuggestions: [GiftSuggestion] = []
    var cachedGiftSuggestionsGeneratedAt: Date?

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
    /// Evidence-linked facts learned automatically from captures. Kept
    /// separate from the manually-entered fields above (interests, notes,
    /// schoolOrWork…) so automatic extraction never overwrites what the
    /// user typed; profile display and AI context merge the two.
    @Relationship(deleteRule: .cascade, inverse: \MemoryFact.person)
    var memoryFacts: [MemoryFact] = []

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

    /// Whether anything new (an interaction, a profile edit) has happened
    /// since a given cached-insight timestamp, so the AI summary and gift
    /// suggestion caches can flag themselves as "may be outdated" instead of
    /// silently going stale forever between explicit refreshes.
    private func hasNewActivity(since generatedAt: Date?) -> Bool {
        guard let generatedAt else { return false }
        if let latestInteraction = sortedInteractions.first?.date, latestInteraction > generatedAt { return true }
        return updatedAt > generatedAt
    }

    /// True once a new interaction or profile edit has landed since the
    /// cached AI summary was generated.
    var aiSummaryIsStale: Bool { hasNewActivity(since: aiSummaryGeneratedAt) }

    /// True once a new interaction or profile edit has landed since gift
    /// suggestions were last generated.
    var giftSuggestionsAreStale: Bool { hasNewActivity(since: cachedGiftSuggestionsGeneratedAt) }

    /// Update the relevant "last..." fields for an interaction of the given type.
    /// Only ever nudges forward: correct for logging a brand-new
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
    /// currently-logged interaction, from scratch, unlike `markContacted`,
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

    /// Visible (active/suggested) automatic facts of a given type, newest first.
    func facts(of type: MemoryFactType) -> [MemoryFact] {
        memoryFacts
            .filter { $0.type == type && $0.isVisible }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Visible automatic facts of every type, newest first.
    var visibleFacts: [MemoryFact] {
        memoryFacts.filter(\.isVisible).sorted { $0.createdAt > $1.createdAt }
    }

    /// Manually-entered interests merged with active learned interests,
    /// deduplicated case-insensitively. Used by profile display, search,
    /// gift suggestions, and AI context.
    var combinedInterests: [String] {
        var merged = interests
        for fact in facts(of: .interest) where fact.status == .active {
            if !merged.contains(where: { $0.caseInsensitiveCompare(fact.value) == .orderedSame }) {
                merged.append(fact.value)
            }
        }
        return merged
    }

    /// Manually-entered dislikes merged with active learned dislikes.
    var combinedDislikes: [String] {
        var merged = dislikes
        for fact in facts(of: .dislike) where fact.status == .active {
            if !merged.contains(where: { $0.caseInsensitiveCompare(fact.value) == .orderedSame }) {
                merged.append(fact.value)
            }
        }
        return merged
    }

    func addInterests(_ new: [String]) {
        for item in new where !interests.contains(where: { $0.caseInsensitiveCompare(item) == .orderedSame }) {
            interests.append(item)
        }
    }

    /// Broad substring search across everything a person could plausibly be
    /// found by: name, tags, interests, notes, and more, not just their
    /// name. Shared by the People list's own search bar and the global
    /// Search tab so a person findable one way is findable the other.
    func matchesSearch(_ term: String) -> Bool {
        guard !term.isEmpty else { return true }
        if name.localizedCaseInsensitiveContains(term)
            || nickname.localizedCaseInsensitiveContains(term)
            || relationshipToMe.localizedCaseInsensitiveContains(term)
            || notes.localizedCaseInsensitiveContains(term)
            || personalityNotes.localizedCaseInsensitiveContains(term)
            || schoolOrWork.localizedCaseInsensitiveContains(term)
            || location.localizedCaseInsensitiveContains(term) {
            return true
        }
        return tags.contains { $0.localizedCaseInsensitiveContains(term) }
            || interests.contains { $0.localizedCaseInsensitiveContains(term) }
            || dislikes.contains { $0.localizedCaseInsensitiveContains(term) }
            || memoryFacts.contains { $0.isVisible && $0.value.localizedCaseInsensitiveContains(term) }
    }
}
