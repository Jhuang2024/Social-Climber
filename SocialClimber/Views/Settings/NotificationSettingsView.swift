import SwiftUI
import SwiftData

/// The dedicated Notifications settings screen: master switch, per-category
/// toggles, quiet hours, preview privacy, snooze, and reminder-frequency
/// controls. Uses the same Form/section visual language as the rest of
/// Settings. Any change reconciles the scheduled notifications immediately so
/// the pending set always matches the user's choices.
struct NotificationSettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var people: [Person]
    @Query private var reminders: [Reminder]
    @Query private var importantDates: [ImportantDate]
    @Query private var events: [Event]
    @Query private var voiceNotes: [VoiceNote]

    typealias K = NotificationSettings.Key

    @AppStorage(K.masterEnabled) private var masterEnabled = false
    @AppStorage(K.explicitReminders) private var explicitReminders = true
    @AppStorage(K.followUps) private var followUps = true
    @AppStorage(K.events) private var events_ = true
    @AppStorage(K.birthdays) private var birthdays = true
    @AppStorage(K.importantDates) private var importantDates_ = true
    @AppStorage(K.relationshipMaintenance) private var relationshipMaintenance = true
    @AppStorage(K.captureFailures) private var captureFailures = true
    @AppStorage(K.periodicReview) private var periodicReview = false

    @AppStorage(K.quietHoursEnabled) private var quietHoursEnabled = false
    @AppStorage(K.quietHoursStartHour) private var quietStart = 22
    @AppStorage(K.quietHoursEndHour) private var quietEnd = 8

    @AppStorage(K.detailedPreviews) private var detailedPreviews = false
    @AppStorage(K.defaultSnoozeMinutes) private var snoozeMinutes = 60
    @AppStorage(K.reviewFrequencyDays) private var reviewFrequencyDays = 30

    // Shared with the "Check-In Cadence Defaults" section: same keys, so they
    // stay in lock-step wherever the user edits them.
    @AppStorage("defaultCadenceClose") private var cadenceClose = 21
    @AppStorage("defaultCadenceRegular") private var cadenceRegular = 60
    @AppStorage("defaultCadenceDistant") private var cadenceDistant = 120

    var body: some View {
        Form {
            Section {
                Toggle("Notifications", isOn: $masterEnabled)
                    .tint(.green)
                    .onChange(of: masterEnabled) { handleMasterChange() }
            } footer: {
                Text("Everything fires locally on this iPhone. Nothing is ever sent anywhere.")
            }

            Section("Categories") {
                categoryToggle("Explicit reminders", systemImage: "bell", isOn: $explicitReminders)
                categoryToggle("Follow-ups", systemImage: "arrow.turn.down.right", isOn: $followUps)
                categoryToggle("Events", systemImage: "calendar", isOn: $events_)
                categoryToggle("Birthdays", systemImage: "gift", isOn: $birthdays)
                categoryToggle("Important dates", systemImage: "star", isOn: $importantDates_)
                categoryToggle("Relationship maintenance", systemImage: "heart", isOn: $relationshipMaintenance)
                categoryToggle("Capture processing failures", systemImage: "waveform.badge.exclamationmark", isOn: $captureFailures)
                categoryToggle("Periodic contact reviews", systemImage: "arrow.triangle.2.circlepath", isOn: $periodicReview)
            }
            .disabled(!masterEnabled)

            Section {
                Toggle("Quiet hours", isOn: $quietHoursEnabled)
                    .tint(.green)
                    .onChange(of: quietHoursEnabled) { reconcile() }
                if quietHoursEnabled {
                    Stepper("From \(hourLabel(quietStart))", value: $quietStart, in: 0...23)
                        .onChange(of: quietStart) { reconcile() }
                    Stepper("Until \(hourLabel(quietEnd))", value: $quietEnd, in: 0...23)
                        .onChange(of: quietEnd) { reconcile() }
                }
            } header: {
                Text("Quiet Hours")
            } footer: {
                Text("During quiet hours, alerts are held until the window ends. Times follow this device's time zone automatically.")
            }
            .disabled(!masterEnabled)

            Section {
                Toggle("Show details in previews", isOn: $detailedPreviews)
                    .tint(.green)
                    .onChange(of: detailedPreviews) { reconcile() }
            } header: {
                Text("Preview Privacy")
            } footer: {
                Text(detailedPreviews
                     ? "Notifications may show names and details on the lock screen."
                     : "Notifications stay generic (e.g. \"A saved reminder is due.\") and never reveal relationship notes on the lock screen.")
            }
            .disabled(!masterEnabled)

            Section {
                Stepper("Default snooze: \(snoozeMinutes) min", value: $snoozeMinutes, in: 5...240, step: 5)
            } header: {
                Text("Snooze")
            } footer: {
                Text("How long the Snooze action postpones an alert.")
            }
            .disabled(!masterEnabled)

            Section {
                Stepper("Top priority: every \(cadenceClose)d", value: $cadenceClose, in: 7...90, step: 7)
                Stepper("Regular priority: every \(cadenceRegular)d", value: $cadenceRegular, in: 14...180, step: 7)
                Stepper("Low priority: every \(cadenceDistant)d", value: $cadenceDistant, in: 30...365, step: 15)
                Stepper("Periodic review: every \(reviewFrequencyDays)d", value: $reviewFrequencyDays, in: 7...180, step: 7)
                    .onChange(of: reviewFrequencyDays) { reconcile() }
            } header: {
                Text("Reminder Frequency")
            } footer: {
                Text("How often relationship-maintenance and periodic-review reminders surface. Per-person cadence on a profile always overrides these.")
            }
            .disabled(!masterEnabled)
        }
        .scrollContentBackground(.hidden)
        .background(SCTheme.pageBackground)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func categoryToggle(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: systemImage)
        }
        .tint(.green)
        .onChange(of: isOn.wrappedValue) { reconcile() }
    }

    private func handleMasterChange() {
        Task {
            if masterEnabled {
                let granted = await NotificationService.shared.requestAuthorization()
                if !granted {
                    masterEnabled = false
                    return
                }
            }
            reconcile()
        }
    }

    /// Rebuilds the scheduled set from current settings + data. Idempotent.
    private func reconcile() {
        let pendingCaptures = voiceNotes.filter {
            $0.processingState == .failed && ($0.failureReason?.isRetryable ?? false)
        }.count
        NotificationService.shared.reconcile(
            people: people,
            reminders: reminders,
            importantDates: importantDates,
            events: events,
            pendingCaptureCount: pendingCaptures
        )
        try? context.save()
    }

    private func hourLabel(_ hour: Int) -> String {
        var comps = DateComponents()
        comps.hour = hour
        let date = Calendar.current.date(from: comps) ?? .now
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        return formatter.string(from: date)
    }
}

#Preview {
    NavigationStack {
        NotificationSettingsView()
            .modelContainer(PreviewData.container)
    }
}
