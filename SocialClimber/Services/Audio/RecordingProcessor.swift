import Foundation
import SwiftData

/// Orchestrates "audio file → transcript" for the whole app: enhance a copy,
/// transcribe it, classify the outcome into an honest state, and (for persisted
/// notes) write the result back idempotently.
///
/// Two entry points share one core:
///   • `processInMemory`: used by the live capture flow before a `VoiceNote`
///     exists, so the review screen can show a transcript without a
///     loading-screen wait or a half-saved record.
///   • `process(note:)`: used to (re)process or retry a saved `VoiceNote`,
///     guarded so relaunching the app or reopening a note never reprocesses an
///     already-finished one or runs two passes at once.
@MainActor
final class RecordingProcessor {
    static let shared = RecordingProcessor()
    private init() {}

    /// Notes currently being processed, so re-entry can't double-process.
    private var inFlight: Set<PersistentIdentifier> = []

    /// The full outcome of processing an audio file, independent of SwiftData.
    struct ProcessedRecording {
        var rawTranscript: String
        var cleanedTranscript: String
        var segments: [TranscriptSegment]
        var enhancedFileName: String?
        var detectedLanguage: String?
        var averageConfidence: Double
        var state: AudioCaptureState
        var failure: AudioCaptureFailure?
    }

    // MARK: In-memory processing (live capture, no persisted note yet)

    /// Enhances and transcribes `originalFileName`, returning a fully-classified
    /// result. Runs enhancement off the main thread. Never mutates the original
    /// file. `locale` pins the transcription language (e.g. Mandarin); when
    /// `nil` the device's preferred language is used.
    func processInMemory(originalFileName: String, contactNames: [String], locale: Locale? = nil) async -> ProcessedRecording {
        AudioLog.info("Processing recording (\(originalFileName.count > 0 ? "present" : "missing"))")

        // 1–6. Enhance a copy (analysis + conservative DSP).
        let enhancement = await SpeechEnhancer.enhance(originalFileName: originalFileName)
        let analysis = enhancement.analysis

        if analysis.isEffectivelySilent {
            return ProcessedRecording(
                rawTranscript: "", cleanedTranscript: "", segments: [],
                enhancedFileName: enhancement.enhancedFileName, detectedLanguage: nil,
                averageConfidence: 0, state: .failed, failure: .noSpeechDetected
            )
        }

        // 7–9. Transcribe the enhanced copy (or original if enhancement was
        // skipped), chunking + recombining internally.
        let transcribeTarget = enhancement.enhancedFileName ?? originalFileName
        let result = await TranscriptionService.shared.transcribe(
            fileName: transcribeTarget,
            contactNames: contactNames,
            locale: locale
        )

        // Classify the outcome into an honest state.
        if !result.hasSpeech {
            let failure: AudioCaptureFailure
            if analysis.isTooQuiet { failure = .recordingTooQuiet }
            else if analysis.isNoisy { failure = .excessiveBackgroundNoise }
            else { failure = .transcriptionUnavailable }
            return ProcessedRecording(
                rawTranscript: "", cleanedTranscript: "", segments: [],
                enhancedFileName: enhancement.enhancedFileName, detectedLanguage: result.detectedLanguage,
                averageConfidence: result.averageConfidence, state: .failed, failure: failure
            )
        }

        return ProcessedRecording(
            rawTranscript: result.rawText,
            cleanedTranscript: result.cleanedText,
            segments: result.segments,
            enhancedFileName: enhancement.enhancedFileName,
            detectedLanguage: result.detectedLanguage,
            averageConfidence: result.averageConfidence,
            state: .completed,
            // A partial result still succeeds, but carries an informational
            // marker so the UI can offer to retry the missing part.
            failure: result.isPartial ? .partialTranscription : nil
        )
    }

    // MARK: Persisted processing / retry (idempotent)

    /// (Re)processes a saved note. Idempotent: a note that already finished is
    /// left alone unless `force` is set (manual retry), and a note already being
    /// processed is never processed twice concurrently.
    func process(note: VoiceNote, contactNames: [String], context: ModelContext, force: Bool = false) async {
        let id = note.persistentModelID
        guard !inFlight.contains(id) else { return }
        guard let originalFileName = note.audioFileName else { return }
        if note.isProcessed && note.processingState == .completed && !force { return }

        inFlight.insert(id)
        defer { inFlight.remove(id) }

        note.processingState = .processing
        note.failureReason = nil
        note.transcriptionAttempts += 1
        try? context.save()

        // Reprocess in the note's own recognised language so a Mandarin note
        // isn't retried with the wrong recogniser.
        let locale = note.detectedLanguage.map(Locale.init(identifier:))
        let processed = await processInMemory(originalFileName: originalFileName, contactNames: contactNames, locale: locale)
        apply(processed, to: note)
        note.processedAt = .now
        try? context.save()
    }

    /// Writes a `ProcessedRecording` onto a note without clobbering user edits:
    /// `transcript` is only seeded from the cleaned text when the user hasn't
    /// already typed/edited one.
    func apply(_ processed: ProcessedRecording, to note: VoiceNote) {
        note.rawTranscript = processed.rawTranscript
        note.cleanedTranscript = processed.cleanedTranscript
        note.segments = processed.segments
        note.enhancedAudioFileName = processed.enhancedFileName
        note.detectedLanguage = processed.detectedLanguage
        note.averageConfidence = processed.averageConfidence
        note.processingState = processed.state
        note.failureReason = processed.failure
        if note.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            note.transcript = processed.cleanedTranscript
        }
    }

    /// Re-runs any saved notes that never finished (failed or left mid-process
    /// by a crash). Called when the app becomes active so pending work isn't
    /// stranded. Skips notes already completed; idempotent by construction.
    func processPending(context: ModelContext, contactNames: [String]) async {
        let descriptor = FetchDescriptor<VoiceNote>()
        guard let notes = try? context.fetch(descriptor) else { return }
        for note in notes where note.audioFileName != nil {
            let state = note.processingState
            let stranded = state == .processing || (state == .failed && note.failureReason?.isRetryable == true)
            // Only auto-retry things left mid-flight; never re-touch completed
            // notes or ones the user explicitly failed out of recently.
            guard stranded, !note.isProcessed || state == .processing else { continue }
            await process(note: note, contactNames: contactNames, context: context)
        }
    }
}
