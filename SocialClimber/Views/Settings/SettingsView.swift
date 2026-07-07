import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var people: [Person]
    @Query private var reminders: [Reminder]

    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @AppStorage("locationEnabled") private var locationEnabled = false
    @AppStorage("googleClientID") private var googleClientID = "201027748898-lerfifmsfgdu2uubgph606p2rsa6ic7j.apps.googleusercontent.com"
    @AppStorage("aiProvider") private var aiProvider = AIProvider.mock.rawValue
    @AppStorage("openRouterModelID") private var openRouterModelID = OpenRouterDefaults.modelID
    @AppStorage("defaultCadenceClose") private var cadenceClose = 7
    @AppStorage("defaultCadenceRegular") private var cadenceRegular = 30
    @AppStorage("defaultCadenceDistant") private var cadenceDistant = 90

    @State private var exportItem: ShareURL?
    @State private var showImporter = false
    @State private var showContactPicker = false
    @State private var confirmClear = false
    @State private var confirmImport = false
    @State private var pendingImportData: Data?
    @State private var pendingImportName = ""
    @State private var openRouterAPIKey = ""
    @State private var hasOpenRouterAPIKey = false
    @State private var isConnectingGoogleCalendar = false
    @State private var message: String?

    private var googleCalendar: GoogleCalendarService { GoogleCalendarService.shared }

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
                    Stepper("Close (5●): every \(cadenceClose)d", value: $cadenceClose, in: 1...60)
                    Stepper("Regular (3●): every \(cadenceRegular)d", value: $cadenceRegular, in: 7...120)
                    Stepper("Distant (1●): every \(cadenceDistant)d", value: $cadenceDistant, in: 14...365)
                    Text("Per-person cadence can be set on each profile and overrides these.")
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
                                    if !granted {
                                        notificationsEnabled = false
                                        message = "Notifications are disabled in iOS Settings."
                                    } else {
                                        NotificationService.shared.rescheduleAll(people: people, reminders: reminders)
                                    }
                                } else {
                                    NotificationService.shared.cancelAll()
                                }
                            }
                        }
                    Text("Birthdays at 9 AM, reminders on their due date. Everything fires locally.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Integrations") {
                    Button {
                        showContactPicker = true
                    } label: {
                        Label("Import a contact…", systemImage: "person.crop.circle.badge.plus")
                    }
                    Text("Contacts are imported one at a time, only when you pick them. No mass import, ever.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

                Section("Import from Messages") {
                    Label("Uses iOS's Share Sheet, not a screen inside Social Climber", systemImage: "square.and.arrow.up.on.square")
                        .font(.subheadline.weight(.medium))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. In Messages, touch and hold a message, tap \"More…\", then tap each bubble you want to include.")
                        Text("2. Tap the share icon in the bottom-left, then choose Social Climber from the row of apps.")
                        Text("3. Open Social Climber — the conversation is waiting for you to review, attach to a person, and log.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text("Only the messages you select are shared — Social Climber never reads your message history, and nothing leaves your device except when you explicitly analyze a note with an AI provider.")
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
                    Text("Read-only. Create a free \"iOS\" OAuth Client ID in Google Cloud Console (enable the Google Calendar API, set the bundle ID to match this app's) and paste it above — no client secret needed. Only a refresh token is stored, in the iOS Keychain; events are fetched on demand and never saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("AI") {
                    Picker("AI Provider", selection: $aiProvider) {
                        ForEach(AIProvider.allCases) { provider in
                            Text(provider.label).tag(provider.rawValue)
                        }
                    }
                    if aiProvider == AIProvider.openRouter.rawValue {
                        SecureField(hasOpenRouterAPIKey ? "OpenRouter API key saved" : "OpenRouter API key", text: $openRouterAPIKey)
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
                        TextField("Model ID", text: $openRouterModelID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                        Text("Default: \(OpenRouterDefaults.modelID). The API key is stored only in iOS Keychain and is never exported or logged.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Mock uses deterministic local heuristics and never sends notes off this iPhone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Voice notes and typed notes stay local unless you explicitly analyze them with the selected LLM provider.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Data") {
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
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Label("Clear all data…", systemImage: "trash")
                    }
                    .tint(.red)
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
            .sheet(isPresented: $showContactPicker) {
                ContactPickerView { contact in
                    let person = ContactsImporter.person(from: contact)
                    context.insert(person)
                    message = "Imported \(person.displayName). Open their profile to fill in the rest."
                }
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
                refreshOpenRouterKeyStatus()
            }
            .keyboardDoneButton()
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
            refreshOpenRouterKeyStatus()
            message = "OpenRouter API key saved."
        } catch {
            message = "Could not save API key: \(error.localizedDescription)"
        }
    }

    private func clearOpenRouterKey() {
        do {
            try KeychainService.saveOpenRouterAPIKey("")
            refreshOpenRouterKeyStatus()
            message = "OpenRouter API key removed."
        } catch {
            message = "Could not remove API key: \(error.localizedDescription)"
        }
    }

    private func refreshOpenRouterKeyStatus() {
        hasOpenRouterAPIKey = KeychainService.hasOpenRouterAPIKey()
    }
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
