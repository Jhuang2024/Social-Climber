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
    /// Optional explicit end time. When set, the post-event follow-up
    /// prompt fires shortly after this instead of a guessed duration.
    var endDate: Date?
    /// Pending "how did it go?" follow-up notification, so it can be
    /// cancelled/rescheduled when the event changes.
    var followUpNotificationID: String?
    /// Set when the user tapped "Skip" on the follow-up prompt, so it is
    /// never offered again for this event.
    var followUpDismissedAt: Date?
    var createdAt: Date = Date()

    // MARK: Social context
    // Kept as plain attributes (not just UI state) because they're real
    // properties of the event, and because `CrossAppIntegrationManager`
    // publishes them, in stripped-down form, as event-prep context for
    // Locked In Fit: no attendee names, location, purpose, or notes.
    var eventKindRaw: String = EventKind.hangout.rawValue
    var importanceRaw: String = ImportanceLevel.medium.rawValue
    var socialIntensityRaw: String = ImportanceLevel.medium.rawValue
    /// Whether this event is significant enough to warrant prep (an outfit
    /// check, an early night, a workout) ahead of time.
    var prepNeeded: Bool = false

    /// Inverse declared on `Person.events`, mirroring how `Interaction.people`
    /// pairs with `Person.interactions`.
    var attendees: [Person] = []

    init(
        name: String = "",
        date: Date = .now,
        endDate: Date? = nil,
        location: String = "",
        purpose: String = "",
        notes: String = "",
        attendees: [Person] = [],
        eventKind: EventKind = .hangout,
        importance: ImportanceLevel = .medium,
        socialIntensity: ImportanceLevel = .medium,
        prepNeeded: Bool = false
    ) {
        self.name = name
        self.date = date
        self.endDate = endDate
        self.location = location
        self.purpose = purpose
        self.notes = notes
        self.attendees = attendees
        self.createdAt = .now
        self.eventKindRaw = eventKind.rawValue
        self.importanceRaw = importance.rawValue
        self.socialIntensityRaw = socialIntensity.rawValue
        self.prepNeeded = prepNeeded
    }

    var eventKind: EventKind {
        get { EventKind(rawValue: eventKindRaw) ?? .hangout }
        set { eventKindRaw = newValue.rawValue }
    }

    var importance: ImportanceLevel {
        get { ImportanceLevel(rawValue: importanceRaw) ?? .medium }
        set { importanceRaw = newValue.rawValue }
    }

    var socialIntensity: ImportanceLevel {
        get { ImportanceLevel(rawValue: socialIntensityRaw) ?? .medium }
        set { socialIntensityRaw = newValue.rawValue }
    }

    /// When the event is considered over: the explicit end time when set,
    /// otherwise a conservative two hours after it starts.
    var effectiveEndDate: Date {
        endDate ?? date.addingTimeInterval(2 * 3600)
    }

    var isPast: Bool { date < .now }

    var isUpcoming: Bool { date >= Calendar.current.startOfDay(for: .now) }

    /// A past event whose interactions haven't been logged yet.
    var needsLogging: Bool { isPast && loggedAt == nil && !attendees.isEmpty }

    var attendeeNames: String {
        attendees.map(\.firstName).joined(separator: ", ")
    }
}
