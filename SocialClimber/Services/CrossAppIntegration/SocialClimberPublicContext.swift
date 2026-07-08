import Foundation
import SwiftData

/// The small public context snapshot Social Climber publishes for
/// LockedInFit to read. Deliberately shallow: today's overall social load,
/// clean event-prep context, and today's social task titles, nothing else.
/// No guest lists, private notes, exact locations, or message content ever
/// cross this boundary.
struct SocialClimberPublicContext: Codable, Equatable {
    enum EventType: String, Codable, Equatable {
        case dinner
        case party
        case networking
        case date
        case hangout
        case other
        case unknown
    }

    struct UpcomingEvent: Codable, Equatable {
        var id: String
        var eventType: EventType
        var importance: CrossAppLevel
        var startTime: Date
        var prepNeeded: Bool
    }

    struct SocialTask: Codable, Equatable {
        var id: String
        var title: String
    }

    struct Today: Codable, Equatable {
        var socialIntensity: CrossAppLevel
        var upcomingEvents: [UpcomingEvent]
        var socialTasksDueToday: [SocialTask]
    }

    var app: String = "SocialClimber"
    var schemaVersion: Int = 1
    var updatedAt: Date
    var today: Today
}

// MARK: - Building a snapshot from live data

extension SocialClimberPublicContext {
    /// Caps on how much goes into a single snapshot. This is a small status
    /// file re-read on every launch, not an export, so it only ever needs
    /// enough to answer "what's due" and "what's coming up," not a full
    /// backlog.
    private static let maxUpcomingEvents = 20
    private static let maxTasks = 20

    /// Builds the snapshot entirely from data Social Climber already
    /// queries elsewhere (reminders, events, the Share Extension inbox);
    /// this is a read-only projection, not a second source of truth.
    static func build(
        reminders: [Reminder],
        events: [Event],
        pendingSharedImports: [SharedImportEntry],
        now: Date = .now
    ) -> SocialClimberPublicContext {
        var tasks: [SocialTask] = []

        // A reminder tied to an archived person shouldn't surface as a
        // social task LockedInFit thinks still matters today.
        let dueReminders = reminders
            .filter { reminder in
                guard !reminder.completed, reminder.dueDate.daysFromNow <= 0 else { return false }
                return !(reminder.person?.isArchived ?? false)
            }
            .sorted { $0.dueDate < $1.dueDate }
        for reminder in dueReminders {
            tasks.append(SocialTask(
                id: stableID(reminder.persistentModelID),
                title: reminder.title.isEmpty ? reminder.type.label : reminder.title
            ))
        }

        let unloggedEvents = events.filter(\.needsLogging).sorted { $0.date > $1.date }
        for event in unloggedEvents {
            tasks.append(SocialTask(
                id: stableID(event.persistentModelID),
                title: "Log \(event.name.isEmpty ? "event" : event.name)"
            ))
        }

        for entry in pendingSharedImports {
            let snippet = entry.text.count > 40 ? "\(entry.text.prefix(40))…" : entry.text
            tasks.append(SocialTask(id: entry.id.uuidString, title: "Reply: \(snippet)"))
        }

        let upcoming = events
            .filter(\.isUpcoming)
            .sorted { $0.date < $1.date }
            .prefix(maxUpcomingEvents)
        let upcomingEvents = upcoming.map { event in
            UpcomingEvent(
                id: stableID(event.persistentModelID),
                eventType: EventType(event.eventKind),
                importance: CrossAppLevel(event.importance),
                startTime: event.date,
                prepNeeded: event.prepNeeded
            )
        }

        // A single "how intense does today look" value, taken from
        // whichever event actually lands today; LockedInFit gets a coarse
        // read on social load without needing the full event list.
        let todaysIntensities = events
            .filter { Calendar.current.isDateInToday($0.date) }
            .map { CrossAppLevel($0.socialIntensity) }
        let socialIntensity = CrossAppLevel.highest(of: todaysIntensities, defaultingTo: .low)

        return SocialClimberPublicContext(
            updatedAt: now,
            today: Today(
                socialIntensity: socialIntensity,
                upcomingEvents: Array(upcomingEvents),
                socialTasksDueToday: Array(tasks.prefix(maxTasks))
            )
        )
    }

    /// A stable, opaque external ID for a SwiftData record. Not meant to be
    /// parsed by the reader, only compared across snapshots.
    private static func stableID(_ id: PersistentIdentifier) -> String {
        String(describing: id)
    }
}

private extension SocialClimberPublicContext.EventType {
    /// `EventKind` is a core domain concept with a `school` case
    /// LockedInFit's schema doesn't model; it folds into `.other` here
    /// rather than growing the shared wire vocabulary for one internal
    /// category. Lives here, isolated in the integration layer, since it's
    /// an external contract, not a core domain concept.
    init(_ kind: EventKind) {
        switch kind {
        case .hangout: self = .hangout
        case .dinner: self = .dinner
        case .party: self = .party
        case .networking: self = .networking
        case .date: self = .date
        case .school, .other: self = .other
        }
    }
}
