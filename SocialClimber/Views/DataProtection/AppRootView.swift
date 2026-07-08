import SwiftUI
import SwiftData

/// Sits above `RootTabView` to run a one-time-per-launch data-loss check
/// before the user sees anything. If Social Climber remembers having real
/// data (see `DataLossGuard`) and now finds none, it shows the recovery
/// flow instead of silently continuing as if this were a fresh install.
struct AppRootView: View {
    @Environment(\.modelContext) private var context
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
