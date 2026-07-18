import SwiftUI
import SwiftData

/// The daily "pull the latest Meta export from Drive" action, shared by the
/// Home dashboard (`.card`) and Social Health (`.inline`). Owns the whole
/// run: progress while syncing, the review sheet on success, an alert on
/// failure. Connection management (connect/disconnect, folder name, the
/// reminder toggle) stays in Settings; this control assumes Google Drive is
/// already connected and should not be shown otherwise.
struct InstagramSyncControl: View {
    enum Style {
        /// A standalone tappable card for the Home dashboard.
        case card
        /// A compact action row for embedding inside another card
        /// (Social Health's Instagram card).
        case inline
    }

    let style: Style

    @Environment(\.modelContext) private var context
    @Query private var people: [Person]

    @State private var syncResult: InstagramSyncResultBox?
    @State private var errorMessage: String?

    private var instagramSync: InstagramSyncService { InstagramSyncService.shared }

    var body: some View {
        Button {
            runSync()
        } label: {
            switch style {
            case .card: cardLabel
            case .inline: inlineLabel
            }
        }
        .buttonStyle(.pressable)
        .disabled(instagramSync.isSyncing)
        .sheet(item: $syncResult) { box in
            InstagramSyncReviewView(result: box.result)
        }
        .alert("Instagram Sync", isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Labels

    private var statusText: String {
        if instagramSync.isSyncing {
            return instagramSync.progressText.isEmpty ? "Syncing…" : instagramSync.progressText
        }
        if let lastSync = instagramSync.lastSyncAt {
            return "Last synced \(lastSync.relativeLabel)"
        }
        return "Pull today's Meta export from Drive"
    }

    /// The determinate bar + countdown for the phase currently running.
    /// Only shown once the phase knows its length; phases that can't be
    /// measured keep the spinner instead.
    @ViewBuilder
    private var progressBar: some View {
        let progress = instagramSync.progress
        if instagramSync.isSyncing, progress.isDeterminate {
            SyncProgressBar(
                fraction: progress.fraction,
                countText: progress.countText,
                tint: SCTheme.Accents.warm
            )
            .padding(.top, 4)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: progress)
        }
    }

    private var cardLabel: some View {
        HStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SCTheme.Accents.warm)
                .frame(width: 44, height: 44)
                .background(SCTheme.Accents.warm.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Instagram Sync")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                progressBar
            }
            Spacer()
            // The determinate bar carries the "syncing" signal itself, so the
            // trailing spinner only shows for phases that can't be measured.
            if instagramSync.isSyncing {
                if !instagramSync.progress.isDeterminate {
                    ProgressView()
                }
            } else {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SCTheme.Accents.warm)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(SCTheme.Accents.warm.opacity(0.14), in: Capsule())
            }
        }
        .scCard(padding: 14)
    }

    private var inlineLabel: some View {
        Group {
            if instagramSync.isSyncing {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if !instagramSync.progress.isDeterminate {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(statusText)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    progressBar
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.subheadline.weight(.semibold))
                    Text("Sync Now")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    if let lastSync = instagramSync.lastSyncAt {
                        Text(lastSync.relativeLabel)
                            .font(.caption)
                            .opacity(0.7)
                    }
                }
            }
        }
        .foregroundStyle(SCTheme.accent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(SCTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous))
    }

    // MARK: Run

    private func runSync() {
        guard !instagramSync.isSyncing else { return }
        Task {
            do {
                let result = try await instagramSync.sync(people: people, context: context)
                Haptics.success()
                syncResult = InstagramSyncResultBox(result: result)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Wraps a sync result so it can drive a `.sheet(item:)`.
struct InstagramSyncResultBox: Identifiable {
    let id = UUID()
    let result: InstagramSyncService.SyncResult
}

#Preview {
    VStack(spacing: 16) {
        InstagramSyncControl(style: .card)
        InstagramSyncControl(style: .inline)
    }
    .padding()
    .modelContainer(PreviewData.container)
}
