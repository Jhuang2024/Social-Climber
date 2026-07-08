import Foundation

/// Handles the one scenario `SocialClimberApp` can't otherwise recover
/// from on its own: `ModelContainer(for:)` failing to open the existing
/// store at all (corruption, an interrupted write, a migration it can't
/// reconcile). Crashing on every launch from then on is strictly worse
/// than recovering, so this quarantines, never deletes, the unreadable
/// files and lets the app open a fresh store instead. `AppRootView`'s own
/// sudden-zero check then surfaces the recovery screen on the very next
/// launch, since its Keychain baseline still remembers a nonzero count.
enum PersistenceRecovery {
    static func quarantineUnreadableStore(at storeURL: URL) {
        let directory = storeURL.deletingLastPathComponent()
        let quarantineDir = directory.appendingPathComponent("QuarantinedStores", isDirectory: true)
        try? FileManager.default.createDirectory(at: quarantineDir, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let baseName = storeURL.lastPathComponent
        let siblingFiles = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        // Moves the main store file plus its `-wal`/`-shm` sidecars (they
        // all share the store's file name as a prefix), so nothing is left
        // behind that could make the fresh store's own files ambiguous.
        for file in siblingFiles where file.lastPathComponent.hasPrefix(baseName) {
            let destination = quarantineDir.appendingPathComponent("\(stamp)_\(file.lastPathComponent)")
            try? FileManager.default.moveItem(at: file, to: destination)
        }
    }
}
