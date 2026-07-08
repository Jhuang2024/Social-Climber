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
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Redundant with `AutoBackupObserver`'s per-save backup, on
            // purpose: this also catches the app being backgrounded right
            // before the exact kind of external event (a reinstall, a
            // signing change) that this whole system exists to survive.
            if newPhase == .background {
                BackupManager.createBackup(context: context, reason: "auto-background")
            }
        }
    }

    private func runCheckIfNeeded() {
        guard !hasChecked else { return }
        let currentCount = RecordCounts.total(in: context)
        if let previous = DataLossGuard.checkForSuddenLoss(currentCount: currentCount) {
            previousCountIfLossDetected = previous
        } else {
            DataLossGuard.recordCurrentCount(currentCount)
        }
        hasChecked = true
    }
}

#Preview {
    AppRootView()
        .modelContainer(PreviewData.container)
}
