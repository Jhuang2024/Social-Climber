import Foundation
import SwiftData

@Model
final class Interaction {
    var typeRaw: String = InteractionType.inPerson.rawValue
    var date: Date = Date()
    var location: String = ""
    var note: String = ""
    var topics: [String] = []
    var quality: Int = 3
    var followUpNeeded: Bool = false
    var createdAt: Date = Date()

    var people: [Person] = []

    @Relationship(deleteRule: .cascade, inverse: \ConversationSummary.interaction)
    var aiSummary: ConversationSummary?

    init(
        type: InteractionType = .inPerson,
        date: Date = .now,
        location: String = "",
        note: String = "",
        topics: [String] = [],
        quality: Int = 3,
        followUpNeeded: Bool = false
    ) {
        self.typeRaw = type.rawValue
        self.date = date
        self.location = location
        self.note = note
        self.topics = topics
        self.quality = quality
        self.followUpNeeded = followUpNeeded
        self.createdAt = .now
    }

    var type: InteractionType {
        get { InteractionType(rawValue: typeRaw) ?? .other }
        set { typeRaw = newValue.rawValue }
    }

    var peopleNames: String {
        people.map(\.firstName).joined(separator: ", ")
    }
}
