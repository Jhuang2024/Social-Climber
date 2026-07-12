import Foundation
import Observation

/// Drives the voice note flow: record audio through the shared pipeline →
/// enhance + transcribe (on-device, confidence-aware) → run AI extraction. No
/// AVFoundation or Speech logic lives here anymore — it's all in the shared
/// `VoiceRecorder` / `RecordingProcessor` / `TranscriptionService` so every
/// capture screen behaves identically.
@Observable
@MainActor
final class VoiceCaptureViewModel {

    // Mirrors of the recorder's state, so SwiftUI tracks them via @Observable.
    var recordingState: AudioCaptureState = .idle
    var level: Float = 0
    var duration: TimeInterval = 0

    var isTranscribing = false
    var isAnalyzing = false

    /// The editable, user-facing transcript (seeded from the cleaned copy).
    var transcript = ""
    /// Verbatim transcript, preserved separately and never shown in the editor.
    private(set) var rawTranscript = ""
    private(set) var segments: [TranscriptSegment] = []
    private(set) var enhancedAudioFileName: String?
    private(set) var detectedLanguage: String?
    private(set) var averageConfidence: Double = 0
    /// A processing/recording failure to surface (retryable). Distinct from
    /// `errorMessage`, which is the AI-provider degradation notice.
    private(set) var captureFailure: AudioCaptureFailure?

    var extraction: AIExtraction?
    /// Set when the configured AI provider failed and `extraction` is the
    /// deterministic local fallback instead, shown as an informational
    /// notice, never blocks review/apply.
    var errorMessage: String?

    private let recorder = VoiceRecorder()
    private(set) var audioFileName: String?
    /// Contact names passed in for name-hinting during cleanup; set by the view.
    var knownContactNames: [String] = []

    // Convenience flags the view already relied on.
    var isRecording: Bool { recordingState == .recording }
    var isPaused: Bool { recordingState == .paused }
    var isInterrupted: Bool { recordingState == .interrupted }

    /// A value-type snapshot of the processed recording, handed to the review
    /// screen so the persisted `VoiceNote` keeps raw/cleaned transcripts,
    /// timed segments, and pipeline metadata.
    struct RecordingPayload {
        var rawTranscript: String
        var cleanedTranscript: String
        var segments: [TranscriptSegment]
        var enhancedAudioFileName: String?
        var detectedLanguage: String?
        var averageConfidence: Double
        var failure: AudioCaptureFailure?
    }

    var recordingPayload: RecordingPayload {
        RecordingPayload(
            rawTranscript: rawTranscript,
            cleanedTranscript: transcript,
            segments: segments,
            enhancedAudioFileName: enhancedAudioFileName,
            detectedLanguage: detectedLanguage,
            averageConfidence: averageConfidence,
            failure: captureFailure
        )
    }

    init() {
        recorder.onChange = { [weak self] in
            guard let self else { return }
            self.recordingState = self.recorder.state
            self.level = self.recorder.level
            self.duration = self.recorder.duration
            if self.recorder.state == .failed {
                self.captureFailure = self.recorder.failure
            }
        }
    }

    // MARK: Recording

    func toggleRecording() {
        Task {
            if recordingState == .recording {
                await stopAndProcess()
            } else if recordingState == .paused || recordingState == .interrupted {
                recorder.resume()
            } else {
                captureFailure = nil
                errorMessage = nil
                await recorder.start()
                if recorder.state == .failed {
                    captureFailure = recorder.failure
                    errorMessage = recorder.failure?.message
                }
            }
        }
    }

    func pauseRecording() { recorder.pause() }
    func resumeRecording() { recorder.resume() }

    private func stopAndProcess() async {
        guard let fileName = await recorder.stop() else {
            recorder.markProcessed(success: false, failure: .recordingFailed)
            captureFailure = .recordingFailed
            return
        }
        audioFileName = fileName
        await runProcessing(originalFileName: fileName)
    }

    /// Runs the shared enhance + transcribe pipeline and folds the result into
    /// the editable transcript. Used for the initial pass and manual retries.
    private func runProcessing(originalFileName: String) async {
        isTranscribing = true
        defer { isTranscribing = false }

        let processed = await RecordingProcessor.shared.processInMemory(
            originalFileName: originalFileName,
            contactNames: knownContactNames
        )

        rawTranscript = processed.rawTranscript
        segments = processed.segments
        enhancedAudioFileName = processed.enhancedFileName
        detectedLanguage = processed.detectedLanguage
        averageConfidence = processed.averageConfidence
        captureFailure = processed.failure

        // Seed the editor with the cleaned transcript, appending if the user has
        // already typed something so nothing is lost.
        if !processed.cleanedTranscript.isEmpty {
            transcript += (transcript.isEmpty ? "" : "\n") + processed.cleanedTranscript
        }

        recorder.markProcessed(success: processed.state == .completed, failure: processed.failure)
        if let failure = processed.failure, processed.state == .failed {
            errorMessage = failure.message
        }
    }

    /// Manually retry transcription/enhancement on the already-recorded audio.
    func retryTranscription() async {
        guard let audioFileName else { return }
        captureFailure = nil
        errorMessage = nil
        await runProcessing(originalFileName: audioFileName)
    }

    // MARK: AI extraction

    func analyze(knownPeople: [String]) async {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }
        let outcome = await AIExtractionCoordinator.extract(from: text, knownPeople: knownPeople)
        extraction = outcome.extraction
        errorMessage = outcome.notice
    }

    func discardRecording() {
        recorder.discard()
        if let audioFileName {
            try? FileManager.default.removeItem(at: VoiceNote.directory.appendingPathComponent(audioFileName))
        }
        if let enhancedAudioFileName {
            try? FileManager.default.removeItem(at: VoiceNote.directory.appendingPathComponent(enhancedAudioFileName))
        }
        audioFileName = nil
        enhancedAudioFileName = nil
    }
}
