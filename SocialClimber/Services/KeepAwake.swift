import UIKit

/// Keeps the device from auto-locking while a long, user-initiated,
/// foreground job runs — the Instagram Drive sync (download + unzip +
/// parse) and the review sheet's apply/extraction pass. iOS suspends the
/// process the moment the screen sleeps, which killed those jobs midway;
/// no background entitlement covers an on-demand Drive pull, so the
/// honest fix is holding the screen awake for the duration.
///
/// Reference-counted so overlapping jobs (a sync finishing while an
/// apply starts) never re-enable the idle timer early. While any job is
/// active it also holds a background-task assertion, so an explicit
/// side-button lock or a quick app switch grants the job iOS's ~30
/// seconds of grace to finish or reach a resumable point instead of
/// being suspended instantly.
@MainActor
enum KeepAwake {
    private static var count = 0
    private static var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// Runs `work` with the device held awake, balancing begin/end even
    /// when `work` throws.
    static func during<T>(_ name: String, work: () async throws -> T) async rethrows -> T {
        begin(name)
        defer { end() }
        return try await work()
    }

    static func begin(_ name: String) {
        count += 1
        UIApplication.shared.isIdleTimerDisabled = true
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: name) {
            // iOS is about to suspend us regardless; hand the assertion
            // back immediately so the app isn't killed for overrunning.
            // Both guarded jobs are safe to re-run: sync's per-thread
            // cutoffs only advance on apply, and apply is idempotent.
            Task { @MainActor in releaseBackgroundTask() }
        }
    }

    static func end() {
        count = max(0, count - 1)
        guard count == 0 else { return }
        UIApplication.shared.isIdleTimerDisabled = false
        releaseBackgroundTask()
    }

    private static func releaseBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
