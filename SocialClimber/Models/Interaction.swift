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
    /// Optional explicit follow-up date. When set alongside `followUpNeeded`,
    /// the follow-up reminder is scheduled for this date instead of a default.
    var followUpDate: Date?
    /// The concrete "next move" the user plans to make with this person.
    var nextMove: String = ""
    /// A short, human-written or auto-generated summary of what was said —
    /// used for imported messages and quick timeline previews.
    var messageSummary: String = ""
    var createdAt: Date = Date()

    /// The closeness delta actually applied to each attached person when
    /// this interaction was saved, keyed by the person's stable
    /// `persistentModelID` (never a name — names are user-editable, so a
    /// rename would silently break the lookup and leave a permanent "ghost"
    /// adjustment behind). Tracked per-person, rather than as one shared
    /// number, because `Person.adjustCloseness` clamps to 1...5 — two
    /// attendees can absorb the same nominal delta differently if one was
    /// already near the ceiling/floor. Editing or deleting the interaction
    /// reverses exactly what was applied to each person instead of guessing
    /// from the current quality value.
    var appliedClosenessDeltasData: Data?

    // MARK: Imported-message metadata

    /// True when this interaction was created from an imported chat/message.
    var isImported: Bool = false
    /// Platform the message came from (empty when not an import).
    var platformRaw: String = ""
    /// The raw, unedited text captured from paste or OCR. Preserved verbatim.
    var rawImportText: String = ""

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
        followUpNeeded: Bool = false,
        followUpDate: Date? = nil,
        nextMove: String = "",
        messageSummary: String = ""
    ) {
        self.typeRaw = type.rawValue
        self.date = date
        self.location = location
        self.note = note
        self.topics = topics
        self.quality = quality
        self.followUpNeeded = followUpNeeded
        self.followUpDate = followUpDate
        self.nextMove = nextMove
        self.messageSummary = messageSummary
        self.createdAt = .now
    }

    var type: InteractionType {
        get { InteractionType(rawValue: typeRaw) ?? .other }
        set { typeRaw = newValue.rawValue }
    }

    /// Four-level sentiment, backed by the 1–5 `quality` value.
    var sentiment: Sentiment {
        get { Sentiment(quality: quality) }
        set { quality = newValue.quality }
    }

    var platform: MessagePlatform? {
        get { platformRaw.isEmpty ? nil : MessagePlatform(rawValue: platformRaw) }
        set { platformRaw = newValue?.rawValue ?? "" }
    }

    var peopleNames: String {
        people.map(\.firstName).joined(separator: ", ")
    }

    /// Best single-line preview: summary if present, else the note.
    var preview: String {
        messageSummary.isEmpty ? note : messageSummary
    }

    /// Decoded view of `appliedClosenessDeltasData`.
    var appliedClosenessDeltas: [PersistentIdentifier: Int] {
        get {
            guard let appliedClosenessDeltasData else { return [:] }
            return (try? JSONDecoder().decode([PersistentIdentifier: Int].self, from: appliedClosenessDeltasData)) ?? [:]
        }
        set {
            appliedClosenessDeltasData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue)
        }
    }
}
