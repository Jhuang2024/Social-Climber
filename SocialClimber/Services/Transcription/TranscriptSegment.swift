import Foundation

/// One recognised span of speech with its timing and confidence. Segments are
/// what let the UI jump from a word back to the moment in the audio, and what
/// let cleanup mark uncertain words instead of silently inventing text.
///
/// `Codable` so a `VoiceNote` can persist the full timed transcript as JSON in
/// a single stored property (SwiftData migrates a new optional `Data` column
/// automatically) without needing a separate `@Model` and relationship.
struct TranscriptSegment: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    /// Verbatim recognised text for this span.
    var text: String
    /// Start time in seconds from the beginning of the *whole* recording, not
    /// the chunk it was transcribed in — the chunker re-bases these on
    /// recombination so timestamps always refer to the original audio.
    var start: TimeInterval
    /// End time in seconds from the beginning of the whole recording.
    var end: TimeInterval
    /// 0...1 recogniser confidence for this span. On-device Speech reports this
    /// per-segment; a value at or below `TranscriptSegment.uncertainThreshold`
    /// marks the span as uncertain.
    var confidence: Double

    init(id: UUID = UUID(), text: String, start: TimeInterval, end: TimeInterval, confidence: Double) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }

    /// Spans at or below this confidence are treated as uncertain — flagged
    /// internally rather than dropped, per the "mark, don't invent" rule.
    static let uncertainThreshold: Double = 0.3

    var isUncertain: Bool { confidence <= Self.uncertainThreshold }

    var duration: TimeInterval { max(0, end - start) }
}

/// The full result of transcribing a recording: the verbatim text, the cleaned
/// text, the timed segments, and metadata. Kept separate from the persisted
/// `VoiceNote` so the pipeline can build and pass it around as a value type.
struct TranscriptionResult: Codable, Hashable, Sendable {
    /// Verbatim recogniser output, exactly as heard, filler and all.
    var rawText: String
    /// Lightly cleaned text (filler removed, obvious fragmentation repaired).
    /// This is what the user sees by default; `rawText` is always preserved.
    var cleanedText: String
    var segments: [TranscriptSegment]
    /// BCP-47 language code the recogniser used, when it could be detected.
    var detectedLanguage: String?
    /// True when one or more chunks failed even after retries, so the caller
    /// can surface `.partialTranscription` rather than claiming success.
    var isPartial: Bool
    /// Mean confidence across segments, 0...1. Used to derive
    /// `recordingTooQuiet` / `noSpeechDetected` states.
    var averageConfidence: Double

    static let empty = TranscriptionResult(
        rawText: "", cleanedText: "", segments: [],
        detectedLanguage: nil, isPartial: false, averageConfidence: 0
    )

    var hasSpeech: Bool { !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
