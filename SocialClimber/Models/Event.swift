import Foundation
import SwiftData

/// A social opportunity (a party, dinner, meetup, conference) that links a
/// set of people you plan to (or did) see together. After the event you can
/// quickly log interactions for every attendee at once.
@Model
final class Event {
    var name: String = ""
    var date: Date = Date()
    var location: String = ""
    var purpose: String = ""
    var notes: String = ""
    /// Set once the event's interactions have been logged, so the dashboard
    /// can nudge you about events you attended but never logged.
    var loggedAt: Date?
    var notificationID: String?
    var createdAt: Date = Date()

    /// Inverse declared on `Person.events`, mirroring how `Interaction.people`
    /// pairs with `Person.interactions`.
    var attendees: [Person] = []

    init(
        name: String = "",
        date: Date = .now,
        location: String = "",
        purpose: String = "",
        notes: String = "",
        attendees: [Person] = []
    ) {
        self.name = name
        self.date = date
        self.location = location
        self.purpose = purpose
        self.notes = notes
        self.attendees = attendees
        self.createdAt = .now
    }

    var isPast: Bool { date < .now }

    var isUpcoming: Bool { date >= Calendar.current.startOfDay(for: .now) }

    /// A past event whose interactions haven't been logged yet.
    var needsLogging: Bool { isPast && loggedAt == nil && !attendees.isEmpty }

    var attendeeNames: String {
        attendees.map(\.firstName).joined(separator: ", ")
    }
}
