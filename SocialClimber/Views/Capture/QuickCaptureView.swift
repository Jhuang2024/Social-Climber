import SwiftUI
import SwiftData
import PhotosUI
import AVFoundation
import Speech
import UIKit

/// The default way anything gets into Social Climber: one natural-language
/// sentence (typed, spoken, pasted, or a screenshot), one "Remember" button,
/// zero required structured fields. The capture is persisted locally the
/// instant it's submitted, the sheet dismisses immediately, and
/// `CaptureProcessor` organizes it in the background — no review screen,
/// no loading state to stare at. Feels like sending yourself a message,
/// not filling in a CRM form.
struct QuickCaptureView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let request: QuickCaptureRequest

    @State private var text = ""
    /// The portion of `text` that came from on-device transcription, kept
    /// separately so the capture can preserve the transcript as such.
    @State private var transcribedText = ""
    @State private var recorder = QuickCaptureRecorder()
    @State private var selectedChipIDs: Set<UUID> = []
    @State private var selectedChipNames: [UUID: String] = [:]
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var cameraImages: [UIImage] = []
    @State private var showCamera = false
    @State private var isSubmitting = false
    /// Set only when persisting the capture itself failed. The sheet stays
    /// open, no haptic/toast/enqueue happens, and the same "Remember" tap
    /// retries — see `CaptureProcessor.persistNewCapture`.
    @State private var saveErrorMessage: String?
    @FocusState private var isTextFocused: Bool

    @Query(sort: [SortDescriptor(\Person.lastContactedAt, order: .reverse)]) private var peopleByRecency: [Person]

    private var hasTrustedContext: Bool {
        !request.trustedPersonIDs.isEmpty || !request.trustedPersonNames.isEmpty || request.eventContext != nil
    }

    private var recentPeople: [Person] {
        peopleByRecency.filter { !$0.isArchived && $0.lastContactedAt != nil }.prefix(6).map { $0 }
    }

    private var photoCount: Int { photoItems.count + cameraImages.count }

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || photoCount > 0
    }

    private var cameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    var body: some View {
        VStack(spacing: 14) {
            grabber

            if hasTrustedContext { contextHeader }

            textArea

            if recorder.isRecording || recorder.isTranscribing {
                recordingStatus
            }

            if let error = recorder.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            if let saveErrorMessage {
                Text(saveErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            if !hasTrustedContext && !recentPeople.isEmpty {
                personChips
            }

            bottomBar
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(SCTheme.pageBackground)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .onAppear {
            text = request.prefilledText
            if request.startRecording {
                recorder.start()
            } else {
                isTextFocused = true
            }
            recorder.onTranscript = { transcript in
                appendTranscript(transcript)
            }
        }
        .onDisappear {
            recorder.discard()
        }
        .sheet(isPresented: $showCamera) {
            CameraCaptureView { captured in
                if let captured { cameraImages.append(captured) }
            }
            .ignoresSafeArea()
        }
        .interactiveDismissDisabled(isSubmitting)
    }

    // MARK: Pieces

    private var grabber: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.35))
            .frame(width: 36, height: 5)
            .padding(.top, 2)
    }

    private var contextHeader: some View {
        HStack(spacing: 8) {
            if let event = request.eventContext {
                Label(event.name.isEmpty ? "Event" : event.name, systemImage: "party.popper")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(SCTheme.accent.opacity(0.12), in: Capsule())
                    .foregroundStyle(SCTheme.accent)
            }
            ForEach(request.trustedPersonNames, id: \.self) { name in
                Label(name.components(separatedBy: " ").first ?? name, systemImage: "person.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(SCTheme.accent.opacity(0.12), in: Capsule())
                    .foregroundStyle(SCTheme.accent)
            }
            Spacer()
        }
    }

    private var textArea: some View {
        TextField(
            "",
            text: $text,
            prompt: Text("What do you want to remember?")
                .foregroundStyle(.tertiary),
            axis: .vertical
        )
        .font(.body)
        .lineLimit(4...10)
        .focused($isTextFocused)
        .padding(14)
        .background(SCTheme.cardBackground, in: RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        }
    }

    private var recordingStatus: some View {
        HStack(spacing: 8) {
            if recorder.isRecording {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Listening… tap the mic to stop")
            } else {
                ProgressView().controlSize(.small)
                Text("Transcribing on-device…")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var personChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(recentPeople) { person in
                    let selected = selectedChipIDs.contains(person.uuid)
                    Button {
                        if selected {
                            selectedChipIDs.remove(person.uuid)
                            selectedChipNames.removeValue(forKey: person.uuid)
                        } else {
                            selectedChipIDs.insert(person.uuid)
                            selectedChipNames[person.uuid] = person.name
                        }
                    } label: {
                        HStack(spacing: 6) {
                            PersonAvatarView(person: person, size: 22)
                            Text(person.firstName)
                                .font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            selected ? SCTheme.accent.opacity(0.18) : SCTheme.cardBackground,
                            in: Capsule()
                        )
                        .overlay {
                            Capsule().strokeBorder(selected ? SCTheme.accent.opacity(0.6) : Color.primary.opacity(0.08))
                        }
                        .foregroundStyle(selected ? SCTheme.accent : .primary)
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selectedChipIDs.count)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            // Voice debrief.
            Button {
                recorder.toggle()
            } label: {
                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.headline)
                    .foregroundStyle(recorder.isRecording ? .white : SCTheme.accent)
                    .frame(width: 44, height: 44)
                    .background(
                        recorder.isRecording ? AnyShapeStyle(Color.red) : AnyShapeStyle(SCTheme.accent.opacity(0.12)),
                        in: Circle()
                    )
            }
            .buttonStyle(.pressable)
            .sensoryFeedback(.start, trigger: recorder.isRecording) { _, isOn in isOn }
            .sensoryFeedback(.stop, trigger: recorder.isRecording) { _, isOn in !isOn }

            // Photo: an explicit choice between the camera and the
            // library, never a single icon that silently only does one of
            // the two (a plain "photo" glyph would be ambiguous now that
            // both are real options; the menu itself removes the ambiguity).
            Menu {
                if cameraAvailable {
                    Button {
                        showCamera = true
                    } label: {
                        Label("Take Photo", systemImage: "camera")
                    }
                }
                PhotosPicker(selection: $photoItems, maxSelectionCount: 4, matching: .images) {
                    Label("Choose Photo", systemImage: "photo.on.rectangle")
                }
            } label: {
                Image(systemName: photoCount == 0 ? "photo" : "photo.fill")
                    .font(.headline)
                    .foregroundStyle(SCTheme.accent)
                    .frame(width: 44, height: 44)
                    .background(SCTheme.accent.opacity(0.12), in: Circle())
                    .overlay(alignment: .topTrailing) {
                        if photoCount > 0 {
                            Text("\(photoCount)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 16, height: 16)
                                .background(SCTheme.accent, in: Circle())
                        }
                    }
            }

            // Paste.
            Button {
                if let pasted = UIPasteboard.general.string, !pasted.isEmpty {
                    text = text.isEmpty ? pasted : text + "\n" + pasted
                }
            } label: {
                Image(systemName: "doc.on.clipboard")
                    .font(.headline)
                    .foregroundStyle(SCTheme.accent)
                    .frame(width: 44, height: 44)
                    .background(SCTheme.accent.opacity(0.12), in: Circle())
            }
            .buttonStyle(.pressable)

            Spacer()

            Button {
                Task { await submit() }
            } label: {
                HStack(spacing: 6) {
                    if isSubmitting {
                        ProgressView().tint(.white).controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.subheadline.weight(.bold))
                    }
                    Text(saveErrorMessage == nil ? "Remember" : "Retry")
                        .font(.headline)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                    SCTheme.accent.opacity(canSubmit ? 1 : 0.4).gradient,
                    in: Capsule()
                )
            }
            .buttonStyle(.pressable)
            .disabled(!canSubmit || isSubmitting)
        }
    }

    // MARK: Voice

    private func appendTranscript(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            recorder.errorMessage = "Couldn't hear anything — type it instead."
            isTextFocused = true
            return
        }
        transcribedText += (transcribedText.isEmpty ? "" : "\n") + trimmed
        text = text.isEmpty ? trimmed : text + "\n" + trimmed
        // Debrief mode: opened straight into recording, nothing typed —
        // submitting right away is the whole point (say it, done).
        if request.startRecording && text == transcribedText {
            Task { await submit() }
        } else {
            isTextFocused = true
        }
    }

    // MARK: Submit

    /// Builds the capture and hands it to `CaptureProcessor.persistNewCapture`,
    /// which is the single source of truth for "is this actually durable
    /// yet". Only on a confirmed successful save do we give haptic
    /// feedback, dismiss, show the toast, and enqueue processing — in that
    /// exact order. On failure the sheet stays open, an inline error shows,
    /// no toast appears, nothing is enqueued, and the same button (now
    /// reading "Retry") tries again with a fresh capture — the failed one
    /// was already rolled back, so a retry can never create a duplicate.
    /// The same guarantee applies whether this came from typing, pasting,
    /// or a voice debrief, since they all funnel through this one method.
    private func submit() async {
        guard canSubmit, !isSubmitting else { return }
        isSubmitting = true
        saveErrorMessage = nil
        defer { isSubmitting = false }

        // Copy any picked/captured screenshots into the capture images
        // directory before building the record.
        var imageNames: [String] = []
        for item in photoItems {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let name = "\(UUID().uuidString).jpg"
            let url = CapturedMemory.imagesDirectory.appendingPathComponent(name)
            if (try? data.write(to: url, options: .atomic)) != nil {
                imageNames.append(name)
            }
        }
        for image in cameraImages {
            guard let data = image.jpegData(compressionQuality: 0.9) else { continue }
            let name = "\(UUID().uuidString).jpg"
            let url = CapturedMemory.imagesDirectory.appendingPathComponent(name)
            if (try? data.write(to: url, options: .atomic)) != nil {
                imageNames.append(name)
            }
        }

        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceOnly = !transcribedText.isEmpty && typed == transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)

        let source: CaptureSource = voiceOnly ? .voice : (!imageNames.isEmpty && typed.isEmpty ? .photo : .text)
        let trustedIDs = request.trustedPersonIDs + selectedChipIDs
        let trustedNames = request.trustedPersonNames + selectedChipIDs.compactMap { selectedChipNames[$0] }
        let capture = CapturedMemory(
            rawText: voiceOnly ? "" : typed,
            source: source,
            transcript: voiceOnly ? typed : "",
            imagePaths: imageNames,
            capturedAt: .now,
            trustedPersonIDs: trustedIDs,
            trustedPersonNames: trustedNames,
            eventName: request.eventContext?.name ?? "",
            eventDate: request.eventContext?.date,
            eventLocation: request.eventContext?.location ?? "",
            typeHint: request.typeHint
        )

        if let error = CaptureProcessor.shared.persistNewCapture(capture) {
            // Not durable — the image files just written are now orphaned
            // (harmless, small, and cleaned up implicitly since nothing
            // references them); the capture itself was rolled back, so
            // retrying is always safe.
            saveErrorMessage = error
            return
        }

        Haptics.success()
        dismiss()
        ToastCenter.shared.show("Remembered")
        Task { await CaptureProcessor.shared.processQueued() }
    }
}

