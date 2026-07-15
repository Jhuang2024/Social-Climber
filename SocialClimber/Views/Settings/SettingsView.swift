import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query private var people: [Person]
    @Query private var reminders: [Reminder]
    @Query private var importantDates: [ImportantDate]
    @Query private var events: [Event]

    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @AppStorage("locationEnabled") private var locationEnabled = false
    @AppStorage("googleClientID") private var googleClientID = "201027748898-lerfifmsfgdu2uubgph606p2rsa6ic7j.apps.googleusercontent.com"
    @AppStorage("aiProvider") private var aiProvider = AIProvider.mock.rawValue
    @AppStorage("bazaarLinkModelID") private var bazaarLinkModelID = BazaarLinkDefaults.modelID
    @AppStorage("defaultCadenceClose") private var cadenceClose = 21
    @AppStorage("defaultCadenceRegular") private var cadenceRegular = 60
    @AppStorage("defaultCadenceDistant") private var cadenceDistant = 120

    @State private var exportItem: ShareURL?
    @State private var showImporter = false
    @State private var showBackupRestore = false
    @State private var confirmClear = false
    @State private var confirmImport = false
    @State private var pendingImportData: Data?
    @State private var pendingImportName = ""
    @State private var openRouterAPIKey = ""
    @State private var hasOpenRouterAPIKey = false
    @State private var bazaarLinkAPIKey = ""
    @State private var hasBazaarLinkAPIKey = false
    @State private var testingConnection = false
    @State private var connectionTestResult: String?
    @State private var isConnectingGoogleCalendar = false
    @State private var isConnectingGoogleDrive = false
    @State private var instagramSyncResult: InstagramSyncResultBox?
    @State private var notificationsAuthDenied = false
    @State private var message: String?

    @AppStorage(InstagramSyncService.folderDefaultsKey) private var instagramDriveFolder = ""
    @AppStorage("instagramSyncReminderEnabled") private var instagramReminderEnabled = false

    private var googleCalendar: GoogleCalendarService { GoogleCalendarService.shared }
    private var googleDrive: GoogleDriveService { GoogleDriveService.shared }
    private var instagramSync: InstagramSyncService { InstagramSyncService.shared }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        BrandLogoView(size: 48)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Social Climber")
                                .font(.title3.weight(.bold))
                            Text("Private relationship memory, built local-first.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .listRowBackground(
                    RoundedRectangle(cornerRadius: SCTheme.cardRadius, style: .continuous)
                        .fill(.thinMaterial)
                        .padding(.vertical, 3)
                )

                Section("Check-In Cadence Defaults") {
                    Stepper("Top priority: every \(cadenceClose)d", value: $cadenceClose, in: 7...90, step: 7)
                    Stepper("Regular priority: every \(cadenceRegular)d", value: $cadenceRegular, in: 14...180, step: 7)
                    Stepper("Low priority: every \(cadenceDistant)d", value: $cadenceDistant, in: 30...365, step: 15)
                    Text("Based on priority: how actively you want to invest in a relationship. Very close relationships automatically get extra slack on top of this, and people you already talk to often won't be flagged between those natural check-ins. Per-person cadence on a profile always overrides these.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Notifications") {
                    Toggle("Local notifications", isOn: $notificationsEnabled)
                        .tint(.green)
                        .onChange(of: notificationsEnabled) {
                            Task {
                                if notificationsEnabled {
                                    let granted = await NotificationService.shared.requestAuthorization()
                                    await refreshNotificationAuthorization()
                                    if !granted {
                                        notificationsEnabled = false
                                        message = "Notifications are disabled in iOS Settings."
                                    } else {
                                        NotificationService.shared.rescheduleAll(people: people, reminders: reminders, importantDates: importantDates, events: events)
                                    }
                                } else {
                                    NotificationService.shared.cancelAll()
                                }
                            }
                        }
                    if notificationsAuthDenied {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Label("Notifications are off in iOS Settings: tap to open", systemImage: "gear")
                        }
                        .font(.caption)
                    }
                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        Label("Notification Settings", systemImage: "slider.horizontal.3")
                    }
                    Text("Categories, quiet hours, preview privacy, snooze, and reminder frequency. Everything fires locally; nothing is ever sent off this iPhone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Integrations") {
                    Toggle("Location (\"Who's nearby\")", isOn: $locationEnabled)
                        .tint(.green)
                        .onChange(of: locationEnabled) {
                            if locationEnabled {
                                Task {
                                    if await !LocationService.shared.requestAccess() {
                                        locationEnabled = false
                                        message = "Location access was denied."
                                    }
                                }
                            }
                        }
                    Text("Looks up your current city on-device to show people whose saved location matches. Never tracked in the background, never stored, never sent anywhere.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    NavigationLink {
                        LockedInFitSettingsView()
                    } label: {
                        Label("LockedInFit", systemImage: "dumbbell.fill")
                    }
                } footer: {
                    Text("Optional, fail-safe context sharing with the LockedInFit app.")
                }

                Section("Import from Messages") {
                    Label("Uses iOS's Share Sheet, not a screen inside Social Climber", systemImage: "square.and.arrow.up.on.square")
                        .font(.subheadline.weight(.medium))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. In Messages, touch and hold a message, tap \"More…\", then tap each bubble you want to include.")
                        Text("2. Tap the share icon in the bottom-left, then choose Social Climber from the row of apps.")
                        Text("3. Open Social Climber: the conversation is waiting for you to review, attach to a person, and log.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text("Only the messages you select are shared; Social Climber never reads your message history, and nothing leaves your device except when you explicitly analyze a note with an AI provider.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Google Calendar") {
                    LabeledContent("Status", value: googleCalendar.isConnected ? "Connected" : "Not connected")
                    if !googleCalendar.isConnected {
                        TextField("OAuth Client ID (Google Cloud Console)", text: $googleClientID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                        Button {
                            connectGoogleCalendar()
                        } label: {
                            if isConnectingGoogleCalendar {
                                ProgressView()
                            } else {
                                Label("Connect Google Calendar", systemImage: "calendar.badge.plus")
                            }
                        }
                        .disabled(googleClientID.trimmingCharacters(in: .whitespaces).isEmpty || isConnectingGoogleCalendar)
                    } else {
                        Button(role: .destructive) {
                            googleCalendar.disconnect()
                            message = "Disconnected from Google Calendar."
                        } label: {
                            Label("Disconnect Google Calendar", systemImage: "calendar.badge.minus")
                        }
                        .tint(.red)
                    }
                    Text("Read-only. Create a free \"iOS\" OAuth Client ID in Google Cloud Console (enable the Google Calendar API, set the bundle ID to match this app's) and paste it above; no client secret needed. Only a refresh token is stored, in the iOS Keychain; events are fetched on demand and never saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Instagram via Google Drive") {
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(googleDrive.isConnected ? SCTheme.Accents.growth : Color.secondary.opacity(0.4))
                                .frame(width: 8, height: 8)
                            Text(googleDrive.isConnected ? "Connected" : "Not connected")
                        }
                    }
                    if !googleDrive.isConnected {
                        if !googleCalendar.isConnected {
                            TextField("OAuth Client ID (Google Cloud Console)", text: $googleClientID)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.done)
                        }
                        Button {
                            connectGoogleDrive()
                        } label: {
                            if isConnectingGoogleDrive {
                                ProgressView()
                            } else {
                                Label("Connect Google Drive", systemImage: "externaldrive.badge.plus")
                            }
                        }
                        .disabled(googleClientID.trimmingCharacters(in: .whitespaces).isEmpty || isConnectingGoogleDrive)
                    } else {
                        TextField("Drive folder name (optional)", text: $instagramDriveFolder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                        Button {
                            runInstagramSync()
                        } label: {
                            if instagramSync.isSyncing {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text(instagramSync.progressText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                HStack {
                                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                                        .fontWeight(.medium)
                                    Spacer()
                                    if let lastSync = instagramSync.lastSyncAt {
                                        Text(lastSync.relativeLabel)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .disabled(instagramSync.isSyncing)
                        Toggle("Daily sync reminder (10 AM)", isOn: $instagramReminderEnabled)
                            .tint(.green)
                            .onChange(of: instagramReminderEnabled) {
                                if instagramReminderEnabled {
                                    Task {
                                        let granted = await NotificationService.shared.requestAuthorization()
                                        await refreshNotificationAuthorization()
                                        guard granted else {
                                            instagramReminderEnabled = false
                                            message = "Notifications are disabled in iOS Settings."
                                            return
                                        }
                                        // The old UI allowed this reminder toggle to be on
                                        // while the master switch was off, which silently
                                        // prevented any request from being scheduled.
                                        notificationsEnabled = true
                                        NotificationService.shared.scheduleInstagramSyncReminder()
                                    }
                                } else {
                                    NotificationService.shared.cancelInstagramSyncReminder()
                                }
                            }
                        Button(role: .destructive) {
                            googleDrive.disconnect()
                            message = "Disconnected from Google Drive."
                        } label: {
                            Label("Disconnect Google Drive", systemImage: "externaldrive.badge.minus")
                        }
                        .tint(.red)
                    }
                    Text("Pulls Instagram's daily \"Download your information\" export from Drive: new DMs become reviewable interactions, and follower changes are tracked on the Social Health page. Read-only; parsed on-device, raw files deleted immediately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("1. In Meta Accounts Center, choose \"Download your information\", select Instagram, choose JSON format, and choose Google Drive. Pick \"Some of your information\" with messages plus followers and following. Monthly ranges work as dated activity feeds; only an All time range provides a complete list that can reveal who unfollowed you by comparing snapshots.")
                            Text("2. Use the same OAuth Client ID as Google Calendar, with the Google Drive API also enabled on that Cloud project.")
                            Text("3. Enter the Meta export folder name, such as meta-2026-Jul-13-17-11-01. The app supports both expanded folder trees and zip exports. Leave it blank to find the newest matching export automatically.")
                            Text("4. iOS can't run this on a schedule in the background, so turn on the daily reminder and sync when you open the app.")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    } label: {
                        Label("How to set up", systemImage: "questionmark.circle")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Section("AI") {
                    Picker("AI Provider", selection: $aiProvider) {
                        ForEach(AIProvider.allCases) { provider in
                            Text(provider.label).tag(provider.rawValue)
                        }
                    }
                    if aiProvider == AIProvider.bazaarLink.rawValue {
                        Text("OpenRouter API Key (default)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        SecureField(hasOpenRouterAPIKey ? "OpenRouter API key saved" : "OpenRouter API key (sk-or-…)", text: $openRouterAPIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                        Button {
                            saveOpenRouterKey()
                        } label: {
                            Label("Save API Key", systemImage: "key.fill")
                        }
                        .disabled(openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if hasOpenRouterAPIKey {
                            Button(role: .destructive) {
                                clearOpenRouterKey()
                            } label: {
                                Label("Remove Saved API Key", systemImage: "trash")
                            }
                            .tint(.red)
                        }

                        Text("BazaarLink API Key (fallback)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        SecureField(hasBazaarLinkAPIKey ? "BazaarLink API key saved" : "BazaarLink API key (sk-bl-…)", text: $bazaarLinkAPIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                        Button {
                            saveBazaarLinkKey()
                        } label: {
                            Label("Save API Key", systemImage: "key.fill")
                        }
                        .disabled(bazaarLinkAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if hasBazaarLinkAPIKey {
                            Button(role: .destructive) {
                                clearBazaarLinkKey()
                            } label: {
                                Label("Remove Saved API Key", systemImage: "trash")
                            }
                            .tint(.red)
                        }

                        TextField("Model ID override (optional)", text: $bazaarLinkModelID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                        Text("Leave blank to use each gateway's free-routing model automatically. Requests try OpenRouter first, falling back to BazaarLink only if OpenRouter has no key or fails. Keys are stored only in iOS Keychain and never exported or logged. Fit Checker and How to Respond need a vision-capable model to read photos; check your model's capabilities on the provider's site if those come back with an error.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            Task { await testConnection() }
                        } label: {
                            if testingConnection {
                                HStack { ProgressView(); Text("Testing…") }
                            } else {
                                Label("Test Connection", systemImage: "bolt.horizontal")
                            }
                        }
                        .disabled(testingConnection || (!hasOpenRouterAPIKey && !hasBazaarLinkAPIKey))
                        if let connectionTestResult {
                            Text(connectionTestResult)
                                .font(.caption)
                                .foregroundStyle(connectionTestResult.hasPrefix("Connected") ? .green : .secondary)
                        }
                    } else {
                        Text("Mock uses deterministic local heuristics and never sends notes off this iPhone. Fit Checker and How to Respond need real photo analysis, so both require an OpenRouter or BazaarLink key.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Voice notes, typed notes, and photos (outfit or screenshot) stay on this iPhone unless you explicitly analyze them with the selected LLM provider.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        do {
                            exportItem = ShareURL(url: try ExportImportService.writeExportFile(context: context))
                        } catch {
                            message = "Export failed: \(error.localizedDescription)"
                        }
                    } label: {
                        Label("Export JSON…", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import JSON…", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        backUpNow()
                    } label: {
                        Label("Backup Now", systemImage: "externaldrive.badge.checkmark")
                    }
                    Button {
                        showBackupRestore = true
                    } label: {
                        Label("Restore From Backup…", systemImage: "clock.arrow.circlepath")
                    }
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Label("Clear all data…", systemImage: "trash")
                    }
                    .tint(.red)
                    #if DEBUG
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Diagnostics (Debug)", systemImage: "wrench.and.screwdriver")
                    }
                    #endif
                } header: {
                    Text("Data")
                } footer: {
                    Text("Social Climber automatically snapshots your data whenever anything changes, and whenever you leave the app, keeping the latest 5 on this device and mirroring each one to the shared App Group container so a copy survives app updates and reinstalls. \"Backup Now\" takes one on demand; \"Restore From Backup\" merges one back in without ever deleting or replacing what's already here.")
                }

                Section("Privacy") {
                    Label {
                        Text("Social Climber is local-first. Your people, interactions, reminders, gifts, voice notes, contacts, and calendar-derived context live on this iPhone. Contacts import is selected-contact only, calendar access is optional, and LLM calls happen only when you choose a provider and analyze a note.")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(.green)
                    }
                }

                Section {
                    LabeledContent("People", value: "\(people.count)")
                    LabeledContent("Version", value: "1.0")
                }
            }
            .scrollContentBackground(.hidden)
            .background(SCTheme.pageBackground)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Settings")
            .sheet(item: $exportItem) { item in
                ShareSheet(items: [item.url])
            }
            .sheet(isPresented: $showBackupRestore) {
                BackupRestoreView(mode: .voluntary)
            }
            .sheet(item: $instagramSyncResult) { box in
                InstagramSyncReviewView(result: box.result)
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    prepareImport(url)
                case .failure(let error):
                    message = "Import failed: \(error.localizedDescription)"
                }
            }
            .confirmationDialog("Delete all data?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete Everything", role: .destructive) {
                    Haptics.warning()
                    SeedData.clearAll(context: context)
                    message = "All data deleted."
                }
                .tint(.red)
            } message: {
                Text("This permanently removes every person, interaction, reminder, gift, important date, voice note, and AI summary on this iPhone. Export first if you want a backup.")
            }
            .confirmationDialog("Import \(pendingImportName)?", isPresented: $confirmImport, titleVisibility: .visible) {
                Button("Merge Import") {
                    importPendingFile()
                }
                Button("Cancel", role: .cancel) {
                    pendingImportData = nil
                    pendingImportName = ""
                }
            } message: {
                Text("Import merges by person name and skips duplicate interactions. It will not silently replace the whole database.")
            }
            .alert("Social Climber", isPresented: .init(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: {
                Text(message ?? "")
            }
            .onAppear {
                refreshAIKeyStatus()
                Task { await refreshNotificationAuthorization() }
            }
            .onChange(of: scenePhase) {
                if scenePhase == .active {
                    Task { await refreshNotificationAuthorization() }
                }
            }
            .keyboardDoneButton()
        }
    }

    /// Detects a permission revoked in iOS Settings after the user granted
    /// it here, so the toggle never claims notifications are on when the OS
    /// has actually silenced them.
    private func refreshNotificationAuthorization() async {
        let status = await NotificationService.shared.authorizationStatus()
        notificationsAuthDenied = status == .denied
        if status == .denied {
            notificationsEnabled = false
        }
    }

    private func connectGoogleDrive() {
        isConnectingGoogleDrive = true
        Task {
            do {
                try await googleDrive.connect()
                Haptics.success()
                message = "Connected to Google Drive."
            } catch {
                message = error.localizedDescription
            }
            isConnectingGoogleDrive = false
        }
    }

    private func runInstagramSync() {
        Task {
            do {
                let result = try await instagramSync.sync(people: people, context: context)
                Haptics.success()
                instagramSyncResult = InstagramSyncResultBox(result: result)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func connectGoogleCalendar() {
        isConnectingGoogleCalendar = true
        Task {
            do {
                try await googleCalendar.connect()
                Haptics.success()
                message = "Connected to Google Calendar."
            } catch {
                message = error.localizedDescription
            }
            isConnectingGoogleCalendar = false
        }
    }

    private func backUpNow() {
        guard let backup = BackupManager.createBackup(context: context, reason: "manual") else {
            message = "Backup failed."
            return
        }
        Haptics.success()
        message = "Backed up at \(backup.createdAt.formatted(date: .abbreviated, time: .shortened))."
    }

    private func prepareImport(_ url: URL) {
        do {
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            pendingImportData = try Data(contentsOf: url)
            pendingImportName = url.lastPathComponent
            confirmImport = true
        } catch {
            message = "Import failed: \(error.localizedDescription)"
        }
    }

    private func importPendingFile() {
        guard let pendingImportData else { return }
        do {
            let count = try ExportImportService.importData(pendingImportData, context: context)
            Haptics.success()
            DataLossGuard.recordCurrentCount(RecordCounts.total(in: context))
            message = "Import complete. \(count) new people added; existing records were merged by name."
        } catch {
            message = "Import failed: \(error.localizedDescription)"
        }
        self.pendingImportData = nil
        pendingImportName = ""
    }

    private func saveOpenRouterKey() {
        do {
            try KeychainService.saveOpenRouterAPIKey(openRouterAPIKey)
            openRouterAPIKey = ""
            refreshAIKeyStatus()
            message = "OpenRouter API key saved."
            connectionTestResult = nil
        } catch {
            message = "Could not save API key: \(error.localizedDescription)"
        }
    }

    private func clearOpenRouterKey() {
        do {
            try KeychainService.saveOpenRouterAPIKey("")
            refreshAIKeyStatus()
            message = "OpenRouter API key removed."
            connectionTestResult = nil
        } catch {
            message = "Could not remove API key: \(error.localizedDescription)"
        }
    }

    private func saveBazaarLinkKey() {
        do {
            try KeychainService.saveBazaarLinkAPIKey(bazaarLinkAPIKey)
            bazaarLinkAPIKey = ""
            refreshAIKeyStatus()
            message = "BazaarLink API key saved."
            connectionTestResult = nil
        } catch {
            message = "Could not save API key: \(error.localizedDescription)"
        }
    }

    private func testConnection() async {
        testingConnection = true
        defer { testingConnection = false }
        do {
            connectionTestResult = try await BazaarLinkAIService().testConnection()
        } catch {
            connectionTestResult = "Failed: \(error.localizedDescription)"
        }
    }

    private func clearBazaarLinkKey() {
        do {
            try KeychainService.saveBazaarLinkAPIKey("")
            refreshAIKeyStatus()
            message = "BazaarLink API key removed."
            connectionTestResult = nil
        } catch {
            message = "Could not remove API key: \(error.localizedDescription)"
        }
    }

    private func refreshAIKeyStatus() {
        hasOpenRouterAPIKey = KeychainService.hasOpenRouterAPIKey()
        hasBazaarLinkAPIKey = KeychainService.hasBazaarLinkAPIKey()
    }
}

/// Wraps a sync result so it can drive a `.sheet(item:)`.
struct InstagramSyncResultBox: Identifiable {
    let id = UUID()
    let result: InstagramSyncService.SyncResult
}

struct ShareURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    SettingsView()
        .modelContainer(PreviewData.container)
}
