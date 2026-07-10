import Foundation
import UserNotifications

final class NotificationService {
    static let shared = NotificationService()
    private let center = UNUserNotificationCenter.current()
    private init() {}

    var enabled: Bool { UserDefaults.standard.bool(forKey: "notificationsEnabled") }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// The real OS-level permission state, independent of the app's own
    /// `notificationsEnabled` preference; lets the UI detect a user
    /// revoking permission in iOS Settings after granting it here, instead
    /// of silently believing notifications are still on.
    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    // MARK: Reminders

    func schedule(reminder: Reminder) {
        guard enabled, !reminder.completed, reminder.dueDate > .now else { return }
        let id = reminder.notificationID ?? UUID().uuidString
        reminder.notificationID = id

        let content = UNMutableNotificationContent()
        content.title = reminder.type.label
        content.body = reminder.person.map { "\($0.firstName): \(reminder.title)" } ?? reminder.title
        content.sound = .default

        var comps = Calendar.current.dateComponents([.year, .month, .day], from: reminder.dueDate)
        comps.hour = 9
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    func cancel(reminder: Reminder) {
        guard let id = reminder.notificationID else { return }
        center.removePendingNotificationRequests(withIdentifiers: [id])
        reminder.notificationID = nil
    }

    // MARK: Birthdays

    func scheduleBirthday(for person: Person) {
        // Name-keyed so the ID is stable across launches.
        let id = "birthday-\(person.name)"
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard enabled, let birthday = person.birthday, !person.isArchived else { return }

        let content = UNMutableNotificationContent()
        content.title = "🎂 \(person.firstName)'s birthday today"
        content.body = "Send them a message. It matters."
        content.sound = .default

        var comps = Calendar.current.dateComponents([.month, .day], from: birthday)
        comps.hour = 9
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    /// Cancels a person's standing birthday notification without touching
    /// anything else; used when a person is deleted or archived.
    func cancelBirthday(for person: Person) {
        center.removePendingNotificationRequests(withIdentifiers: ["birthday-\(person.name)"])
    }

    // MARK: Important Dates

    func schedule(importantDate: ImportantDate) {
        let id = importantDate.notificationID ?? UUID().uuidString
        importantDate.notificationID = id
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard enabled, let next = importantDate.nextOccurrence else { return }

        let content = UNMutableNotificationContent()
        content.title = "⭐ \(importantDate.title)"
        content.body = importantDate.person.map { "\($0.firstName), don't forget." } ?? "Today."
        content.sound = .default

        var comps = importantDate.repeatsYearly
            ? Calendar.current.dateComponents([.month, .day], from: next)
            : Calendar.current.dateComponents([.year, .month, .day], from: next)
        comps.hour = 9
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: importantDate.repeatsYearly)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    func cancel(importantDate: ImportantDate) {
        guard let id = importantDate.notificationID else { return }
        center.removePendingNotificationRequests(withIdentifiers: [id])
        importantDate.notificationID = nil
    }

    // MARK: Events

    func schedule(event: Event) {
        let id = event.notificationID ?? UUID().uuidString
        event.notificationID = id
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard enabled, event.date > .now else { return }

        let content = UNMutableNotificationContent()
        content.title = "📅 \(event.name.isEmpty ? "Event" : event.name) today"
        content.body = event.location.isEmpty ? "Coming up soon." : "At \(event.location)."
        content.sound = .default

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: event.date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    func cancel(event: Event) {
        guard let id = event.notificationID else { return }
        center.removePendingNotificationRequests(withIdentifiers: [id])
        event.notificationID = nil
        cancelFollowUp(for: event)
    }

    // MARK: Event follow-up prompts

    /// Category + action identifiers for the post-event "how did it go?"
    /// prompt. Handled by `NotificationActionHandler`.
    static let eventFollowUpCategoryID = "EVENT_FOLLOWUP"
    static let eventLogActionID = "EVENT_LOG"
    static let eventAddNoteActionID = "EVENT_ADD_NOTE"
    static let eventSkipActionID = "EVENT_SKIP"

    /// Registers actionable categories. Called once at app launch.
    func registerNotificationCategories() {
        let log = UNNotificationAction(identifier: Self.eventLogActionID, title: "Log it", options: [])
        let addNote = UNNotificationAction(identifier: Self.eventAddNoteActionID, title: "Add note", options: [.foreground])
        let skip = UNNotificationAction(identifier: Self.eventSkipActionID, title: "Skip", options: [])
        let category = UNNotificationCategory(
            identifier: Self.eventFollowUpCategoryID,
            actions: [log, addNote, skip],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    /// Schedules a local "how did it go?" prompt shortly after the event
    /// ends (its explicit end time when set). One tap on "Log it" then
    /// creates one neutral event interaction for the attendees, no form.
    /// Never fires for events with no attendees, already-logged events, or
    /// ones whose prompt the user skipped.
    func scheduleFollowUp(for event: Event) {
        if let existing = event.followUpNotificationID {
            center.removePendingNotificationRequests(withIdentifiers: [existing])
            event.followUpNotificationID = nil
        }
        guard enabled, !event.attendees.isEmpty, event.loggedAt == nil, event.followUpDismissedAt == nil else { return }
        let fireDate = event.effectiveEndDate.addingTimeInterval(15 * 60)
        guard fireDate > .now else { return }

        let id = "event-followup-\(UUID().uuidString)"
        event.followUpNotificationID = id

        let content = UNMutableNotificationContent()
        content.title = event.name.isEmpty ? "How did it go?" : "How was \(event.name)?"
        content.body = "Log it for \(event.attendeeNames) in one tap, or add a quick note."
        content.sound = .default
        content.categoryIdentifier = Self.eventFollowUpCategoryID
        content.userInfo = ["kind": "scEvent", "followUpID": id]

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    func cancelFollowUp(for event: Event) {
        guard let id = event.followUpNotificationID else { return }
        center.removePendingNotificationRequests(withIdentifiers: [id])
        event.followUpNotificationID = nil
    }

    /// Same prompt for confidently-matched Google Calendar events. Never
    /// creates an interaction on its own; an event merely existing is not
    /// contact; it takes one explicit notification action. Deduplicated by
    /// the calendar event's own id, which also makes rescheduling on every
    /// refresh idempotent.
    func scheduleCalendarFollowUp(
        calendarEventID: String,
        title: String,
        endDate: Date,
        location: String,
        attendeeIDs: [UUID],
        attendeeNames: [String]
    ) {
        guard enabled, !attendeeNames.isEmpty else { return }
        let defaults = UserDefaults.standard
        var handled = Set(defaults.stringArray(forKey: "gcalFollowUpsScheduledOrHandled") ?? [])
        guard !handled.contains(calendarEventID) else { return }

        let fireDate = endDate.addingTimeInterval(15 * 60)
        guard fireDate > .now else { return }

        handled.insert(calendarEventID)
        defaults.set(Array(handled), forKey: "gcalFollowUpsScheduledOrHandled")

        let id = "gcal-followup-\(calendarEventID)"
        let content = UNMutableNotificationContent()
        content.title = "How was \(title)?"
        content.body = "Log it for \(attendeeNames.joined(separator: ", ")) in one tap, or add a quick note."
        content.sound = .default
        content.categoryIdentifier = Self.eventFollowUpCategoryID
        content.userInfo = [
            "kind": "gcalEvent",
            "gcalID": calendarEventID,
            "title": title,
            "location": location,
            "attendeeIDs": attendeeIDs.map(\.uuidString),
            "attendees": attendeeNames,
            "dateEpoch": endDate.timeIntervalSince1970,
        ]

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    /// Re-sync every pending notification from current data.
    func rescheduleAll(people: [Person], reminders: [Reminder], importantDates: [ImportantDate], events: [Event]) {
        center.removeAllPendingNotificationRequests()
        for reminder in reminders where !reminder.completed {
            reminder.notificationID = nil
            schedule(reminder: reminder)
        }
        for person in people {
            scheduleBirthday(for: person)
        }
        for importantDate in importantDates {
            importantDate.notificationID = nil
            schedule(importantDate: importantDate)
        }
        for event in events where event.isUpcoming {
            event.notificationID = nil
            schedule(event: event)
            event.followUpNotificationID = nil
            scheduleFollowUp(for: event)
        }
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
    }
}