// MARK: - Recorder

/// A minimal record-then-transcribe helper for the quick voice debrief:
/// record a short spoken sentence, transcribe it on-device, hand the text
/// back, and delete the audio. No person picker, no Analyze & Review — this
/// is a post-conversation debrief, not a covert recorder; the longer live
/// recording flow still lives in `VoiceCaptureView` for those who want it.
@MainActor
@Observable
final class QuickCaptureRecorder {
    var isRecording = false
    var isTranscribing = false
    var errorMessage: String?
    var onTranscript: ((String) -> Void)?

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?

    func toggle() {
        isRecording ? stop() : start()
    }

    func start() {
        guard !isRecording else { return }
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.errorMessage = "Microphone access is off. Type the note instead, or enable the mic in Settings."
                    return
                }
                self.begin()
            }
        }
    }

    private func begin() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("quick-capture-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.record()
            fileURL = url
            isRecording = true
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't start recording: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard isRecording else { return }
        recorder?.stop()
        recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        transcribe()
    }

    private func transcribe() {
        guard let fileURL else { return }
        isTranscribing = true

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized, let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
                    self.finishTranscription(text: nil, unavailable: true)
                    return
                }
                let request = SFSpeechURLRecognitionRequest(url: fileURL)
                request.requiresOnDeviceRecognition = true
                recognizer.recognitionTask(with: request) { result, error in
                    let text = (result?.isFinal == true) ? result?.bestTranscription.formattedString : nil
                    let failed = error != nil
                    guard text != nil || failed else { return }
                    Task { @MainActor in
                        if let text {
                            self.finishTranscription(text: text, unavailable: false)
                        } else {
                            self.finishTranscription(text: nil, unavailable: true)
                        }
                    }
                }
            }
        }
    }

    private func finishTranscription(text: String?, unavailable: Bool) {
        isTranscribing = false
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
        if let text, !text.isEmpty {
            onTranscript?(text)
        } else if unavailable {
            errorMessage = "Speech recognition isn't available right now — type the note instead."
        } else {
            onTranscript?("")
        }
    }

    func discard() {
        recorder?.stop()
        recorder = nil
        isRecording = false
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
    }
}

#Preview {
    QuickCaptureView(request: QuickCaptureRequest())
        .modelContainer(PreviewData.container)
}
