import SwiftUI
import SwiftData

/// Voice note flow: record or type → transcribe → AI extraction → review → apply.
struct VoiceCaptureView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var model = VoiceCaptureViewModel()
    @State private var selectedPeople: [Person] = []
    @State private var showPeoplePicker = false
    @State private var showReview = false

    @Query(sort: \Person.name) private var allPeople: [Person]

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text("Turn a messy memory into useful context.")
                        .font(.headline)
                    Text("Record or type a note, then review what gets added.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)

                recordButton

                if model.isTranscribing {
                    Label("Transcribing…", systemImage: "waveform")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("NOTE")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $model.transcript)
                        .frame(minHeight: 160)
                        .padding(8)
                        .scrollContentBackground(.hidden)
                        .background(SCTheme.cardBackground, in: RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.06))
                        }
                        .overlay(alignment: .topLeading) {
                            if model.transcript.isEmpty {
                                Text("Record, or type what happened — who you saw, what you talked about, anything worth remembering.")
                                    .font(.subheadline)
                                    .foregroundStyle(.tertiary)
                                    .padding(16)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                peopleSection

                if let error = model.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Spacer()

                Button {
                    Task {
                        await model.analyze(knownPeople: allPeople.map(\.name))
                        autoSelectMentionedPeople()
                        if model.extraction != nil { showReview = true }
                    }
                } label: {
                    if model.isAnalyzing {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Analyze & Review", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isAnalyzing || model.isRecording)
            }
            .padding()
            .background(SCTheme.pageBackground)
            .navigationTitle("Voice Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.discardRecording()
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showPeoplePicker) {
                NavigationStack {
                    PersonMultiPicker(selected: $selectedPeople)
                        .navigationTitle("Who is this about?")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showPeoplePicker = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showReview) {
                if let extraction = model.extraction {
                    ExtractionReviewView(
                        extraction: extraction,
                        people: selectedPeople,
                        transcript: model.transcript,
                        audioFileName: model.audioFileName
                    ) {
                        dismiss()
                    }
                }
            }
        }
    }

    private var recordButton: some View {
        VStack(spacing: 10) {
            Button {
                model.toggleRecording()
            } label: {
                ZStack {
                    Circle()
                        .fill(model.isRecording ? Color.red : Color.accentColor)
                        .frame(width: 88, height: 88)
                        .shadow(color: (model.isRecording ? Color.red : Color.accentColor).opacity(0.35), radius: 12, y: 4)
                    Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            Text(model.isRecording ? "Recording… tap to stop" : "Tap to record")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ABOUT")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Button {
                showPeoplePicker = true
            } label: {
                HStack {
                    if selectedPeople.isEmpty {
                        Text("Choose people (or let AI detect them)")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(selectedPeople.prefix(5)) { person in
                            PersonAvatarView(person: person, size: 30)
                        }
                        Text(selectedPeople.map(\.firstName).joined(separator: ", "))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(SCTheme.cardBackground, in: RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06))
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func autoSelectMentionedPeople() {
        guard let extraction = model.extraction else { return }
        for name in extraction.peopleMentioned {
            if let person = allPeople.first(where: { $0.name == name }),
               !selectedPeople.contains(where: { $0 === person }) {
                selectedPeople.append(person)
            }
        }
    }
}

// MARK: - Review & apply

struct ExtractionReviewView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let extraction: AIExtraction
    let people: [Person]
    let transcript: String
    let audioFileName: String?
    let onApplied: () -> Void

    @State private var options = ExtractionApplier.Options()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(extraction.summary.isEmpty ? "No summary" : extraction.summary)
                        .font(.subheadline)
                    HStack {
                        if !extraction.topics.isEmpty {
                            Text(extraction.topics.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("Confidence \(Int(extraction.confidence * 100))%")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } header: {
                    Text("Summary")
                }

                if people.isEmpty {
                    Section {
                        Label("No people selected — this will only be saved as a note.", systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }

                if !extraction.interests.isEmpty {
                    toggleSection("Interests", items: extraction.interests, isOn: $options.addInterests)
                }
                if !extraction.giftIdeas.isEmpty {
                    toggleSection("Gift Ideas", items: extraction.giftIdeas, isOn: $options.addGiftIdeas)
                }
                if !extraction.reminders.isEmpty {
                    toggleSection("Reminders", items: extraction.reminders.map(\.title), isOn: $options.addReminders)
                }
                if !extraction.importantDates.isEmpty {
                    toggleSection("Important Dates", items: extraction.importantDates.map(\.display), isOn: $options.addImportantDates)
                }
                if !extraction.personalityNotes.isEmpty {
                    toggleSection("Personality Notes", items: extraction.personalityNotes, isOn: $options.addPersonalityNotes)
                }
                if !extraction.followUpQuestions.isEmpty {
                    Section("Ask Next Time") {
                        ForEach(extraction.followUpQuestions, id: \.self) { question in
                            Text(question).font(.subheadline)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(SCTheme.pageBackground)
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func toggleSection(_ title: String, items: [String], isOn: Binding<Bool>) -> some View {
        Section {
            Toggle("Add to profile", isOn: isOn)
            ForEach(items, id: \.self) { item in
                Text("• \(item)")
                    .font(.subheadline)
                    .foregroundStyle(isOn.wrappedValue ? .primary : .tertiary)
            }
        } header: {
            Text(title)
        }
    }

    private func apply() {
        let voiceNote = VoiceNote(audioFileName: audioFileName, transcript: transcript)
        voiceNote.people = people
        context.insert(voiceNote)

        ExtractionApplier.apply(
            extraction,
            to: people,
            sourceText: transcript,
            interactionType: .voiceNote,
            voiceNote: voiceNote,
            options: options,
            context: context
        )
        dismiss()
        onApplied()
    }
}

#Preview {
    VoiceCaptureView()
        .modelContainer(PreviewData.container)
}
