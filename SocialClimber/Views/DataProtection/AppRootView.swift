import SwiftUI
import SwiftData

/// Sits above `RootTabView` to run a one-time-per-launch data-loss check
/// before the user sees anything. If Social Climber remembers having real
/// data (see `DataLossGuard`) and now finds none, it shows the recovery
/// flow instead of silently continuing as if this were a fresh install.
struct AppRootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var previousCountIfLossDetected: Int?
    @State private var hasChecked = false
    @State private var periodicBackupTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let previousCountIfLossDetected {
                BackupRestoreView(mode: .emergency(previousCount: previousCountIfLossDetected, onResolved: { newCount in
                    DataLossGuard.recordCurrentCount(newCount)
                    self.previousCountIfLossDetected = nil
                }))
            } else if hasChecked {
                RootTabView()
            } else {
                Color.clear
            }
        }
        .task {
            runCheckIfNeeded()
            startPeriodicBackupLoop()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Redundant with `AutoBackupObserver`'s per-save backup and the
            // periodic loop below, on purpose: three independent triggers
            // means no single one of them has to be perfectly reliable.
            // This one also catches the app being backgrounded right before
            // the exact kind of external event (a reinstall, a signing
            // change) that this whole system exists to survive.
            if newPhase == .background {
                BackupManager.createBackup(context: context, reason: "auto-background")
            }
        }
    }

    /// A steady, timing-independent pulse of backups (roughly once a
    /// minute while the app is open) that doesn't depend on `didSave`
    /// notifications ever firing the way `AutoBackupObserver` expects.
    /// Belt-and-suspenders: even if that observer's trigger somehow never
    /// fires for some interaction, this loop still keeps a fresh backup on
    /// disk.
    private func startPeriodicBackupLoop() {
        guard periodicBackupTask == nil else { return }
        periodicBackupTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { return }
                BackupManager.createBackup(context: context, reason: "auto-periodic")
            }
        }
    }

    /// A zero count is only trusted after it's confirmed twice, a beat
    /// apart. Showing the recovery screen is disruptive and scary, so a
    /// single transient bad read (the store still settling right at
    /// launch, a momentary race) must never be enough to trigger it on its
    /// own; only a count that's *still* zero a moment later counts as real.
    private func runCheckIfNeeded() {
        guard !hasChecked else { return }
        let firstReading = RecordCounts.total(in: context)
        guard let previous = DataLossGuard.checkForSuddenLoss(currentCount: firstReading) else {
            DataLossGuard.recordCurrentCount(firstReading)
            hasChecked = true
            return
        }
        Task {
            try? await Task.sleep(nanoseconds: 750_000_000)
            let confirmedReading = RecordCounts.total(in: context)
            if confirmedReading == 0 {
                previousCountIfLossDetected = previous
            } else {
                DataLossGuard.recordCurrentCount(confirmedReading)
            }
            hasChecked = true
        }
    }
}

#Preview {
    AppRootView()
        .modelContainer(PreviewData.container)
}
