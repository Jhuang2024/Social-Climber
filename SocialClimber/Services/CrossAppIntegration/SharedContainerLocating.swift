import Foundation

/// Abstracts "where is the shared App Group container on disk" so the rest
/// of the bridge never touches `FileManager` directly. Returns `nil`
/// whenever the App Group entitlement isn't provisioned for this build
/// instead of throwing: the container simply not existing is an expected,
/// everyday case (LockedInFit not installed, or this build not signed with
/// the group yet), not an error.
protocol SharedContainerLocating {
    func containerURL() -> URL?
}

/// The real implementation, backed by the App Group Social Climber shares
/// with LockedInFit.
struct AppGroupContainerLocator: SharedContainerLocating {
    let appGroupID: String

    func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }
}
