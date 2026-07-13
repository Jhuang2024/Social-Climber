import Foundation

/// All user-controllable notification preferences, backed by `UserDefaults` so
/// the same values are readable from `NotificationService` (no SwiftUI) and
/// bindable from Settings (via `@AppStorage` on the same keys).
///
/// One struct means the service and the UI can never disagree about what's
/// enabled, and the defaults live in exactly one place.
struct NotificationSettings {

    // MARK: Keys (shared verbatim with @AppStorage in SettingsView)

    enum Key {
        static let masterEnabled = "notificationsEnabled"
        static let explicitReminders = "notifyExplicitReminders"
        static let events = "notifyEvents"
        static let birthdays = "notifyBirthdays"
        static let importantDates = "notifyImportantDates"
        static let relationshipMaintenance = "notifyRelationshipMaintenance"
        static let captureFailures = "notifyCaptureFailures"
        static let followUps = "notifyFollowUps"
        static let periodicReview = "notifyPeriodicReview"

        static let quietHoursEnabled = "quietHoursEnabled"
        static let quietHoursStartHour = "quietHoursStartHour"
        static let quietHoursEndHour = "quietHoursEndHour"

        static let detailedPreviews = "notificationDetailedPreviews"
        static let defaultSnoozeMinutes = "notificationDefaultSnoozeMinutes"
        static let reviewFrequencyDays = "notificationReviewFrequencyDays"
    }

    // MARK: Defaults

    /// Registers default values once, so a brand-new install has sensible
    /// category settings (all on except detailed previews and quiet hours)
    /// without every read needing to special-case "never set".
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.explicitReminders: true,
            Key.events: true,
            Key.birthdays: true,
            Key.importantDates: true,
            Key.relationshipMaintenance: true,
            Key.captureFailures: true,
            Key.followUps: true,
            Key.periodicReview: false,
            Key.quietHoursEnabled: false,
            Key.quietHoursStartHour: 22,
            Key.quietHoursEndHour: 8,
            Key.detailedPreviews: false,
            Key.defaultSnoozeMinutes: 60,
            Key.reviewFrequencyDays: 30,
        ])
    }

    // MARK: Reads

    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var masterEnabled: Bool { defaults.bool(forKey: Key.masterEnabled) }

    func isEnabled(_ category: NotificationCategory) -> Bool {
        guard masterEnabled else { return false }
        guard let key = category.settingKey else { return true }
        // Fall back to `true` when unset so registerDefaults not having run yet
        // (e.g. in a unit test) doesn't silently disable everything.
        return defaults.object(forKey: key) as? Bool ?? true
    }

    var detailedPreviews: Bool { defaults.bool(forKey: Key.detailedPreviews) }
    var quietHoursEnabled: Bool { defaults.bool(forKey: Key.quietHoursEnabled) }
    var quietHoursStartHour: Int { value(Key.quietHoursStartHour, default: 22) }
    var quietHoursEndHour: Int { value(Key.quietHoursEndHour, default: 8) }
    var defaultSnoozeMinutes: Int { value(Key.defaultSnoozeMinutes, default: 60) }
    var reviewFrequencyDays: Int { value(Key.reviewFrequencyDays, default: 30) }

    private func value(_ key: String, default def: Int) -> Int {
        (defaults.object(forKey: key) as? Int) ?? def
    }
}

/// The notification categories Social Climber schedules. Each carries its
/// settings key (nil = always-on when master is on), the iOS category
/// identifier used to attach actions, and a privacy-safe generic message shown
/// unless detailed previews are enabled.
enum NotificationCategory: String, CaseIterable {
    case explicitReminder
    case followUp
    case event
    case birthday
    case importantDate
    case relationshipMaintenance
    case overdueFollowUp
    case captureReview
    case periodicReview

    /// Settings key gating this category. `nil` means it follows only the
    /// master toggle.
    var settingKey: String? {
        switch self {
        case .explicitReminder: return NotificationSettings.Key.explicitReminders
        case .followUp, .overdueFollowUp: return NotificationSettings.Key.followUps
        case .event: return NotificationSettings.Key.events
        case .birthday: return NotificationSettings.Key.birthdays
        case .importantDate: return NotificationSettings.Key.importantDates
        case .relationshipMaintenance: return NotificationSettings.Key.relationshipMaintenance
        case .captureReview: return NotificationSettings.Key.captureFailures
        case .periodicReview: return NotificationSettings.Key.periodicReview
        }
    }

    /// The iOS `UNNotificationCategory` identifier (drives which actions show).
    var identifier: String { "sc.\(rawValue)" }

    /// Generic, privacy-safe body used by default; never names a person or
    /// reveals note content on the lock screen.
    var genericBody: String {
        switch self {
        case .explicitReminder: return "A saved reminder is due."
        case .followUp: return "You have a follow-up due today."
        case .overdueFollowUp: return "You have an overdue follow-up."
        case .event: return "An upcoming event may need preparation."
        case .birthday: return "Someone's birthday is today."
        case .importantDate: return "An important date is today."
        case .relationshipMaintenance: return "A relationship could use a check-in."
        case .captureReview: return "One capture still needs review."
        case .periodicReview: return "Time for a relationship review."
        }
    }

    /// Generic title used with privacy-safe previews.
    var genericTitle: String {
        switch self {
        case .explicitReminder, .followUp, .overdueFollowUp: return "Reminder"
        case .event: return "Upcoming event"
        case .birthday: return "Birthday"
        case .importantDate: return "Important date"
        case .relationshipMaintenance, .periodicReview: return "Social Climber"
        case .captureReview: return "Capture needs review"
        }
    }
}
