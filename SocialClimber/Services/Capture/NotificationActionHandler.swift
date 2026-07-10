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
        [.banner, .sound, .badge]
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
                break
            }
        }
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
