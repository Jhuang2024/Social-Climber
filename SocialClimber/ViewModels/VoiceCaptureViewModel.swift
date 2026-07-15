import Foundation
import AVFoundation
import Observation

/// A translation the view model needs the view to perform, using Apple's
/// on-device `Translation` framework. The view model can't create a
/// `TranslationSession` itself (the API is only vended through SwiftUI's
/// `.translationTask`), so it publishes this request; `VoiceCaptureView`
/// observes it, runs the translation, and calls `fulfillTranslation`.
struct VoiceTranslationRequest: Equatable, Sendable {
    let id: UUID
    let text: String
    /// BCP-47 source-language identifier (target is always English).
    let sourceLanguageID: String
}

/// Drives the voice note flow: record audio through the shared pipeline in
/// rolling 30-second segments → each finished segment is enhanced +
/// transcribed *in the background while recording continues* → the transcript
/// builds up live → (for Mandarin) translate to English → run AI extraction.
/// No AVFoundation or Speech logic lives here; it's all in the shared
/// `VoiceRecorder` / `RecordingProcessor` / `TranscriptionService`, so every
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
    /// True while the final Mandarin→English translation is running at stop.
    var isTranslating = false

    /// The language the user chose before recording. Pins the recogniser and
    /// decides whether the transcript is translated to English before parsing.
    var recordingLanguage: RecordingLanguage = .english

    /// Segments already transcribed in the background, and those still queued,
    /// so the UI can show live progress ("captured as you talk").
    private(set) var processedSegmentCount = 0
    private(set) var pendingSegmentCount = 0

    /// The editable, user-facing transcript (built live from segment results,
    /// then replaced with the English translation for a Mandarin recording).
    var transcript = ""
    /// Verbatim transcript in the spoken language, preserved separately and
    /// never shown in the editor. For Mandarin this stays the original Mandarin.
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
    /// deterministic local fallback instead, or to carry a translation notice.
    /// Shown as an informational notice; never blocks review/apply.
    var errorMessage: String?

    /// A pending translation for the view to run via `.translationTask`.
    /// Non-nil only while a translation is in flight.
    private(set) var translationRequest: VoiceTranslationRequest?
    private var translationContinuation: CheckedContinuation<String, Never>?

    private let recorder = VoiceRecorder()
    private(set) var audioFileName: String?
    /// Contact names passed in for name-hinting during cleanup; set by the view.
    var knownContactNames: [String] = []

    // MARK: Streaming accumulation state

    /// The portion of `transcript` that came from transcription (as opposed to
    /// anything the user typed), so translation can replace exactly that part.
    private var transcribedPortion = ""
    /// Running offset (seconds) so each 30s slice's segment timestamps map onto
    /// the whole recording's timeline.
    private var segmentTimeOffset: TimeInterval = 0
    private var anySpeechCaptured = false
    private var sawPartial = false
    /// Serial chain that processes finalized segments strictly in order while
    /// recording keeps running. Awaiting the tail awaits every queued segment.
    private var processingChain: Task<Void, Never> = Task {}

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
        // Each rolling 30-second segment is transcribed in the background as
        // soon as it closes, so a long conversation never waits for one big
        // pass at the end.
        recorder.onSegmentFinalized = { [weak self] fileName in
            self?.enqueueSegment(fileName)
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
                resetForNewRecording()
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

    /// Clears transcription-derived state for a fresh capture while preserving
    /// anything the user already typed into the editor.
    private func resetForNewRecording() {
        captureFailure = nil
        errorMessage = nil
        rawTranscript = ""
        segments = []
        segmentTimeOffset = 0
        transcribedPortion = ""
        anySpeechCaptured = false
        sawPartial = false
        processedSegmentCount = 0
        pendingSegmentCount = 0
        detectedLanguage = nil
        enhancedAudioFileName = nil
        averageConfidence = 0
        processingChain = Task {}
    }

    private func stopAndProcess() async {
        let names = recorder.stopAndCollectSegments()
        guard !names.isEmpty else {
            recorder.markProcessed(success: false, failure: .recordingFailed)
            captureFailure = .recordingFailed
            return
        }
        isTranscribing = true
        defer { isTranscribing = false }

        // Wait for every queued segment (including the final one just emitted)
        // to finish transcribing before merging, since the merge removes the
        // per-segment files.
        await processingChain.value

        // Merge the raw slices into one canonical original for storage/playback.
        audioFileName = await recorder.mergeCollectedSegments(names)

        await finalizeRecording()
    }

    /// Enqueues a finalized segment for in-order background processing.
    private func enqueueSegment(_ fileName: String) {
        pendingSegmentCount += 1
        let previous = processingChain
        processingChain = Task { [weak self] in
            _ = await previous.value
            await self?.processSegment(fileName)
        }
    }

    /// Enhances + transcribes one 30-second slice and folds its result into the
    /// running transcript, segments, and metadata. Runs while recording (or the
    /// stop drain) continues.
    private func processSegment(_ fileName: String) async {
        let processed = await RecordingProcessor.shared.processInMemory(
            originalFileName: fileName,
            contactNames: knownContactNames,
            locale: recordingLanguage.recognizerLocale
        )

        // We keep only the merged original; drop the per-slice enhanced copy.
        if let enhanced = processed.enhancedFileName {
            try? FileManager.default.removeItem(at: VoiceNote.directory.appendingPathComponent(enhanced))
        }

        let sliceDuration = await Self.audioDuration(fileName: fileName)

        if !processed.segments.isEmpty {
            let offset = segmentTimeOffset
            let shifted = processed.segments.map { seg -> TranscriptSegment in
                var s = seg
                s.start += offset
                s.end += offset
                return s
            }
            segments.append(contentsOf: shifted)
        }
        // Advance the timeline by the slice's real audio length so timestamps
        // line up with the merged recording even across silent slices.
        segmentTimeOffset += sliceDuration > 0 ? sliceDuration : VoiceRecorder.rollingSegmentDuration

        if !processed.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rawTranscript += (rawTranscript.isEmpty ? "" : " ") + processed.rawTranscript
            anySpeechCaptured = true
        }
        if !processed.cleanedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendLiveTranscript(processed.cleanedTranscript)
        }
        if detectedLanguage == nil { detectedLanguage = processed.detectedLanguage }
        if processed.failure == .partialTranscription { sawPartial = true }

        processedSegmentCount += 1
        pendingSegmentCount = max(0, pendingSegmentCount - 1)
    }

    /// Appends newly transcribed text to the live editor, tracking which part
    /// of `transcript` is transcription-derived.
    private func appendLiveTranscript(_ text: String) {
        transcript += (transcript.isEmpty ? "" : " ") + text
        transcribedPortion += (transcribedPortion.isEmpty ? "" : " ") + text
    }

    /// Classifies the finished capture, translating Mandarin → English when
    /// needed, and settles the recorder in a terminal state.
    private func finalizeRecording() async {
        guard anySpeechCaptured else {
            captureFailure = .noSpeechDetected
            recorder.markProcessed(success: false, failure: .noSpeechDetected)
            return
        }

        if recordingLanguage.needsTranslationToEnglish {
            await translateToEnglishIfPossible()
        }

        averageConfidence = segments.isEmpty
            ? 0
            : segments.map(\.confidence).reduce(0, +) / Double(segments.count)
        captureFailure = sawPartial ? .partialTranscription : nil
        recorder.markProcessed(success: true, failure: captureFailure)
    }

    // MARK: Translation

    /// Translates the accumulated original-language transcript to English via
    /// the view's `.translationTask`, replacing the editable transcript with
    /// the translation while keeping the original in `rawTranscript`.
    private func translateToEnglishIfPossible() async {
        guard let source = recordingLanguage.translationSourceLanguage else { return }
        guard TranslationSupport.isAvailable else {
            errorMessage = "Recorded in \(recordingLanguage.longLabel). On-device translation needs iOS 18 or later, so the transcript is kept in its original language for you to translate manually."
            return
        }
        let original = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return }

        isTranslating = true
        defer { isTranslating = false }

        let translated = await requestTranslation(text: original, sourceLanguageID: source.minimalIdentifier)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty else {
            errorMessage = "Couldn't translate the recording automatically; showing the original \(recordingLanguage.longLabel) transcript."
            return
        }
        // Prefer the English translation in the editor (it's what gets parsed);
        // the original stays preserved in `rawTranscript`.
        transcript = translated
        transcribedPortion = translated
    }

    /// Suspends until the view fulfills the translation. Returns the original
    /// text unchanged if the view can't translate (so the flow never hangs).
    private func requestTranslation(text: String, sourceLanguageID: String) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            translationContinuation = continuation
            translationRequest = VoiceTranslationRequest(id: UUID(), text: text, sourceLanguageID: sourceLanguageID)
        }
    }

    /// Called by the view once it has a translation (or has failed to get one,
    /// in which case it passes the original text back).
    func fulfillTranslation(_ translated: String) {
        guard let continuation = translationContinuation else { return }
        translationContinuation = nil
        translationRequest = nil
        continuation.resume(returning: translated)
    }

    // MARK: Retry

    /// Manually retry transcription/enhancement on the already-merged recording,
    /// in the selected language, then translate if needed.
    func retryTranscription() async {
        guard let audioFileName else { return }
        captureFailure = nil
        errorMessage = nil
        isTranscribing = true
        defer { isTranscribing = false }

        rawTranscript = ""
        segments = []
        segmentTimeOffset = 0
        transcribedPortion = ""
        anySpeechCaptured = false
        sawPartial = false

        let processed = await RecordingProcessor.shared.processInMemory(
            originalFileName: audioFileName,
            contactNames: knownContactNames,
            locale: recordingLanguage.recognizerLocale
        )

        enhancedAudioFileName = processed.enhancedFileName
        rawTranscript = processed.rawTranscript
        segments = processed.segments
        detectedLanguage = processed.detectedLanguage
        anySpeechCaptured = !processed.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sawPartial = processed.failure == .partialTranscription
        if !processed.cleanedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            transcript = processed.cleanedTranscript
            transcribedPortion = processed.cleanedTranscript
        }

        if processed.state == .failed {
            captureFailure = processed.failure
            errorMessage = processed.failure?.message
            recorder.markProcessed(success: false, failure: processed.failure)
            return
        }

        if recordingLanguage.needsTranslationToEnglish {
            await translateToEnglishIfPossible()
        }

        averageConfidence = segments.isEmpty
            ? 0
            : segments.map(\.confidence).reduce(0, +) / Double(segments.count)
        captureFailure = sawPartial ? .partialTranscription : nil
        recorder.markProcessed(success: true, failure: captureFailure)
    }

    // MARK: AI extraction

    /// Runs extraction, passing the pre-identified participants so the AI can
    /// label who said what in the conversation.
    func analyze(knownPeople: [String], participants: [String]) async {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }
        let context = AIExtractionContext(
            trustedPersonNames: participants,
            conversationParticipants: participants
        )
        let outcome = await AIExtractionCoordinator.extract(from: text, knownPeople: knownPeople, context: context)
        extraction = outcome.extraction
        errorMessage = outcome.notice
    }

    func discardRecording() {
        processingChain.cancel()
        // Unblock any in-flight translation so its awaiting task doesn't hang.
        fulfillTranslation("")
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

    // MARK: Helpers

    private static func audioDuration(fileName: String) async -> TimeInterval {
        let url = VoiceNote.directory.appendingPathComponent(fileName)
        let asset = AVURLAsset(url: url)
        guard let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 else { return 0 }
        return seconds
    }
}
