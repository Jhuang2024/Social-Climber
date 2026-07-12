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

    /// Category/quiet-hours/preview preferences, read fresh each call.
    private var settings: NotificationSettings { NotificationSettings() }

    /// Requests permission the first time the user does something a reminder
    /// would help with (creates a reminder, date, or event) — the action itself
    /// is the explanation, so the OS prompt never appears cold on first launch.
    /// A no-op after the first ask. On grant, flips the master toggle on.
    @discardableResult
    func requestPermissionContextually() async -> Bool {
        let askedKey = "hasRequestedNotificationPermission"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: askedKey) else { return enabled }
        let status = await authorizationStatus()
        guard status == .notDetermined else {
            defaults.set(true, forKey: askedKey)
            return status == .authorized
        }
        defaults.set(true, forKey: askedKey)
        let granted = await requestAuthorization()
        if granted { defaults.set(true, forKey: "notificationsEnabled") }
        return granted
    }

    // MARK: Quiet hours + privacy helpers

    /// Returns `preferred` unless it lands in quiet hours, in which case the
    /// window's end hour.
    private func nonQuietHour(_ preferred: Int) -> Int {
        guard settings.quietHoursEnabled else { return preferred }
        return QuietHours.isQuiet(hour: preferred, startHour: settings.quietHoursStartHour, endHour: settings.quietHoursEndHour)
            ? settings.quietHoursEndHour
            : preferred
    }

    /// Adjusts an absolute fire date out of quiet hours.
    private func adjustedDate(_ date: Date) -> Date {
        guard settings.quietHoursEnabled else { return date }
        return QuietHours.adjustedFireDate(date, startHour: settings.quietHoursStartHour, endHour: settings.quietHoursEndHour)
    }

    /// Applies privacy-safe generic text unless the user opted into detailed
    /// previews, and stamps the category so actions route correctly. Layered on
    /// top of whatever detailed title/body the caller already set.
    private func applyPrivacy(_ content: UNMutableNotificationContent, category: NotificationCategory) {
        content.categoryIdentifier = category.identifier
        if !settings.detailedPreviews {
            content.title = category.genericTitle
            content.body = category.genericBody
        }
        var info = content.userInfo
        info["category"] = category.rawValue
        content.userInfo = info
    }

    private func dateAt(hour: Int, on day: Date) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }

    // MARK: Reminders

    func schedule(reminder: Reminder) {
        let category: NotificationCategory = reminder.type == .followUp ? .followUp : .explicitReminder
        guard enabled, settings.isEnabled(category), !reminder.completed, reminder.dueDate > .now else { return }
        let id = reminder.notificationID ?? UUID().uuidString
        reminder.notificationID = id
        center.removePendingNotificationRequests(withIdentifiers: [id])

        let content = UNMutableNotificationContent()
        content.title = reminder.type.label
        content.body = reminder.person.map { "\($0.firstName): \(reminder.title)" } ?? reminder.title
        content.sound = .default
        content.threadIdentifier = reminder.person?.name ?? category.identifier
        content.userInfo = ["kind": "reminder"]
        applyPrivacy(content, category: category)

        var comps = Calendar.current.dateComponents([.year, .month, .day], from: reminder.dueDate)
        comps.hour = nonQuietHour(9)
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
        guard enabled, settings.isEnabled(.birthday), let birthday = person.birthday, !person.isArchived else { return }

        let content = UNMutableNotificationContent()
        content.title = "🎂 \(person.firstName)'s birthday today"
        content.body = "Send them a message. It matters."
        content.sound = .default
        content.threadIdentifier = person.name
        content.userInfo = ["kind": "birthday", "personName": person.name]
        applyPrivacy(content, category: .birthday)

        var comps = Calendar.current.dateComponents([.month, .day], from: birthday)
        comps.hour = nonQuietHour(9)
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
        guard enabled, settings.isEnabled(.importantDate), let next = importantDate.nextOccurrence else { return }

        let content = UNMutableNotificationContent()
        content.title = "⭐ \(importantDate.title)"
        content.body = importantDate.person.map { "\($0.firstName), don't forget." } ?? "Today."
        content.sound = .default
        content.threadIdentifier = importantDate.person?.name ?? "important-dates"
        content.userInfo = ["kind": "importantDate", "personName": importantDate.person?.name ?? ""]
        applyPrivacy(content, category: .importantDate)

        var comps = importantDate.repeatsYearly
            ? Calendar.current.dateComponents([.month, .day], from: next)
            : Calendar.current.dateComponents([.year, .month, .day], from: next)
        comps.hour = nonQuietHour(9)
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
        guard enabled, settings.isEnabled(.event), event.date > .now else { return }

        let content = UNMutableNotificationContent()
        content.title = "📅 \(event.name.isEmpty ? "Event" : event.name) today"
        content.body = event.location.isEmpty ? "Coming up soon." : "At \(event.location)."
        content.sound = .default
        content.threadIdentifier = "event-\(event.name)"
        content.userInfo = ["kind": "event"]
        applyPrivacy(content, category: .event)

        let fireDate = adjustedDate(event.date)
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
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

    /// Registers actionable categories. Called once at app launch. Registers
    /// both the post-event "how did it go?" category and the reminder/contact
    /// categories in a single call (setNotificationCategories replaces the whole
    /// set, so they must be registered together).
    func registerNotificationCategories() {
        let log = UNNotificationAction(identifier: Self.eventLogActionID, title: "Log it", options: [])
        let addNote = UNNotificationAction(identifier: Self.eventAddNoteActionID, title: "Add note", options: [.foreground])
        let skip = UNNotificationAction(identifier: Self.eventSkipActionID, title: "Skip", options: [])
        let eventCategory = UNNotificationCategory(
            identifier: Self.eventFollowUpCategoryID,
            actions: [log, addNote, skip],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories(scCategories().union([eventCategory]))
    }

    /// The reminder/contact-oriented categories (complete/snooze/open/…).
    private func scCategories() -> Set<UNNotificationCategory> {
        func make(_ cat: NotificationCategory, _ actions: [NotificationAction]) -> UNNotificationCategory {
            let unActions = actions.map {
                UNNotificationAction(identifier: $0.rawValue, title: $0.title, options: $0.opensApp ? [.foreground] : [])
            }
            return UNNotificationCategory(identifier: cat.identifier, actions: unActions, intentIdentifiers: [], options: [])
        }
        return [
            make(.explicitReminder, [.markComplete, .snooze, .openReminder]),
            make(.followUp, [.markComplete, .snooze, .logInteraction]),
            make(.overdueFollowUp, [.markComplete, .snooze, .logInteraction]),
            make(.event, [.openContact, .snooze]),
            make(.birthday, [.openContact, .logInteraction]),
            make(.importantDate, [.openContact, .snooze]),
            make(.relationshipMaintenance, [.logInteraction, .openContact, .snooze]),
            make(.captureReview, [.reviewCapture]),
            make(.periodicReview, [.openContact]),
        ]
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

    // MARK: Relationship maintenance & periodic review

    /// A single, gentle nudge for a person drifting past their check-in
    /// cadence, anchored to a stable due date (last contact + cadence) so
    /// rebuilding on every reconcile never advances it or nags.
    func scheduleRelationshipMaintenance(for person: Person) {
        let id = "maintenance-\(person.name)"
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard enabled, settings.isEnabled(.relationshipMaintenance), !person.isArchived else { return }
        let status = person.status
        guard status == .checkInSoon || status == .goingQuiet || status == .dormant else { return }

        let cadence = RelationshipHealth.expectedCadenceDays(for: person)
        let anchor = person.lastContactedAt ?? person.createdAt
        var due = Calendar.current.date(byAdding: .day, value: cadence, to: anchor) ?? .now
        if due < .now {
            due = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now)) ?? .now
        }
        let fireDate = adjustedDate(dateAt(hour: 9, on: due))

        let content = UNMutableNotificationContent()
        content.title = "Reconnect with \(person.firstName)?"
        content.body = "It's been a while. A quick hello goes a long way."
        content.sound = .default
        content.threadIdentifier = person.name
        content.userInfo = ["kind": "maintenance", "personName": person.name]
        applyPrivacy(content, category: .relationshipMaintenance)

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        center.add(UNNotificationRequest(identifier: id, content: content,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }

    /// Optional periodic review nudge for prioritised contacts, anchored to
    /// last contact + the user's review frequency.
    func schedulePeriodicReview(for person: Person) {
        let id = "review-\(person.name)"
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard enabled, settings.isEnabled(.periodicReview), !person.isArchived, person.priority >= 4 else { return }

        let anchor = person.lastContactedAt ?? person.createdAt
        var due = Calendar.current.date(byAdding: .day, value: settings.reviewFrequencyDays, to: anchor) ?? .now
        if due < .now {
            due = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now)) ?? .now
        }
        let fireDate = adjustedDate(dateAt(hour: 9, on: due))

        let content = UNMutableNotificationContent()
        content.title = "Review \(person.firstName)"
        content.body = "A good moment to revisit notes and plans for them."
        content.sound = .default
        content.threadIdentifier = person.name
        content.userInfo = ["kind": "review", "personName": person.name]
        applyPrivacy(content, category: .periodicReview)

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        center.add(UNNotificationRequest(identifier: id, content: content,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }

    /// A single grouped alert for captures needing review, scheduled shortly
    /// from now. Fixed identifier so the count updates in place.
    func scheduleCaptureReview(pendingCount: Int) {
        let id = "capture-review"
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard enabled, settings.isEnabled(.captureReview), pendingCount > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Capture needs review"
        content.body = pendingCount == 1 ? "One capture still needs review." : "\(pendingCount) captures still need review."
        content.sound = .default
        content.threadIdentifier = id
        content.userInfo = ["kind": "captureReview"]
        applyPrivacy(content, category: .captureReview)

        let fire = adjustedDate(Date().addingTimeInterval(30 * 60))
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        center.add(UNNotificationRequest(identifier: id, content: content,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }

    /// Comprehensive reconciliation used on launch and whenever data changes.
    /// Extends `rescheduleAll` with relationship-maintenance, periodic-review,
    /// and capture-review alerts. Idempotent via stable identifiers.
    func reconcile(
        people: [Person],
        reminders: [Reminder],
        importantDates: [ImportantDate],
        events: [Event],
        pendingCaptureCount: Int
    ) {
        rescheduleAll(people: people, reminders: reminders, importantDates: importantDates, events: events)
        guard enabled else { return }
        for person in people {
            scheduleRelationshipMaintenance(for: person)
            schedulePeriodicReview(for: person)
        }
        scheduleCaptureReview(pendingCount: pendingCaptureCount)
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
    }
}
