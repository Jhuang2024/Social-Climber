import Foundation
import OSLog

/// Logs whenever the resolved SwiftData store path changes between
/// launches, the same signal that, in hindsight, would have flagged the
/// reinstall that wiped Social Climber's data after an entitlements change.
/// Logging only: this never acts on the change itself, just makes it
/// visible in the device console for debugging a future incident.
enum PersistenceGuard {
    private static let lastPathKey = "lastKnownStorePath"
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SocialClimber", category: "PersistenceGuard")

    static func checkAndLogPathChange(currentPath: String) {
        let defaults = UserDefaults.standard
        if let previous = defaults.string(forKey: lastPathKey), previous != currentPath {
            logger.warning("Persistence store path changed.\nPrevious: \(previous, privacy: .public)\nCurrent: \(currentPath, privacy: .public)")
        }
        defaults.set(currentPath, forKey: lastPathKey)
    }
}
