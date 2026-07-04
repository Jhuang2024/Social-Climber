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
        content.body = "Send them a message — it matters."
        content.sound = .default

        var comps = Calendar.current.dateComponents([.month, .day], from: birthday)
        comps.hour = 9
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    /// Re-sync every pending notification from current data.
    func rescheduleAll(people: [Person], reminders: [Reminder]) {
        center.removeAllPendingNotificationRequests()
        for reminder in reminders where !reminder.completed {
            reminder.notificationID = nil
            schedule(reminder: reminder)
        }
        for person in people {
            scheduleBirthday(for: person)
        }
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
    }
}
