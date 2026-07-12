import Foundation

/// Splits a long recording's timeline into safe, overlapping windows for
/// transcription, and recombines the per-window segment results back into one
/// continuous, correctly-timed transcript.
///
/// On-device `SFSpeechRecognizer` degrades and can time out on very long audio,
/// so anything past `maxChunkDuration` is cut into windows. Windows overlap by
/// `overlapDuration` so a word straddling a cut is heard whole in at least one
/// window; the recombiner then drops duplicates that fall inside the overlap.
///
/// This type is intentionally pure — it computes *time ranges* and merges
/// *segments*. Extracting the actual audio for a range lives in
/// `SpeechEnhancer`/`RecordingProcessor`, and is kept separate so the chunk math
/// (the part with the fiddly edge cases) is unit-testable with no audio files.
enum AudioChunker {
    /// A single window of the recording to transcribe independently.
    struct Chunk: Equatable {
        let index: Int
        /// Start offset in the original recording, seconds.
        let start: TimeInterval
        /// End offset in the original recording, seconds.
        let end: TimeInterval

        var duration: TimeInterval { end - start }
    }

    /// Longest window we hand to the recogniser at once. Kept comfortably under
    /// the point where on-device recognition gets unreliable.
    static let maxChunkDuration: TimeInterval = 45

    /// How much consecutive windows overlap, so a word on a boundary is fully
    /// contained in one of them.
    static let overlapDuration: TimeInterval = 2

    /// Computes the chunk windows for a recording of `totalDuration` seconds.
    /// Short recordings return a single chunk spanning the whole thing.
    static func chunks(
        totalDuration: TimeInterval,
        maxChunk: TimeInterval = maxChunkDuration,
        overlap: TimeInterval = overlapDuration
    ) -> [Chunk] {
        guard totalDuration > 0 else { return [] }
        guard totalDuration > maxChunk else {
            return [Chunk(index: 0, start: 0, end: totalDuration)]
        }
        // Guard against pathological inputs that would otherwise never advance.
        let safeOverlap = max(0, min(overlap, maxChunk / 2))
        let stride = maxChunk - safeOverlap

        var result: [Chunk] = []
        var start: TimeInterval = 0
        var index = 0
        while start < totalDuration {
            let end = min(start + maxChunk, totalDuration)
            result.append(Chunk(index: index, start: start, end: end))
            if end >= totalDuration { break }
            start += stride
            index += 1
        }
        return result
    }

    /// Re-bases each chunk's locally-timed segments onto the original
    /// recording's timeline and merges them, dropping segments that duplicate
    /// speech already captured by the previous chunk within the overlap region.
    ///
    /// - Parameter chunkResults: for each chunk, the chunk's window and the
    ///   segments the recogniser produced *with times relative to that chunk*
    ///   (i.e. starting at 0 for each chunk).
    static func recombine(_ chunkResults: [(chunk: Chunk, segments: [TranscriptSegment])]) -> [TranscriptSegment] {
        var merged: [TranscriptSegment] = []
        var lastEnd: TimeInterval = -1

        for entry in chunkResults.sorted(by: { $0.chunk.start < $1.chunk.start }) {
            for local in entry.segments {
                // Shift the chunk-relative time back onto the full timeline.
                let absoluteStart = entry.chunk.start + local.start
                let absoluteEnd = entry.chunk.start + local.end
                // Anything that starts at or before what we've already covered
                // is overlap-duplicated speech from the seam — skip it.
                if absoluteStart <= lastEnd { continue }
                var shifted = local
                shifted.start = absoluteStart
                shifted.end = absoluteEnd
                merged.append(shifted)
                lastEnd = max(lastEnd, absoluteEnd)
            }
        }
        return merged
    }

    /// Joins segment text into a single verbatim string, collapsing runaway
    /// whitespace but preserving word order and content.
    static func joinedText(_ segments: [TranscriptSegment]) -> String {
        segments
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
