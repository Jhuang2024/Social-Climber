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

    /// Nudges closeness based on how an interaction went: bad interactions
    /// erode it, neutral ones leave it alone, good/great ones build it.
    /// Clamped to the 1...5 scale.
    func applyInteractionQuality(_ quality: Int) {
        let delta: Int
        switch quality {
        case ..<3: delta = -1
        case 3: delta = 0
        default: delta = 1
        }
        guard delta != 0 else { return }
        closeness = min(5, max(1, closeness + delta))
    }

    func addInterests(_ new: [String]) {
        for item in new where !interests.contains(where: { $0.caseInsensitiveCompare(item) == .orderedSame }) {
            interests.append(item)
        }
    }
}
