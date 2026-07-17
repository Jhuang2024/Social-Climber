import Foundation
import UserNotifications
import OSLog

final class NotificationService {
    static let shared = NotificationService()
    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: "com.jerryhuang.SocialClimber", category: "notifications")
    private init() {}

    var enabled: Bool { UserDefaults.standard.bool(forKey: "notificationsEnabled") }

    func requestAuthorization() async -> Bool {
        // `.timeSensitive` is what lets `interruptionLevel = .timeSensitive`
        // (set below on reminders/birthdays/dates/events) actually break
        // through Focus/Do Not Disturb the way Messages and Calendar do —
        // without requesting this option, the OS won't grant that
        // interruption level even if the content asks for it, and every
        // notification gets silently logged to Notification Center instead
        // of shown, indistinguishable from a scheduling failure.
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge, .timeSensitive])) ?? false
    }

    /// The real OS-level permission state, independent of the app's own
    /// `notificationsEnabled` preference; lets the UI detect a user
    /// revoking permission in iOS Settings after granting it here, instead
    /// of silently believing notifications are still on.
    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    struct Diagnostics {
        let authorizationStatus: UNAuthorizationStatus
        let alertSetting: UNNotificationSetting
        let soundSetting: UNNotificationSetting
        let timeSensitiveSetting: UNNotificationSetting
        let notificationCenterSetting: UNNotificationSetting
        let lockScreenSetting: UNNotificationSetting
        let pendingCount: Int
        let instagramReminderScheduled: Bool
        let lastSchedulingError: String?
        let lastForegroundPresentationID: String?
        let lastForegroundPresentationAt: Date?
    }

    /// Reads what iOS actually has, rather than inferring delivery from
    /// toggles in UserDefaults. Used by Settings to make silent scheduling
    /// failures visible. Authorization alone is not sufficient for a banner
    /// to appear: a user can grant permission but still have the alert
    /// style set to "None", or have Focus/Do Not Disturb active, in which
    /// case `authorizationStatus == .authorized` while nothing is ever
    /// actually shown. `alertSetting`/`soundSetting` surface that gap.
    func diagnostics() async -> Diagnostics {
        let notificationSettings = await center.notificationSettings()
        let pending = await center.pendingNotificationRequests()
        logger.info("""
            diagnostics: auth=\(String(describing: notificationSettings.authorizationStatus), privacy: .public) \
            alert=\(String(describing: notificationSettings.alertSetting), privacy: .public) \
            sound=\(String(describing: notificationSettings.soundSetting), privacy: .public) \
            timeSensitive=\(String(describing: notificationSettings.timeSensitiveSetting), privacy: .public) \
            notifCenter=\(String(describing: notificationSettings.notificationCenterSetting), privacy: .public) \
            lockScreen=\(String(describing: notificationSettings.lockScreenSetting), privacy: .public) \
            pendingCount=\(pending.count, privacy: .public)
            """)
        return Diagnostics(
            authorizationStatus: notificationSettings.authorizationStatus,
            alertSetting: notificationSettings.alertSetting,
            soundSetting: notificationSettings.soundSetting,
            timeSensitiveSetting: notificationSettings.timeSensitiveSetting,
            notificationCenterSetting: notificationSettings.notificationCenterSetting,
            lockScreenSetting: notificationSettings.lockScreenSetting,
            pendingCount: pending.count,
            instagramReminderScheduled: pending.contains { $0.identifier == Self.instagramReminderID },
            lastSchedulingError: UserDefaults.standard.string(forKey: Self.lastSchedulingErrorKey),
            lastForegroundPresentationID: UserDefaults.standard.string(forKey: Self.lastForegroundPresentationIDKey),
            lastForegroundPresentationAt: UserDefaults.standard.object(forKey: Self.lastForegroundPresentationAtKey) as? Date
        )
    }

    private static let lastSchedulingErrorKey = "notificationLastSchedulingError"
    private static let lastForegroundPresentationIDKey = "notificationLastForegroundPresentationID"
    private static let lastForegroundPresentationAtKey = "notificationLastForegroundPresentationAt"

    /// Called only by `UNUserNotificationCenterDelegate.willPresent`, proving
    /// that iOS fired the request while the app was foregrounded and invoked
    /// the app's presentation path.
    func recordForegroundPresentation(requestID: String) {
        UserDefaults.standard.set(requestID, forKey: Self.lastForegroundPresentationIDKey)
        UserDefaults.standard.set(Date.now, forKey: Self.lastForegroundPresentationAtKey)
        logger.info("willPresent invoked for id=\(requestID, privacy: .public); requesting banner, list, sound, badge")
    }

    /// Submit through one checked path. Previously every production
    /// `center.add` discarded its error, so a rejected request appeared to
    /// have scheduled successfully.
    private func enqueue(_ request: UNNotificationRequest, source: String) {
        center.add(request) { [logger] error in
            if let error {
                let message = "\(source) [\(request.identifier)]: \(error.localizedDescription)"
                UserDefaults.standard.set(message, forKey: Self.lastSchedulingErrorKey)
                logger.error("schedule failed: \(message, privacy: .public)")
            } else {
                logger.info("scheduled \(source, privacy: .public) id=\(request.identifier, privacy: .public)")
            }
        }
    }

    static let deliveryTestID = "notification-delivery-test"

    enum DeliveryTestOutcome {
        /// The 3-second trigger hasn't fired yet.
        case stillPending
        /// iOS fired it while the app was active and invoked `willPresent`.
        case presentedInForeground
        /// iOS delivered it without invoking the foreground delegate, meaning
        /// the app was backgrounded/inactive when it fired.
        case deliveredInBackground
        /// Neither pending nor delivered after the trigger should have
        /// fired — `center.add` likely threw, or iOS silently dropped it
        /// before delivery (rare, but seen with corrupted notification
        /// state that only a device restart clears).
        case missing
    }

    /// Call a few seconds after `scheduleDeliveryTest()` to find out what
    /// actually happened, instead of guessing from "I didn't see anything."
    func checkDeliveryTestOutcome() async -> DeliveryTestOutcome {
        let pending = await center.pendingNotificationRequests()
        if pending.contains(where: { $0.identifier == Self.deliveryTestID }) {
            logger.info("deliveryTest: still pending")
            return .stillPending
        }
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Self.lastForegroundPresentationIDKey) == Self.deliveryTestID {
            logger.info("deliveryTest: foreground delegate invoked")
            return .presentedInForeground
        }
        let delivered = await center.deliveredNotifications()
        let outcome: DeliveryTestOutcome = delivered.contains { $0.request.identifier == Self.deliveryTestID }
            ? .deliveredInBackground
            : .missing
        logger.info("deliveryTest: outcome=\(String(describing: outcome), privacy: .public) deliveredCount=\(delivered.count, privacy: .public)")
        return outcome
    }

    /// A short, explicit end-to-end delivery test. It requests permission if
    /// needed, enables the app master switch, then asks iOS to fire in 3 sec.
    func scheduleDeliveryTest() async throws {
        let status = await authorizationStatus()
        logger.info("deliveryTest: authorizationStatus=\(String(describing: status), privacy: .public)")
        let authorized: Bool
        switch status {
        case .denied:
            authorized = false
        default:
            // Re-request even when already authorized/provisional/ephemeral:
            // iOS only grants the interruption levels that were included in
            // the options set at the moment the user answered the system
            // prompt. An install that granted permission before this app
            // requested `.timeSensitive` will never pick it up just because
            // the code changed — calling requestAuthorization again is safe
            // (no new UI for options already decided) and is what actually
            // extends the grant to include it.
            authorized = await requestAuthorization()
            logger.info("deliveryTest: requestAuthorization()=\(authorized, privacy: .public)")
        }
        guard authorized else {
            logger.error("deliveryTest: not authorized, aborting")
            throw NotificationDeliveryTestError.permissionDenied
        }
        UserDefaults.standard.set(true, forKey: "notificationsEnabled")

        let content = UNMutableNotificationContent()
        content.title = "Social Climber notifications work"
        content.body = "This is a test alert from this iPhone."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["kind": "deliveryTest"]
        let request = UNNotificationRequest(
            identifier: Self.deliveryTestID,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        )
        center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
        // A prior test used the same stable identifier. Leaving it in the
        // delivered list made `checkDeliveryTestOutcome` mistake stale history
        // for proof that the new test fired.
        center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
        UserDefaults.standard.removeObject(forKey: Self.lastForegroundPresentationIDKey)
        UserDefaults.standard.removeObject(forKey: Self.lastForegroundPresentationAtKey)
        do {
            try await center.add(request)
            logger.info("deliveryTest: center.add succeeded, firing in 3s")
        } catch {
            logger.error("deliveryTest: center.add threw \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Category/quiet-hours/preview preferences, read fresh each call.
    private var settings: NotificationSettings { NotificationSettings() }

    /// Requests permission the first time the user does something a reminder
    /// would help with (creates a reminder, date, or event): the action itself
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

    /// Guards against `reconcile()` walking dozens of people/reminders in one
    /// pass and each of them independently kicking off a permission request
    /// before the first one has set `hasRequestedNotificationPermission`.
    private var isRequestingPermission = false

    /// Called by a `schedule*` method once its own data preconditions have
    /// passed but `enabled` is false. Only 3 of the app's ~15 scheduling
    /// call sites (creating a Reminder or Important Date, and the
    /// follow-up-needed auto-reminder) used to call
    /// `requestPermissionContextually()` themselves — every other path
    /// (birthdays, events, Quick Capture, relationship maintenance, …)
    /// skipped straight to a `schedule*` call and silently no-opped forever
    /// on a fresh install, since permission was never actually requested.
    /// Centralizing the contextual ask here means every entry point gets it
    /// for free. A no-op after the first ask (or if disabled for another
    /// reason, e.g. a per-category toggle) — `retry` re-checks `enabled`
    /// itself, so this can't loop or re-prompt.
    private func requestPermissionThenRetry(_ retry: @escaping () -> Void) {
        guard !UserDefaults.standard.bool(forKey: "hasRequestedNotificationPermission"), !isRequestingPermission else { return }
        isRequestingPermission = true
        Task {
            await requestPermissionContextually()
            isRequestingPermission = false
            retry()
        }
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

    /// Date-only records alert at 9 AM. When scheduling today's record after
    /// 9, use a short interval instead of creating a calendar trigger in the
    /// past (which iOS accepts but never fires).
    private func fireDateAtNine(for day: Date, now: Date = .now) -> Date? {
        let nine = adjustedDate(dateAt(hour: nonQuietHour(9), on: day))
        if nine > now { return nine }
        guard Calendar.current.isDate(day, inSameDayAs: now) else { return nil }
        return adjustedDate(now.addingTimeInterval(60))
    }

    // MARK: Reminders

    func schedule(reminder: Reminder) {
        guard !reminder.completed else { return }
        let isOverdue = reminder.dueDate < Calendar.current.startOfDay(for: .now)
        let category: NotificationCategory = reminder.type == .followUp
            ? (isOverdue ? .overdueFollowUp : .followUp)
            : .explicitReminder
        guard !isOverdue || reminder.type == .followUp else { return }
        guard enabled, settings.isEnabled(category) else {
            requestPermissionThenRetry { [weak self] in self?.schedule(reminder: reminder) }
            return
        }
        let id = reminder.notificationID ?? UUID().uuidString
        reminder.notificationID = id
        center.removePendingNotificationRequests(withIdentifiers: [id])

        let content = UNMutableNotificationContent()
        content.title = reminder.type.label
        content.body = reminder.person.map { "\($0.firstName): \(reminder.title)" } ?? reminder.title
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = reminder.person?.name ?? category.identifier
        content.userInfo = ["kind": "reminder"]
        applyPrivacy(content, category: category)

        let fireDate: Date
        if isOverdue {
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now)) ?? .now
            fireDate = adjustedDate(dateAt(hour: nonQuietHour(9), on: tomorrow))
        } else if let scheduled = fireDateAtNine(for: reminder.dueDate) {
            fireDate = scheduled
        } else {
            return
        }
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        enqueue(UNNotificationRequest(identifier: id, content: content, trigger: trigger), source: "reminder")
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
        guard let birthday = person.birthday, !person.isArchived else { return }
        guard enabled, settings.isEnabled(.birthday) else {
            requestPermissionThenRetry { [weak self] in self?.scheduleBirthday(for: person) }
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "🎂 \(person.firstName)'s birthday today"
        content.body = "Send them a message. It matters."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = person.name
        content.userInfo = ["kind": "birthday", "personName": person.name]
        applyPrivacy(content, category: .birthday)

        var comps = Calendar.current.dateComponents([.month, .day], from: birthday)
        comps.hour = nonQuietHour(9)
        let isBirthdayToday = Calendar.current.component(.month, from: birthday) == Calendar.current.component(.month, from: .now)
            && Calendar.current.component(.day, from: birthday) == Calendar.current.component(.day, from: .now)
        let trigger: UNNotificationTrigger
        if isBirthdayToday, dateAt(hour: nonQuietHour(9), on: .now) <= .now {
            // A repeating month/day trigger created after today's matching
            // time would otherwise skip straight to next year.
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false)
        } else {
            trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        }
        enqueue(UNNotificationRequest(identifier: id, content: content, trigger: trigger), source: "birthday")
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
        guard let next = importantDate.nextOccurrence else { return }
        guard enabled, settings.isEnabled(.importantDate) else {
            requestPermissionThenRetry { [weak self] in self?.schedule(importantDate: importantDate) }
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "⭐ \(importantDate.title)"
        content.body = importantDate.person.map { "\($0.firstName), don't forget." } ?? "Today."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = importantDate.person?.name ?? "important-dates"
        content.userInfo = ["kind": "importantDate", "personName": importantDate.person?.name ?? ""]
        applyPrivacy(content, category: .importantDate)

        var comps = importantDate.repeatsYearly
            ? Calendar.current.dateComponents([.month, .day], from: next)
            : Calendar.current.dateComponents([.year, .month, .day], from: next)
        comps.hour = nonQuietHour(9)
        let today = Calendar.current.isDate(next, inSameDayAs: .now)
        let nineToday = dateAt(hour: nonQuietHour(9), on: .now)
        let trigger: UNNotificationTrigger
        if today && nineToday <= .now {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false)
        } else {
            trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: importantDate.repeatsYearly)
        }
        enqueue(UNNotificationRequest(identifier: id, content: content, trigger: trigger), source: "important-date")
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
        guard event.date > .now else { return }
        guard enabled, settings.isEnabled(.event) else {
            requestPermissionThenRetry { [weak self] in self?.schedule(event: event) }
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "📅 \(event.name.isEmpty ? "Event" : event.name) today"
        content.body = event.location.isEmpty ? "Coming up soon." : "At \(event.location)."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "event-\(event.name)"
        content.userInfo = ["kind": "event"]
        applyPrivacy(content, category: .event)

        let fireDate = adjustedDate(event.date)
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        enqueue(UNNotificationRequest(identifier: id, content: content, trigger: trigger), source: "event")
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
        guard !event.attendees.isEmpty, event.loggedAt == nil, event.followUpDismissedAt == nil else { return }
        let fireDate = event.effectiveEndDate.addingTimeInterval(15 * 60)
        guard fireDate > .now else { return }
        guard enabled else {
            requestPermissionThenRetry { [weak self] in self?.scheduleFollowUp(for: event) }
            return
        }

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
        enqueue(UNNotificationRequest(identifier: id, content: content, trigger: trigger), source: "event-follow-up")
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
        guard !attendeeNames.isEmpty else { return }
        let defaults = UserDefaults.standard
        var handled = Set(defaults.stringArray(forKey: "gcalFollowUpsScheduledOrHandled") ?? [])
        guard !handled.contains(calendarEventID) else { return }

        let fireDate = endDate.addingTimeInterval(15 * 60)
        guard fireDate > .now else { return }
        guard enabled else {
            requestPermissionThenRetry { [weak self] in
                self?.scheduleCalendarFollowUp(
                    calendarEventID: calendarEventID, title: title, endDate: endDate,
                    location: location, attendeeIDs: attendeeIDs, attendeeNames: attendeeNames
                )
            }
            return
        }

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
        enqueue(UNNotificationRequest(identifier: id, content: content, trigger: trigger), source: "calendar-follow-up")
    }

    // MARK: Instagram sync reminder

    /// iOS background execution is too unreliable to run the Drive sync on
    /// a real schedule, so this daily nudge asks the user to open the app
    /// and run it instead. Fires every morning at 10 AM while the toggle in
    /// Settings is on.
    private static let instagramReminderID = "instagram-sync-reminder"

    var instagramReminderEnabled: Bool {
        UserDefaults.standard.bool(forKey: "instagramSyncReminderEnabled")
    }

    func scheduleInstagramSyncReminder() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.instagramReminderID])
        guard enabled, instagramReminderEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "📸 Instagram sync"
        content.body = "Tap Sync on the Home screen to pull the latest export from Google Drive and refresh people, messages, and follower activity."
        content.sound = .default

        var comps = DateComponents()
        comps.hour = 10
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        enqueue(UNNotificationRequest(identifier: Self.instagramReminderID, content: content, trigger: trigger), source: "instagram-sync")
    }

    func cancelInstagramSyncReminder() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.instagramReminderID])
    }

    /// Re-sync every pending notification from current data.
    func rescheduleAll(people: [Person], reminders: [Reminder], importantDates: [ImportantDate], events: [Event]) {
        UserDefaults.standard.removeObject(forKey: Self.lastSchedulingErrorKey)
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
        // `removeAllPendingNotificationRequests` above also cleared the
        // standing Instagram reminder; put it back if it's turned on.
        scheduleInstagramSyncReminder()
    }

    // MARK: Relationship maintenance & periodic review

    /// A single, gentle nudge for a person drifting past their check-in
    /// cadence, anchored to a stable due date (last contact + cadence) so
    /// rebuilding on every reconcile never advances it or nags.
    func scheduleRelationshipMaintenance(for person: Person) {
        let id = "maintenance-\(person.name)"
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard !person.isArchived else { return }
        let status = person.status
        guard status == .checkInSoon || status == .goingQuiet || status == .dormant else { return }
        guard enabled, settings.isEnabled(.relationshipMaintenance) else {
            requestPermissionThenRetry { [weak self] in self?.scheduleRelationshipMaintenance(for: person) }
            return
        }

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
        enqueue(UNNotificationRequest(identifier: id, content: content,
                                      trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)),
                source: "relationship-maintenance")
    }

    /// Optional periodic review nudge for prioritised contacts, anchored to
    /// last contact + the user's review frequency.
    func schedulePeriodicReview(for person: Person) {
        let id = "review-\(person.name)"
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard !person.isArchived, person.priority >= 4 else { return }
        guard enabled, settings.isEnabled(.periodicReview) else {
            requestPermissionThenRetry { [weak self] in self?.schedulePeriodicReview(for: person) }
            return
        }

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
        enqueue(UNNotificationRequest(identifier: id, content: content,
                                      trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)),
                source: "periodic-review")
    }

    /// A single grouped alert for captures needing review, scheduled shortly
    /// from now. Fixed identifier so the count updates in place.
    func scheduleCaptureReview(pendingCount: Int) {
        let id = "capture-review"
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard pendingCount > 0 else { return }
        guard enabled, settings.isEnabled(.captureReview) else {
            requestPermissionThenRetry { [weak self] in self?.scheduleCaptureReview(pendingCount: pendingCount) }
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Capture needs review"
        content.body = pendingCount == 1 ? "One capture still needs review." : "\(pendingCount) captures still need review."
        content.sound = .default
        content.threadIdentifier = id
        content.userInfo = ["kind": "captureReview"]
        applyPrivacy(content, category: .captureReview)

        let fire = adjustedDate(Date().addingTimeInterval(30 * 60))
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        enqueue(UNNotificationRequest(identifier: id, content: content,
                                      trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)),
                source: "capture-review")
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
        upgradeAuthorizationOptionsIfNeeded()
        rescheduleAll(people: people, reminders: reminders, importantDates: importantDates, events: events)
        guard enabled else { return }
        for person in people {
            scheduleRelationshipMaintenance(for: person)
            schedulePeriodicReview(for: person)
        }
        scheduleCaptureReview(pendingCount: pendingCaptureCount)
    }

    /// One-shot catch-up for installs that granted permission before this
    /// app started requesting `.timeSensitive` (see `requestAuthorization`).
    /// Runs on every `reconcile()` (i.e. every launch/foreground) until it
    /// succeeds once, so already-onboarded users silently pick up Focus/DND
    /// breakthrough without needing to find and re-tap anything.
    private func upgradeAuthorizationOptionsIfNeeded() {
        let key = "hasRequestedTimeSensitiveOption"
        guard enabled, !UserDefaults.standard.bool(forKey: key) else { return }
        Task {
            let granted = await requestAuthorization()
            if granted { UserDefaults.standard.set(true, forKey: key) }
            logger.info("upgradeAuthorizationOptions: requestAuthorization()=\(granted, privacy: .public)")
        }
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
    }
}

enum NotificationDeliveryTestError: LocalizedError {
    case permissionDenied

    var errorDescription: String? {
        "Notifications are disabled in iOS Settings."
    }
}
