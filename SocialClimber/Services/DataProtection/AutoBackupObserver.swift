import Foundation
import SwiftData

/// Watches for ANY SwiftData save, whether from an explicit user action
/// (adding a person, logging an interaction, completing a reminder) or
/// SwiftData's own autosave, and takes a debounced automatic backup
/// shortly after. Debounced rather than one backup per save so a burst of
/// saves in quick succession (bulk edits, autosave firing repeatedly)
/// coalesces into a single write instead of hammering disk on every change.
enum AutoBackupObserver {
    private static var observerToken: NSObjectProtocol?
    private static var pendingTask: Task<Void, Never>?
    private static let debounceNanoseconds: UInt64 = 2_000_000_000

    /// Call once, right after the container is created. Safe to call more
    /// than once; only the first call registers an observer.
    static func start(container: ModelContainer) {
        guard observerToken == nil else { return }
        observerToken = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: .main
        ) { _ in
            scheduleBackup(container: container)
        }
    }

    /// The scheduled work runs on the main actor deliberately: every other
    /// place in this app touches a `ModelContext` only from the main
    /// thread, and creating one concurrently on a background executor here
    /// (as a bare, unisolated `Task` would) risked racing SwiftData's own
    /// autosave on the same store instead of just reading a settled,
    /// consistent snapshot of it.
    private static func scheduleBackup(container: ModelContainer) {
        pendingTask?.cancel()
        pendingTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            let context = ModelContext(container)
            BackupManager.createBackup(context: context, reason: "auto-change")
        }
    }
}
