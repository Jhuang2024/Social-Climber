import SwiftUI
import SwiftData

/// Voice note flow: record a live conversation or type → transcribe → AI extraction → review → apply.
struct VoiceCaptureView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var model = VoiceCaptureViewModel()
    @State private var selectedPeople: [Person] = []
    @State private var showPeoplePicker = false
    @State private var showReview = false

    @Query(sort: \Person.name) private var allPeople: [Person]

    private var isAnalyzeDisabled: Bool {
        selectedPeople.isEmpty
            || model.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model.isAnalyzing || model.isRecording
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text("Capture the conversation as it happens.")
                        .font(.headline)
                    Text("Choose who you were talking to, then record or type notes.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)

                peopleSection

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
                                Text("Record the conversation as you're having it, or type what's being said — who you're with, what you're talking about.")
                                    .font(.subheadline)
                                    .foregroundStyle(.tertiary)
                                    .padding(16)
                                    .allowsHitTesting(false)
                            }
                        }
                }

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
                        if model.extraction != nil { showReview = true }
                    }
                } label: {
                    Group {
                        if model.isAnalyzing {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Label("Analyze & Review", systemImage: "sparkles")
                                .foregroundStyle(.white)
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        SCTheme.accent.opacity(isAnalyzeDisabled ? 0.4 : 1),
                        in: RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous)
                    )
                }
                .buttonStyle(.pressable)
                .disabled(isAnalyzeDisabled)
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
            .keyboardDoneToolbar()
            .sheet(isPresented: $showPeoplePicker) {
                NavigationStack {
                    PersonMultiPicker(selected: $selectedPeople)
                        .navigationTitle("Who were you talking to?")
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
                        .stroke(Color.red.opacity(model.isRecording ? 0.35 : 0), lineWidth: 3)
                        .frame(width: 88, height: 88)
                        .scaleEffect(model.isRecording ? 1.35 : 1)
                        .opacity(model.isRecording ? 0 : 1)
                        .animation(model.isRecording ? .easeOut(duration: 1.1).repeatForever(autoreverses: false) : .default, value: model.isRecording)
                    Circle()
                        .fill(model.isRecording ? Color.red : SCTheme.accent)
                        .frame(width: 88, height: 88)
                        .shadow(color: (model.isRecording ? Color.red : SCTheme.accent).opacity(0.35), radius: 12, y: 4)
                    Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.pressable)
            .sensoryFeedback(.start, trigger: model.isRecording) { _, isRecording in isRecording }
            .sensoryFeedback(.stop, trigger: model.isRecording) { _, isRecording in !isRecording }
            Text(model.isRecording ? "Recording live… tap to stop" : "Tap to record the conversation live")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(.snappy, value: model.isRecording)
        }
        .padding(.top, 4)
    }

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("WHO WERE YOU TALKING TO?")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Required")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.14), in: Capsule())
            }
            Button {
                showPeoplePicker = true
            } label: {
                HStack {
                    if selectedPeople.isEmpty {
                        Text("Choose the person or people you're talking to")
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
                        .strokeBorder(selectedPeople.isEmpty ? Color.orange.opacity(0.35) : Color.primary.opacity(0.06))
                }
            }
            .buttonStyle(.pressable)
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
