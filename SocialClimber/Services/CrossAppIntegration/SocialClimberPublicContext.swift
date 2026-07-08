import Foundation
import SwiftData

/// The small public context snapshot Social Climber publishes for Locked In
/// Fit to read. Deliberately shallow: today's actionable social tasks and
/// upcoming event context, nothing else. No private notes, no message
/// content, no closeness history, no AI drafts, no per-person detail beyond
/// what's needed to say "something's due" or "something's coming up."
struct SocialClimberPublicContext: Codable, Equatable {
    struct SocialTask: Codable, Equatable {
        enum Kind: String, Codable {
            case reply
            case checkIn = "check_in"
            case followUp = "follow_up"
            case eventPrep = "event_prep"
            case logInteraction = "log_interaction"
        }

        var id: String
        var title: String
        var type: Kind
        var priority: ImportanceLevel
    }

    struct UpcomingEvent: Codable, Equatable {
        var id: String
        var title: String
        var startDate: Date
        var eventType: EventKind
        var importance: ImportanceLevel
        var socialIntensity: ImportanceLevel
        var prepNeeded: Bool
    }

    struct Today: Codable, Equatable {
        var socialTasksDue: [SocialTask]
        var upcomingEvents: [UpcomingEvent]
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
    private static let maxTasks = 20
    private static let maxUpcomingEvents = 20

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
        // social task Locked In Fit thinks still matters today.
        let dueReminders = reminders
            .filter { reminder in
                guard !reminder.completed, reminder.dueDate.daysFromNow <= 0 else { return false }
                return !(reminder.person?.isArchived ?? false)
            }
            .sorted { $0.dueDate < $1.dueDate }
        for reminder in dueReminders {
            tasks.append(SocialTask(
                id: stableID(reminder.persistentModelID),
                title: reminder.title.isEmpty ? reminder.type.label : reminder.title,
                type: SocialTask.Kind(reminderType: reminder.type),
                priority: taskPriority(person: reminder.person, overdue: reminder.isOverdue)
            ))
        }

        let unloggedEvents = events.filter(\.needsLogging).sorted { $0.date > $1.date }
        for event in unloggedEvents {
            tasks.append(SocialTask(
                id: stableID(event.persistentModelID),
                title: "Log \(event.name.isEmpty ? "event" : event.name)",
                type: .logInteraction,
                priority: event.importance
            ))
        }

        for entry in pendingSharedImports {
            let snippet = entry.text.count > 40 ? "\(entry.text.prefix(40))…" : entry.text
            tasks.append(SocialTask(
                id: entry.id.uuidString,
                title: "Reply: \(snippet)",
                type: .reply,
                priority: .medium
            ))
        }

        let upcomingEvents = events
            .filter(\.isUpcoming)
            .sorted { $0.date < $1.date }
            .prefix(maxUpcomingEvents)
            .map { event in
                UpcomingEvent(
                    id: stableID(event.persistentModelID),
                    title: event.name.isEmpty ? "Event" : event.name,
                    startDate: event.date,
                    eventType: event.eventKind,
                    importance: event.importance,
                    socialIntensity: event.socialIntensity,
                    prepNeeded: event.prepNeeded
                )
            }

        return SocialClimberPublicContext(
            updatedAt: now,
            today: Today(
                socialTasksDue: Array(tasks.prefix(maxTasks)),
                upcomingEvents: Array(upcomingEvents)
            )
        )
    }

    /// A stable, opaque external ID for a SwiftData record. Not meant to be
    /// parsed by the reader, only compared across snapshots.
    private static func stableID(_ id: PersistentIdentifier) -> String {
        String(describing: id)
    }

    private static func taskPriority(person: Person?, overdue: Bool) -> ImportanceLevel {
        if overdue { return .high }
        guard let person else { return .medium }
        if person.priority >= 4 { return .high }
        if person.priority <= 2 { return .low }
        return .medium
    }
}

private extension SocialClimberPublicContext.SocialTask.Kind {
    /// Reminder types map onto the export's coarser task taxonomy; this
    /// mapping lives here, isolated in the integration layer, rather than on
    /// `ReminderType` itself, since it's an external contract, not a core
    /// domain concept.
    init(reminderType: ReminderType) {
        switch reminderType {
        case .checkIn, .birthday, .custom: self = .checkIn
        case .followUp, .gift: self = .followUp
        case .hangout: self = .eventPrep
        }
    }
}

// MARK: - Encoding

extension SocialClimberPublicContext {
    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(self)
    }
}
