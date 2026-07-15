import Foundation
import SwiftData

@Model
final class VoiceNote {
    /// File name inside the app's Documents/VoiceNotes directory. This is the
    /// preserved *original* recording; enhancement and transcription never
    /// overwrite it.
    var audioFileName: String?

    /// The transcript shown to and edited by the user. Kept for backward
    /// compatibility; on new captures it starts as the cleaned transcript and
    /// the user's edits live here.
    var transcript: String = ""

    var createdAt: Date = Date()

    // MARK: Audio pipeline (all additive with defaults → lightweight migration)

    /// Verbatim recogniser output, preserved separately from the cleaned copy.
    var rawTranscript: String = ""
    /// Filler-stripped, lightly-repaired reading copy the pipeline produced.
    /// `transcript` is seeded from this but may then diverge as the user edits.
    var cleanedTranscript: String = ""
    /// File name of the enhanced audio copy used for transcription. Never the
    /// original; may be nil when enhancement was skipped.
    var enhancedAudioFileName: String?
    /// Encoded `[TranscriptSegment]`: timed, confidence-tagged spans that let
    /// the UI jump from text back to audio and flag uncertain words.
    var segmentsData: Data?
    /// Detected/used recognition language (BCP-47), when known.
    var detectedLanguage: String?
    /// Mean recogniser confidence across segments, 0...1.
    var averageConfidence: Double = 0
    /// Current lifecycle state. Existing notes default to `.completed` so
    /// migration never marks historical notes as unprocessed.
    var processingStateRaw: String = AudioCaptureState.completed.rawValue
    /// Failure reason when `processingState == .failed`.
    var failureReasonRaw: String?
    /// When processing last finished: the idempotency guard. A note with a set
    /// `processedAt` is never re-processed on relaunch unless the user asks.
    var processedAt: Date?
    /// How many times transcription has been attempted, for backoff/telemetry.
    var transcriptionAttempts: Int = 0

    /// Encoded `[ConversationLine]`: the AI's best-effort "who said what" split
    /// of the conversation, using the participants picked before recording plus
    /// the narrator. A reading aid; nil/empty when attribution wasn't produced.
    var conversationData: Data?

    var people: [Person] = []

    @Relationship(deleteRule: .cascade, inverse: \ConversationSummary.voiceNote)
    var aiSummary: ConversationSummary?

    init(audioFileName: String? = nil, transcript: String = "") {
        self.audioFileName = audioFileName
        self.transcript = transcript
        self.createdAt = .now
    }

    var audioURL: URL? {
        guard let audioFileName else { return nil }
        return VoiceNote.directory.appendingPathComponent(audioFileName)
    }

    /// URL of the enhanced copy, if one exists.
    var enhancedAudioURL: URL? {
        guard let enhancedAudioFileName else { return nil }
        return VoiceNote.directory.appendingPathComponent(enhancedAudioFileName)
    }

    // MARK: Typed accessors over the raw stored values

    var processingState: AudioCaptureState {
        get { AudioCaptureState(rawValue: processingStateRaw) ?? .completed }
        set { processingStateRaw = newValue.rawValue }
    }

    var failureReason: AudioCaptureFailure? {
        get { failureReasonRaw.flatMap(AudioCaptureFailure.init(rawValue:)) }
        set { failureReasonRaw = newValue?.rawValue }
    }

    var segments: [TranscriptSegment] {
        get {
            guard let segmentsData else { return [] }
            return (try? JSONDecoder().decode([TranscriptSegment].self, from: segmentsData)) ?? []
        }
        set { segmentsData = try? JSONEncoder().encode(newValue) }
    }

    var conversation: [ConversationLine] {
        get {
            guard let conversationData else { return [] }
            return (try? JSONDecoder().decode([ConversationLine].self, from: conversationData)) ?? []
        }
        set { conversationData = newValue.isEmpty ? nil : (try? JSONEncoder().encode(newValue)) }
    }

    /// True when the recording was spoken in a non-English language and its
    /// editable transcript is a translation (the original is in `rawTranscript`).
    var wasTranslated: Bool {
        RecordingLanguage.from(languageCode: detectedLanguage).needsTranslationToEnglish
            && !rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True when the pipeline has already produced a final result for this note,
    /// so re-entry (relaunch, reopening) must not reprocess it.
    var isProcessed: Bool { processedAt != nil }

    static var directory: URL {
        let dir = URL.documentsDirectory.appendingPathComponent("VoiceNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
