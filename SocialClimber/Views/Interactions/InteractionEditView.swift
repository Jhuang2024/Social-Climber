import SwiftUI
import SwiftData

/// Edits an existing interaction's details. Quality changes are routed
/// through `InteractionSaver.updateQuality`, which reverses the interaction's
/// prior closeness impact and re-applies the new one — so closeness never
/// drifts or double-counts across edits.
struct InteractionEditView: View {
    @Bindable var interaction: Interaction
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var type: InteractionType
    @State private var date: Date
    @State private var location: String
    @State private var note: String
    @State private var messageSummary: String
    @State private var topics: [String]
    @State private var sentiment: Sentiment
    @State private var followUpNeeded: Bool
    @State private var followUpDate: Date
    @State private var nextMove: String

    init(interaction: Interaction) {
        self.interaction = interaction
        _type = State(initialValue: interaction.type)
        _date = State(initialValue: interaction.date)
        _location = State(initialValue: interaction.location)
        _note = State(initialValue: interaction.note)
        _messageSummary = State(initialValue: interaction.messageSummary)
        _topics = State(initialValue: interaction.topics)
        _sentiment = State(initialValue: interaction.sentiment)
        _followUpNeeded = State(initialValue: interaction.followUpNeeded)
        _followUpDate = State(initialValue: interaction.followUpDate ?? Calendar.current.date(byAdding: .day, value: 3, to: .now) ?? .now)
        _nextMove = State(initialValue: interaction.nextMove)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !interaction.people.isEmpty {
                    Section("Who") {
                        Text(interaction.peopleNames)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("What") {
                    // All cases, not just `.loggable` — an interaction
                    // originally logged as a voice note still needs its
                    // current type represented when editing.
                    Picker("Type", selection: $type) {
                        ForEach(InteractionType.allCases) { t in
                            Label(t.label, systemImage: t.icon).tag(t)
                        }
                    }
                    DatePicker("When", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    TextField("Location", text: $location)
                        .submitLabel(.done)
                }

                Section("Notes") {
                    TextField("What happened?", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                    TextField("Summary (optional)", text: $messageSummary, axis: .vertical)
                        .lineLimit(1...4)
                    TagListEditor(label: "topic", items: $topics)
                }

                Section {
                    SentimentPicker(sentiment: $sentiment)
                } footer: {
                    Text("Changing how this went adjusts \(interaction.peopleNames.isEmpty ? "their" : interaction.peopleNames + "'s") closeness — poor interactions cost points, great ones earn more.")
                }

                Section("Follow-up") {
                    Toggle("Needs follow-up", isOn: $followUpNeeded.animation(.snappy))
                    if followUpNeeded {
                        DatePicker("Follow up by", selection: $followUpDate, displayedComponents: .date)
                        TextField("Next move", text: $nextMove, axis: .vertical)
                            .lineLimit(1...3)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(SCTheme.pageBackground)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Edit Interaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .keyboardDoneButton()
        }
    }

    private func save() {
        let wasFollowUpNeeded = interaction.followUpNeeded

        interaction.type = type
        interaction.date = date
        interaction.location = location
        interaction.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        interaction.messageSummary = messageSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        interaction.topics = topics
        interaction.followUpNeeded = followUpNeeded
        interaction.followUpDate = followUpNeeded ? followUpDate : nil
        interaction.nextMove = nextMove.trimmingCharacters(in: .whitespacesAndNewlines)

        // Only schedule a new reminder when follow-up is newly turned on —
        // this interaction has no back-reference to a reminder it may have
        // already created, so re-scheduling on every edit would duplicate it.
        if followUpNeeded, !wasFollowUpNeeded {
            InteractionSaver.scheduleFollowUpIfNeeded(for: interaction, people: interaction.people, context: context)
        }

        // Compare by Sentiment, not raw quality — `quality` values outside
        // the four canonical ones (e.g. legacy/imported data) collapse onto
        // a Sentiment, so comparing ints here could see a "change" (and
        // silently rewrite + re-nudge closeness) on a save where the user
        // never touched the picker.
        if sentiment != interaction.sentiment {
            InteractionSaver.updateQuality(of: interaction, to: sentiment.quality)
        }

        Haptics.success()
        dismiss()
    }
}

#Preview {
    InteractionEditView(interaction: {
        let i = Interaction(type: .inPerson, note: "Preview interaction", topics: ["Food"])
        return i
    }())
    .modelContainer(PreviewData.container)
}
