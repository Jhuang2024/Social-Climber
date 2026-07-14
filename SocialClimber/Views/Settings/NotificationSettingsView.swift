import SwiftUI
import SwiftData
import UserNotifications
import UIKit

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

    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var alertSetting: UNNotificationSetting = .notSupported
    @State private var soundSetting: UNNotificationSetting = .notSupported
    @State private var pendingNotificationCount = 0
    @State private var instagramReminderScheduled = false
    @State private var deliveryMessage: String?
    @State private var isSendingDeliveryTest = false

    var body: some View {
        Form {
            Section {
                Toggle("Notifications", isOn: $masterEnabled)
                    .tint(.green)
                    .onChange(of: masterEnabled) { handleMasterChange() }
                LabeledContent("iOS permission", value: authorizationLabel)
                // Permission being "Allowed" doesn't guarantee a banner ever
                // shows: the user can still have the alert/sound style set
                // to "None" per-app, or Focus/Do Not Disturb active. Those
                // read directly from iOS here so a silent failure is visible
                // without attaching a debugger.
                LabeledContent("Alert style", value: settingLabel(alertSetting))
                LabeledContent("Sound", value: settingLabel(soundSetting))
                LabeledContent("Scheduled alerts", value: "\(pendingNotificationCount)")
                if UserDefaults.standard.bool(forKey: "instagramSyncReminderEnabled") {
                    Label(
                        instagramReminderScheduled ? "10 AM Instagram reminder is scheduled" : "10 AM Instagram reminder is not scheduled",
                        systemImage: instagramReminderScheduled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(instagramReminderScheduled ? Color.green : Color.orange)
                }
                Button {
                    sendDeliveryTest()
                } label: {
                    Label("Send Test Notification", systemImage: "bell.badge")
                }
                if authorizationStatus == .denied {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Open iOS Notification Settings", systemImage: "gear")
                    }
                }
            } footer: {
                Text(deliveryMessage ?? "Everything fires locally on this iPhone. The status above is read directly from iOS.")
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
        .task { await refreshDiagnostics() }
    }

    private func categoryToggle(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: systemImage)
        }
        .tint(.green)
        .onChange(of: isOn.wrappedValue) { reconcile() }
    }

    private func handleMasterChange() {
        guard !isSendingDeliveryTest else { return }
        Task {
            if masterEnabled {
                let granted = await NotificationService.shared.requestAuthorization()
                if !granted {
                    masterEnabled = false
                    return
                }
            }
            reconcile()
            await refreshDiagnostics()
        }
    }

    private func sendDeliveryTest() {
        deliveryMessage = "Scheduling test…"
        Task {
            isSendingDeliveryTest = true
            defer { isSendingDeliveryTest = false }
            do {
                // Reconciliation clears and rebuilds the pending queue. Do it
                // before adding the test request so turning the master switch
                // on cannot immediately erase the test.
                if !masterEnabled {
                    let granted = await NotificationService.shared.requestAuthorization()
                    guard granted else { throw NotificationDeliveryTestError.permissionDenied }
                    masterEnabled = true
                    reconcile()
                }
                try await NotificationService.shared.scheduleDeliveryTest()
                await refreshDiagnostics()
                deliveryMessage = "Scheduled — checking whether iOS actually delivers it…"

                // The trigger fires at 3s; wait past that, then ask iOS
                // directly what happened instead of assuming success from
                // `add` not throwing.
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                let outcome = await NotificationService.shared.checkDeliveryTestOutcome()
                await refreshDiagnostics()
                switch outcome {
                case .stillPending:
                    deliveryMessage = "Still pending after 4s — the trigger hasn't fired yet. Wait a moment and check again."
                case .delivered:
                    if alertSetting == .disabled {
                        deliveryMessage = "iOS delivered it, but this app's Alert style is set to \"None\" in iOS Settings → Notifications, so no banner/sound shows. Tap \"Open iOS Notification Settings\" and set Alert Style to Banners or Alerts."
                    } else {
                        deliveryMessage = "iOS delivered it — check Notification Center or the lock screen. If you still saw nothing, a Focus/Do Not Disturb mode active on this device is silencing it; this isn't something the app controls."
                    }
                case .missing:
                    deliveryMessage = "iOS never delivered it (not pending, not in Notification Center). This points to a device-level notification issue rather than app code — try again, and if it keeps failing, restart the device."
                }
            } catch {
                deliveryMessage = error.localizedDescription
            }
            await refreshDiagnostics()
        }
    }

    private func refreshDiagnostics() async {
        let result = await NotificationService.shared.diagnostics()
        authorizationStatus = result.authorizationStatus
        alertSetting = result.alertSetting
        soundSetting = result.soundSetting
        pendingNotificationCount = result.pendingCount
        instagramReminderScheduled = result.instagramReminderScheduled
    }

    private var authorizationLabel: String {
        switch authorizationStatus {
        case .notDetermined: "Not requested"
        case .denied: "Denied"
        case .authorized: "Allowed"
        case .provisional: "Provisional"
        case .ephemeral: "Temporary"
        @unknown default: "Unknown"
        }
    }

    private func settingLabel(_ setting: UNNotificationSetting) -> String {
        switch setting {
        case .notSupported: "N/A"
        case .disabled: "Off"
        case .enabled: "On"
        @unknown default: "Unknown"
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
