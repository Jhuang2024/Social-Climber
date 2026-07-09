import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Restoring from an automatic backup or a manually-picked JSON file. Used
/// two ways: as a voluntary sheet from Settings (`.voluntary`), and as the
/// full-screen recovery flow `AppRootView` shows when it detects data
/// silently vanished (`.emergency`). Restoring always merges into the live
/// context via `ExportImportService.importData`, the same non-destructive
/// path "Import JSON…" already uses, so a bad or empty backup can only ever
/// add data, never erase what's already there.
struct BackupRestoreView: View {
    enum Mode {
        case voluntary
        case emergency(previousCount: Int, onResolved: (Int) -> Void)
    }

    let mode: Mode

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var backups: [BackupManager.BackupInfo] = []
    @State private var message: String?
    @State private var isRestoring = false
    @State private var hasAutoRestored = false
    @State private var showFileImporter = false
    @State private var confirmContinueEmpty = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    backupList

                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Restore from a different JSON file…", systemImage: "doc.badge.arrow.up")
                    }
                    .buttonStyle(.secondaryCTA)
                    .padding(.horizontal)
                    .disabled(isRestoring)

                    if case .emergency = mode {
                        Button(role: .destructive) {
                            confirmContinueEmpty = true
                        } label: {
                            Text("This is a fresh start, continue without restoring")
                        }
                        .font(.footnote)
                        .padding(.top, 8)
                        .disabled(isRestoring)
                    }
                }
                .padding(.bottom, 28)
            }
            .socialClimberPageBackground()
            .navigationTitle("Restore Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if case .voluntary = mode {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .onAppear {
                backups = BackupManager.listBackups()
                autoRestoreIfPossible()
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    restoreFromFile(url)
                case .failure(let error):
                    message = "Could not read that file: \(error.localizedDescription)"
                }
            }
            .confirmationDialog("Continue with no data?", isPresented: $confirmContinueEmpty, titleVisibility: .visible) {
                Button("Continue Without Restoring", role: .destructive) {
                    if case .emergency(_, let onResolved) = mode { onResolved(0) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Social Climber will treat this as a fresh start. Only do this if you're sure there's really nothing to restore.")
            }
            .alert("Social Climber", isPresented: .init(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        switch mode {
        case .voluntary:
            VStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 40))
                    .foregroundStyle(SCTheme.accent)
                    .padding(.top, 20)
                Text("Restore From Backup")
                    .font(.title3.weight(.bold))
                Text("Restoring merges into what's already here; it never deletes or replaces existing people or interactions.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        case .emergency(let previousCount, _):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                    .padding(.top, 24)
                Text("Your data seems to be missing")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("Social Climber remembers having \(previousCount) record\(previousCount == 1 ? "" : "s") before this launch, but found none this time. This usually happens when something outside the app, like a reinstall or a signing change, reset its storage.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var backupList: some View {
        if backups.isEmpty {
            Text("No automatic backups are available on this device yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Automatic Backups")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal)
                ForEach(backups) { backup in
                    Button {
                        restore(backup)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(backup.reason.replacingOccurrences(of: "-", with: " ").capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.counterclockwise.circle.fill")
                                .foregroundStyle(SCTheme.accent)
                        }
                        .padding(12)
                        .background(SCTheme.cardBackground, in: RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isRestoring)
                }
            }
            .padding(.horizontal)
        }
    }

    /// Restores the newest automatic backup the instant this screen appears
    /// in emergency mode, so a wipe never requires the user to notice this
    /// screen and tap through it themselves — merge-only restore makes this
    /// safe without confirmation. Never runs in `.voluntary` mode, where
    /// picking a specific backup is the whole point of opening this screen.
    /// The manual list stays visible underneath as a fallback for the rare
    /// case nothing is available yet to auto-restore.
    private func autoRestoreIfPossible() {
        guard !hasAutoRestored, case .emergency = mode, let newest = backups.first else { return }
        hasAutoRestored = true
        restore(newest)
    }

    private func restore(_ backup: BackupManager.BackupInfo) {
        guard let data = try? Data(contentsOf: backup.url) else {
            message = "Could not read that backup file."
            return
        }
        performRestore(data: data)
    }

    private func restoreFromFile(_ url: URL) {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            message = "Could not read that file."
            return
        }
        performRestore(data: data)
    }

    /// Refuses to proceed if the source is empty or unreadable, so a
    /// corrupted or blank backup can never masquerade as a successful
    /// restore; otherwise merges via `ExportImportService.importData`,
    /// which only ever adds or updates by name, never deletes.
    private func performRestore(data: Data) {
        guard let count = ExportImportService.recordCount(in: data), count > 0 else {
            message = "That file appears to be empty or unreadable. Nothing was restored."
            return
        }
        isRestoring = true
        do {
            try ExportImportService.importData(data, context: context)
            isRestoring = false
            Haptics.success()
            let newTotal = RecordCounts.total(in: context)
            switch mode {
            case .voluntary:
                DataLossGuard.recordCurrentCount(newTotal)
                message = "Restore complete. \(count) record\(count == 1 ? "" : "s") merged."
            case .emergency(_, let onResolved):
                onResolved(newTotal)
            }
        } catch {
            isRestoring = false
            message = "Restore failed: \(error.localizedDescription)"
        }
    }
}

#Preview {
    BackupRestoreView(mode: .voluntary)
        .modelContainer(PreviewData.container)
}
