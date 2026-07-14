import Foundation
import SwiftData
import UserNotifications

/// Handles the post-event "how did it go?" notification actions:
///   • Log it: one neutral event interaction for the known attendees,
///     created right here with no form;
///   • Add note: deep-links into Quick Capture with the event's attendees,
///     date, and location supplied as trusted context;
///   • Skip: marks the prompt dismissed and never re-asks.
/// Every action is idempotent: a re-delivered or double-tapped action can
/// never create a second interaction.
final class NotificationActionHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationActionHandler()
    private override init() { super.init() }

    // Show notifications while the app is foregrounded too.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // The delivery test is fired while Settings is open, so this delegate
        // decides whether the alert is visible. `.banner` alone does not put a
        // foreground notification in Notification Center; if the banner is
        // suppressed the alert appears to vanish despite iOS reporting it as
        // delivered. Always request `.list` as the durable fallback.
        NotificationService.shared.recordForegroundPresentation(
            requestID: notification.request.identifier
        )
        return [.banner, .list, .sound, .badge]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let actionID = response.actionIdentifier
        let kind = userInfo["kind"] as? String

        await MainActor.run {
            switch kind {
            case "scEvent":
                let followUpID = userInfo["followUpID"] as? String
                Self.handleSocialClimberEvent(actionID: actionID, followUpID: followUpID)
            case "gcalEvent":
                Self.handleCalendarEvent(actionID: actionID, userInfo: userInfo)
            default:
                // Reminder / birthday / important-date / maintenance / review /
                // capture-review categories (added by the notification
                // overhaul).
                Self.handleReminderOrContact(
                    actionID: actionID,
                    request: response.notification.request,
                    userInfo: userInfo
                )
            }
        }
    }

    // MARK: Reminders, contacts, and capture review

    @MainActor
    private static func handleReminderOrContact(
        actionID: String,
        request: UNNotificationRequest,
        userInfo: [AnyHashable: Any]
    ) {
        let action = NotificationAction(rawValue: actionID)
        let personName = userInfo["personName"] as? String

        switch action {
        case .snooze:
            snooze(request: request)
            return
        case .markComplete:
            completeReminder(notificationID: request.identifier)
            return
        case .openContact:
            route(personName?.isEmpty == false ? .contact(name: personName!) : .reminders)
            return
        case .logInteraction:
            route(.logInteraction(personName: personName))
            return
        case .reviewCapture:
            route(.captureReview)
            return
        case .openReminder:
            route(.reminders)
            return
        case .none:
            break
        }

        // Default tap (no explicit action): route by category.
        let category = (userInfo["category"] as? String).flatMap(NotificationCategory.init(rawValue:))
        switch category {
        case .captureReview:
            route(.captureReview)
        case .birthday, .event, .importantDate, .relationshipMaintenance, .periodicReview:
            route(personName?.isEmpty == false ? .contact(name: personName!) : .reminders)
        default:
            route(.reminders)
        }
    }

    @MainActor
    private static func route(_ destination: NotificationRouter.Destination) {
        NotificationRouter.shared.request(destination)
    }

    @MainActor
    private static func completeReminder(notificationID: String) {
        let context = AppServices.container.mainContext
        let all = (try? context.fetch(FetchDescriptor<Reminder>())) ?? []
        guard let reminder = all.first(where: { $0.notificationID == notificationID }) else { return }
        reminder.completed = true
        NotificationService.shared.cancel(reminder: reminder)
        try? context.save()
    }

    /// Re-fires the same notification after the user's default snooze duration,
    /// reusing its content so it keeps its category/actions.
    private static func snooze(request: UNNotificationRequest) {
        let minutes = NotificationSettings().defaultSnoozeMinutes
        let interval = TimeInterval(max(1, minutes) * 60)
        let content = request.content.mutableCopy() as? UNMutableNotificationContent ?? UNMutableNotificationContent()
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger)
        )
    }

    // MARK: Social Climber events

    @MainActor
    private static func handleSocialClimberEvent(actionID: String, followUpID: String?) {
        guard let followUpID else { return }
        let context = AppServices.container.mainContext
        let descriptor = FetchDescriptor<Event>(predicate: #Predicate { $0.followUpNotificationID == followUpID })
        guard let event = (try? context.fetch(descriptor))?.first else { return }

        switch actionID {
        case NotificationService.eventLogActionID, UNNotificationDefaultActionIdentifier:
            // Idempotent: an already-logged event never gets a second
            // interaction, however many times the action fires.
            guard event.loggedAt == nil, !event.attendees.isEmpty else { break }
            let interaction = Interaction(
                type: .event,
                date: event.date,
                location: event.location,
                quality: 3,
                messageSummary: "At \(event.name.isEmpty ? "an event" : event.name)"
            )
            InteractionSaver.finalize(interaction, people: event.attendees, context: context)
            event.loggedAt = .now
            event.followUpNotificationID = nil
            try? context.save()

        case NotificationService.eventAddNoteActionID:
            QuickCaptureRouter.shared.open(event: event)

        case NotificationService.eventSkipActionID:
            event.followUpDismissedAt = .now
            event.followUpNotificationID = nil
            try? context.save()

        default:
            break
        }
    }

    // MARK: Matched Google Calendar events

    private static let gcalLoggedKey = "gcalFollowUpsLogged"

    @MainActor
    private static func handleCalendarEvent(actionID: String, userInfo: [AnyHashable: Any]) {
        guard let gcalID = userInfo["gcalID"] as? String else { return }
        let title = userInfo["title"] as? String ?? "Calendar event"
        let location = userInfo["location"] as? String ?? ""
        let attendeeNames = userInfo["attendees"] as? [String] ?? []
        let attendeeIDs = (userInfo["attendeeIDs"] as? [String] ?? []).compactMap(UUID.init)
        let date = (userInfo["dateEpoch"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) } ?? .now

        let context = AppServices.container.mainContext
        let allPeople = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        // IDs are authoritative; name matching is only a fallback for a
        // notification scheduled before this field existed.
        let people: [Person] = !attendeeIDs.isEmpty
            ? CapturedMemory.resolvePeople(ids: attendeeIDs, in: allPeople)
            : attendeeNames.compactMap { name in allPeople.first { $0.name == name } }

        switch actionID {
        case NotificationService.eventLogActionID, UNNotificationDefaultActionIdentifier:
            // Idempotent via a persisted handled-set keyed by the calendar
            // event's own id.
            var logged = Set(UserDefaults.standard.stringArray(forKey: gcalLoggedKey) ?? [])
            guard !logged.contains(gcalID), !people.isEmpty else { break }
            logged.insert(gcalID)
            UserDefaults.standard.set(Array(logged), forKey: gcalLoggedKey)

            let interaction = Interaction(
                type: .event,
                date: date,
                location: location,
                quality: 3,
                messageSummary: "At \(title)"
            )
            InteractionSaver.finalize(interaction, people: people, context: context)
            try? context.save()

        case NotificationService.eventAddNoteActionID:
            QuickCaptureRouter.shared.open(QuickCaptureRequest(
                trustedPersonIDs: people.map(\.uuid),
                trustedPersonNames: attendeeNames,
                eventContext: CaptureEventContext(name: title, date: date, location: location, attendeeIDs: people.map(\.uuid), attendeeNames: attendeeNames)
            ))

        case NotificationService.eventSkipActionID:
            var logged = Set(UserDefaults.standard.stringArray(forKey: gcalLoggedKey) ?? [])
            logged.insert(gcalID)
            UserDefaults.standard.set(Array(logged), forKey: gcalLoggedKey)

        default:
            break
        }
    }
}
