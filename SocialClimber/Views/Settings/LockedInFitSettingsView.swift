import SwiftUI

/// The Settings screen for the small App Group bridge with LockedInFit: a
/// single toggle gating both directions, live status of the bridge itself,
/// and full disclosure of exactly what crosses the boundary each way.
struct LockedInFitSettingsView: View {
    @AppStorage("crossAppSharingEnabled") private var sharingEnabled = true

    var body: some View {
        Form {
            Section {
                Toggle("Share context with LockedInFit", isOn: $sharingEnabled)
                    .tint(.green)
            } footer: {
                Text("When on, Social Climber publishes a small daily summary (today's social intensity, upcoming event context, and today's social task titles) for LockedInFit to read, and quiets low-priority check-ins and suggestions on days LockedInFit reports low energy or recovery. Turn this off to keep Social Climber fully self-contained.")
            }

            Section("Status") {
                LabeledContent("App Group") {
                    Text(CrossAppIntegrationManager.isAppGroupAvailable ? "Available" : "Not available on this build")
                        .foregroundStyle(CrossAppIntegrationManager.isAppGroupAvailable ? .green : .secondary)
                }
                LabeledContent("LockedInFit") {
                    linkStatusLabel
                }
                if let lastUpdated {
                    LabeledContent("Last updated", value: lastUpdated.formatted(date: .abbreviated, time: .shortened))
                }
            }

            Section {
                Text("Social Climber publishes only today's social-intensity level, today's social task titles, and clean event-prep context (type, timing, importance) for upcoming events. It never shares guest lists, private notes, exact locations, or message content. In return, it can read LockedInFit's energy, recovery, sleep, and workout/nutrition status to decide how much social noise to show today, but it never edits LockedInFit's logs, workouts, meals, or health data, and LockedInFit never edits Social Climber's people, interactions, or reminders. A snapshot older than 24 hours is treated as if it doesn't exist. Neither app can read the other's private database: only this one small shared file each way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("How this works")
            }
        }
        .scrollContentBackground(.hidden)
        .background(SCTheme.pageBackground)
        .navigationTitle("LockedInFit")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The raw `updatedAt` from LockedInFit's file, shown whenever a file
    /// was found at all, even a stale one, distinct from whether Social
    /// Climber currently treats it as usable.
    private var lastUpdated: Date? {
        switch CrossAppIntegrationManager.linkStatus() {
        case .notDetected: nil
        case .stale(let updatedAt), .linked(let updatedAt): updatedAt
        }
    }

    @ViewBuilder
    private var linkStatusLabel: some View {
        switch CrossAppIntegrationManager.linkStatus() {
        case .linked:
            Text("Linked").foregroundStyle(.green)
        case .stale:
            Text("Found, but stale").foregroundStyle(.secondary)
        case .notDetected:
            Text("Not detected").foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack {
        LockedInFitSettingsView()
    }
}
