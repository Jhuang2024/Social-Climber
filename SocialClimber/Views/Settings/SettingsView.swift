import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var people: [Person]
    @Query private var reminders: [Reminder]

    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @AppStorage("calendarEnabled") private var calendarEnabled = false
    @AppStorage("aiProvider") private var aiProvider = AIProvider.mock.rawValue
    @AppStorage("defaultCadenceClose") private var cadenceClose = 7
    @AppStorage("defaultCadenceRegular") private var cadenceRegular = 30
    @AppStorage("defaultCadenceDistant") private var cadenceDistant = 90

    @State private var exportURL: URL?
    @State private var showImporter = false
    @State private var showContactPicker = false
    @State private var confirmClear = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
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
                    Toggle("Calendar (read-only)", isOn: $calendarEnabled)
                        .onChange(of: calendarEnabled) {
                            if calendarEnabled {
                                Task {
                                    if await !CalendarService.shared.requestAccess() {
                                        calendarEnabled = false
                                        message = "Calendar access was denied."
                                    }
                                }
                            }
                        }
                    Button {
                        showContactPicker = true
                    } label: {
                        Label("Import a contact…", systemImage: "person.crop.circle.badge.plus")
                    }
                    Text("Contacts are imported one at a time, only when you pick them. No mass import, ever.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("AI") {
                    Picker("Provider", selection: $aiProvider) {
                        ForEach(AIProvider.allCases) { provider in
                            Text(provider.label).tag(provider.rawValue)
                        }
                    }
                    Text("The mock analyzer runs entirely on-device. A real LLM provider can be plugged in later via AIService.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Data") {
                    Button {
                        do {
                            exportURL = try ExportImportService.writeExportFile(context: context)
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
                }

                Section("Privacy") {
                    Label {
                        Text("Everything lives on this iPhone. No account, no cloud, no analytics, no network calls. Deleting the app deletes the data — export a JSON backup first if you want one.")
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
            .navigationTitle("Settings")
            .sheet(item: $exportURL) { url in
                ShareSheet(items: [url])
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
                    importFile(url)
                case .failure(let error):
                    message = "Import failed: \(error.localizedDescription)"
                }
            }
            .confirmationDialog("Delete all people, interactions, reminders, and gifts? This cannot be undone.", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete Everything", role: .destructive) {
                    SeedData.clearAll(context: context)
                    UserDefaults.standard.set(true, forKey: "didSeed")
                    message = "All data deleted."
                }
            }
            .alert("Social Climber", isPresented: .init(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }

    private func importFile(_ url: URL) {
        do {
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let count = try ExportImportService.importData(data, context: context)
            message = "Import complete. \(count) new people added."
        } catch {
            message = "Import failed: \(error.localizedDescription)"
        }
    }
}

extension URL: Identifiable {
    public var id: String { absoluteString }
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
