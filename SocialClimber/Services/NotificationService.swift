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
        }
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
    }
}
