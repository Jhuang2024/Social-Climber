import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// Import a social-media interaction — either by pasting copied chat text or by
/// scanning a screenshot with on-device OCR. Fully local: nothing is ever sent
/// off the device.
struct ImportMessageView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var preselected: [Person] = []

    enum Mode: String, CaseIterable, Identifiable {
        case paste = "Paste Text"
        case screenshot = "Screenshot"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .paste
    @State private var rawText = ""
    @State private var parsed: ParsedMessage?

    @State private var platform: MessagePlatform = .instagram
    @State private var selectedPeople: [Person] = []
    @State private var summary = ""
    @State private var notes = ""
    @State private var sentiment: Sentiment = .neutral
    @State private var followUpNeeded = false
    @State private var followUpDate = Calendar.current.date(byAdding: .day, value: 3, to: .now) ?? .now
    @State private var nextMove = ""
    @State private var messageDate = Date.now
    @State private var useDetectedDate = false

    @State private var photoItem: PhotosPickerItem?
    @State private var isScanning = false
    @State private var errorMessage: String?

    @State private var newContactName = ""
    @State private var showPeoplePicker = false

    @Query(sort: \Person.name) private var allPeople: [Person]

    private var canSave: Bool {
        !selectedPeople.isEmpty && !(summary.isEmpty && rawText.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                sourceSection
                if !rawText.isEmpty { detailsSection }
            }
            .scrollContentBackground(.hidden)
            .background(SCTheme.pageBackground)
            .navigationTitle("Import Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
            .sheet(isPresented: $showPeoplePicker) {
                NavigationStack {
                    PersonMultiPicker(selected: $selectedPeople)
                        .navigationTitle("Who is this with?")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showPeoplePicker = false }
                            }
                        }
                }
            }
            .alert("Import", isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear { if selectedPeople.isEmpty { selectedPeople = preselected } }
            .onChange(of: photoItem) { _, item in
                if let item { Task { await scan(item) } }
            }
            .keyboardDoneButton()
        }
    }

    // MARK: Source

    @ViewBuilder
    private var sourceSection: some View {
        Section {
            Picker("Source", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch mode {
            case .paste:
                TextField("Paste the copied chat or message here…", text: $rawText, axis: .vertical)
                    .lineLimit(5...14)
                Button {
                    parse()
                } label: {
                    Label("Detect summary", systemImage: "wand.and.stars")
                }
                .disabled(rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            case .screenshot:
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label(rawText.isEmpty ? "Choose a screenshot" : "Choose a different screenshot",
                          systemImage: "photo.on.rectangle.angled")
                }
                if isScanning {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Scanning on-device…").foregroundStyle(.secondary)
                    }
                }
                if !rawText.isEmpty {
                    Text("Extracted text (edit if needed):")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Extracted text", text: $rawText, axis: .vertical)
                        .lineLimit(4...14)
                }
            }
        } header: {
            Text("Source")
        } footer: {
            Text("Everything stays on your device. Screenshots are read with Apple's on-device text recognition and never uploaded.")
        }
    }

    // MARK: Details

    @ViewBuilder
    private var detailsSection: some View {
        Section("Platform") {
            Picker("Platform", selection: $platform) {
                ForEach(MessagePlatform.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
            }
        }

        Section("Contact") {
            if selectedPeople.isEmpty {
                Button { showPeoplePicker = true } label: {
                    Label("Choose contact", systemImage: "person.crop.circle.badge.plus")
                }
            } else {
                ForEach(selectedPeople) { person in
                    HStack {
                        PersonAvatarView(person: person, size: 30)
                        Text(person.displayName)
                        Spacer()
                    }
                }
                .onDelete { selectedPeople.remove(atOffsets: $0) }
                Button { showPeoplePicker = true } label: {
                    Label("Change contact", systemImage: "person.2.badge.plus")
                }
            }
            HStack {
                TextField(newContactPrompt, text: $newContactName)
                Button("Create") { createContact() }
                    .disabled(newContactName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }

        Section("Summary") {
            TextField("Editable summary", text: $summary, axis: .vertical)
                .lineLimit(2...6)
            if let speakers = parsed?.speakers, !speakers.isEmpty {
                Text("Detected: \(speakers.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        Section("Details") {
            SentimentPicker(sentiment: $sentiment)
            if parsed?.detectedDate != nil {
                Toggle("Use detected message date", isOn: $useDetectedDate.animation(.snappy))
            }
            if useDetectedDate, parsed?.detectedDate != nil {
                DatePicker("Message date", selection: $messageDate, displayedComponents: [.date, .hourAndMinute])
            }
            TextField("Notes (optional)", text: $notes, axis: .vertical)
                .lineLimit(1...4)
        }

        Section("Follow-up") {
            Toggle("Needs follow-up", isOn: $followUpNeeded.animation(.snappy))
            if followUpNeeded {
                DatePicker("Follow up by", selection: $followUpDate, displayedComponents: .date)
                TextField("Next move", text: $nextMove, axis: .vertical)
                    .lineLimit(1...3)
            }
        }

        Section("Raw text (preserved)") {
            Text(rawText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var newContactPrompt: String {
        if let name = parsed?.speakers.first, !name.isEmpty {
            return "New contact (e.g. \(name))"
        }
        return "Create a new contact"
    }

    // MARK: Actions

    private func parse() {
        let result = MessageImportParser.parse(rawText)
        parsed = result
        if summary.isEmpty { summary = result.summary }
        if let date = result.detectedDate {
            messageDate = date
            useDetectedDate = true
        }
        // Offer the first detected speaker as a suggested new-contact name.
        if newContactName.isEmpty, let speaker = result.speakers.first,
           !allPeople.contains(where: { $0.name.localizedCaseInsensitiveContains(speaker) }) {
            newContactName = speaker
        }
        Haptics.success()
    }

    private func scan(_ item: PhotosPickerItem) async {
        isScanning = true
        errorMessage = nil
        defer { isScanning = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                errorMessage = OCRError.noImage.errorDescription
                return
            }
            let text = try await OCRService.recognizeText(in: image)
            rawText = text
            parse()
        } catch let error as OCRError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createContact() {
        let name = newContactName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let person = Person(name: name, category: .acquaintance, closeness: 2, priority: 2)
        context.insert(person)
        selectedPeople.append(person)
        newContactName = ""
        Haptics.success()
    }

    private func save() {
        if parsed == nil { parse() }
        let finalSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = useDetectedDate ? messageDate : .now

        let interaction = Interaction(
            type: .socialMedia,
            date: date,
            note: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            quality: sentiment.quality,
            followUpNeeded: followUpNeeded,
            followUpDate: followUpNeeded ? followUpDate : nil,
            nextMove: nextMove.trimmingCharacters(in: .whitespacesAndNewlines),
            messageSummary: finalSummary.isEmpty ? (parsed?.summary ?? "") : finalSummary
        )
        interaction.isImported = true
        interaction.platform = platform
        interaction.rawImportText = rawText

        InteractionSaver.finalize(interaction, people: selectedPeople, context: context)
        Haptics.success()
        dismiss()
    }
}

#Preview {
    ImportMessageView()
        .modelContainer(PreviewData.container)
}
