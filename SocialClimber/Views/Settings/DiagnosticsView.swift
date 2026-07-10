#if DEBUG
import SwiftUI
import SwiftData

/// Debug-only diagnostics for the data-protection system: exactly where
/// Social Climber's data lives, what SwiftData resolved the App Group to,
/// and current record counts. Entirely excluded from Release builds, both
/// this file and its entry point in `SettingsView`.
struct DiagnosticsView: View {
    @Environment(\.modelContext) private var context

    @State private var isRunningIntegrityCheck = false
    @State private var integrityResults: [CaptureIntegrityValidator.CheckResult] = []

    var body: some View {
        Form {
            Section("App") {
                LabeledContent("Bundle Identifier", value: Bundle.main.bundleIdentifier ?? "unknown")
            }

            Section {
                Button {
                    Task {
                        isRunningIntegrityCheck = true
                        integrityResults = await CaptureIntegrityValidator.run(context: context)
                        isRunningIntegrityCheck = false
                    }
                } label: {
                    if isRunningIntegrityCheck {
                        HStack { ProgressView(); Text("Running…") }
                    } else {
                        Text("Run Capture Integrity Checks")
                    }
                }
                .disabled(isRunningIntegrityCheck)
                ForEach(integrityResults) { result in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.name).font(.caption)
                            if !result.detail.isEmpty {
                                Text(result.detail).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(result.passed ? .green : .red)
                    }
                }
                if !integrityResults.isEmpty {
                    let failed = integrityResults.filter { !$0.passed }.count
                    Text(failed == 0 ? "All \(integrityResults.count) checks passed." : "\(failed) of \(integrityResults.count) checks FAILED.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(failed == 0 ? .green : .red)
                }
            } header: {
                Text("Capture Pipeline Integrity")
            } footer: {
                Text("Creates and fully removes its own throwaway test people/captures — never touches real data. Exercises undo completeness, idempotent reprocessing, no-invented-dates, and multi-person attribution against the real pipeline.")
            }

            Section("Persistence") {
                LabeledContent("Store Path") {
                    Text(storePath)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                LabeledContent("Store Files") {
                    Text(storeFileNames)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                LabeledContent("App Group Path") {
                    Text(appGroupPath)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }

            Section("Record Counts") {
                ForEach(RecordCounts.breakdown(in: context)) { entry in
                    LabeledContent(entry.label, value: "\(entry.count)")
                }
            }

            Section("Backups") {
                LabeledContent("Latest Backup", value: latestBackupText)
                LabeledContent("Backups Kept", value: "\(BackupManager.listBackups().count)")
                LabeledContent("Backups Directory") {
                    Text(BackupManager.backupsDirectory.path)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var storeURL: URL? {
        context.container.configurations.first?.url
    }

    private var storePath: String {
        storeURL?.path ?? "unavailable"
    }

    private var storeFileNames: String {
        guard let storeURL else { return "unavailable" }
        let directory = storeURL.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let matching = files.filter { $0.hasPrefix(storeURL.lastPathComponent) }
        return matching.isEmpty ? "none found" : matching.sorted().joined(separator: "\n")
    }

    private var appGroupPath: String {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: CrossAppIntegrationManager.appGroupID)?.path
            ?? "unavailable (App Group not provisioned)"
    }

    private var latestBackupText: String {
        guard let date = BackupManager.latestBackupTimestamp() else { return "none yet" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

#Preview {
    NavigationStack {
        DiagnosticsView()
            .modelContainer(PreviewData.container)
    }
}
#endif
