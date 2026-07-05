import SwiftUI
import SwiftData

struct AddInteractionView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var preselected: [Person] = []

    @State private var selectedPeople: [Person] = []
    @State private var type: InteractionType = .inPerson
    @State private var date = Date.now
    @State private var location = ""
    @State private var note = ""
    @State private var topics: [String] = []
    @State private var quality = 3
    @State private var followUpNeeded = false
    @State private var analyzeWithAI = true
    @State private var isSaving = false
    @State private var showPeoplePicker = false
    @State private var message: String?

    @Query(sort: \Person.name) private var allPeople: [Person]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Capture the useful bits while they are fresh.", systemImage: "bubble.left.and.bubble.right.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(
                    RoundedRectangle(cornerRadius: SCTheme.cardRadius, style: .continuous)
                        .fill(.thinMaterial)
                        .padding(.vertical, 3)
                )

                Section("Who") {
                    if selectedPeople.isEmpty {
                        Button { showPeoplePicker = true } label: {
                            Label("Choose people", systemImage: "person.2.badge.plus")
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
                            Label("Add / remove people", systemImage: "person.2.badge.plus")
                        }
                    }
                }

                Section("What") {
                    Picker("Type", selection: $type) {
                        ForEach(InteractionType.allCases.filter { $0 != .voiceNote }) { t in
                            Label(t.label, systemImage: t.icon).tag(t)
                        }
                    }
                    DatePicker("When", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    TextField("Location", text: $location)
                }

                Section("Notes") {
                    TextField("What happened? What did you talk about?", text: $note, axis: .vertical)
                        .lineLimit(4...10)
                    TagListEditor(label: "topic", items: $topics)
                }

                Section {
                    DotRatingPicker(label: "Quality", value: $quality, color: .yellow)
                    Toggle("Needs follow-up", isOn: $followUpNeeded)
                    Toggle(isOn: $analyzeWithAI) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Analyze note")
                            Text("Extract interests, gifts, dates & follow-ups")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(SCTheme.pageBackground)
            .navigationTitle("Log Interaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .disabled(selectedPeople.isEmpty)
                    }
                }
            }
            .sheet(isPresented: $showPeoplePicker) {
                NavigationStack {
                    PersonMultiPicker(selected: $selectedPeople)
                        .navigationTitle("Who was there?")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showPeoplePicker = false }
                            }
                        }
                }
            }
            .alert("Social Climber", isPresented: .init(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: {
                Text(message ?? "")
            }
            .onAppear {
                if selectedPeople.isEmpty { selectedPeople = preselected }
            }
            .keyboardDoneButton()
        }
    }

    private func save() async {
        isSaving = true
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)

        if analyzeWithAI, !trimmedNote.isEmpty {
            do {
                let extraction = try await AIProvider.current.extract(
                    from: trimmedNote,
                    knownPeople: allPeople.map(\.name)
                )

                let interaction = ExtractionApplier.apply(
                    extraction,
                    to: selectedPeople,
                    sourceText: trimmedNote,
                    interactionType: type,
                    date: date,
                    context: context
                )
                interaction?.location = location
                interaction?.quality = quality
                if followUpNeeded { interaction?.followUpNeeded = true }
                var mergedTopics = interaction?.topics ?? []
                for topic in topics where !mergedTopics.contains(topic) { mergedTopics.append(topic) }
                interaction?.topics = mergedTopics
            } catch {
                savePlainInteraction(note: trimmedNote)
                saveFollowUpReminderIfNeeded()
                message = error.localizedDescription
                isSaving = false
                return
            }
        } else {
            savePlainInteraction(note: trimmedNote)
        }

        saveFollowUpReminderIfNeeded()

        isSaving = false
        dismiss()
    }

    private func savePlainInteraction(note: String) {
        let interaction = Interaction(type: type, date: date, location: location, note: note, topics: topics, quality: quality, followUpNeeded: followUpNeeded)
        interaction.people = selectedPeople
        context.insert(interaction)
        for person in selectedPeople {
            person.markContacted(type: type, date: date)
        }
    }

    private func saveFollowUpReminderIfNeeded() {
        guard followUpNeeded, let first = selectedPeople.first else { return }
            let reminder = Reminder(
                title: "Follow up with \(selectedPeople.map(\.firstName).joined(separator: " & "))",
                dueDate: Calendar.current.date(byAdding: .day, value: 3, to: .now) ?? .now,
                type: .followUp,
                person: first
            )
            context.insert(reminder)
            NotificationService.shared.schedule(reminder: reminder)
    }
}

#Preview {
    AddInteractionView()
        .modelContainer(PreviewData.container)
}
