import Foundation

/// Pure quiet-hours math: given a desired fire time and a quiet window, returns
/// a fire time that respects the window. Kept free of `UserNotifications` and
/// side effects so time-zone and boundary behaviour is unit-testable with an
/// injected `Calendar`.
enum QuietHours {

    /// Whether `hour` (0...23) falls inside the quiet window `[startHour,
    /// endHour)`. Handles overnight windows (e.g. 22 → 8) as well as same-day
    /// ones (e.g. 1 → 6). A window where start == end is treated as "no quiet
    /// hours" (never quiet) rather than "always quiet".
    static func isQuiet(hour: Int, startHour: Int, endHour: Int) -> Bool {
        guard startHour != endHour else { return false }
        if startHour < endHour {
            return hour >= startHour && hour < endHour
        } else {
            // Overnight: quiet from start through midnight to end.
            return hour >= startHour || hour < endHour
        }
    }

    /// If `date` lands in quiet hours, pushes it forward to the next `endHour`
    /// boundary; otherwise returns it unchanged. Uses `calendar` (and therefore
    /// its time zone) throughout, so a device whose time zone changed simply
    /// recomputes against the new local hours.
    static func adjustedFireDate(
        _ date: Date,
        startHour: Int,
        endHour: Int,
        calendar: Calendar = .current
    ) -> Date {
        let hour = calendar.component(.hour, from: date)
        guard isQuiet(hour: hour, startHour: startHour, endHour: endHour) else { return date }

        // Move to endHour:00. If the window is overnight and we're in the
        // late-evening part (hour >= startHour), the boundary is the *next*
        // day; otherwise it's later today.
        var target = calendar.startOfDay(for: date)
        let crossesMidnight = startHour > endHour
        if crossesMidnight && hour >= startHour {
            target = calendar.date(byAdding: .day, value: 1, to: target) ?? target
        }
        return calendar.date(bySettingHour: endHour, minute: 0, second: 0, of: target) ?? date
    }
}

/// Actions attached to notifications, matching the product spec. Identifiers
/// are stable strings the delegate switches on.
enum NotificationAction: String {
    case markComplete = "sc.action.markComplete"
    case snooze = "sc.action.snooze"
    case openReminder = "sc.action.openReminder"
    case openContact = "sc.action.openContact"
    case reviewCapture = "sc.action.reviewCapture"
    case logInteraction = "sc.action.logInteraction"

    var title: String {
        switch self {
        case .markComplete: return "Mark Complete"
        case .snooze: return "Snooze"
        case .openReminder: return "Open Reminder"
        case .openContact: return "Open Contact"
        case .reviewCapture: return "Review Capture"
        case .logInteraction: return "Log Interaction"
        }
    }

    /// Actions that must bring the app forward to complete (open/log/review),
    /// versus ones handled silently in the background (complete/snooze).
    var opensApp: Bool {
        switch self {
        case .openReminder, .openContact, .reviewCapture, .logInteraction: return true
        case .markComplete, .snooze: return false
        }
    }
}
