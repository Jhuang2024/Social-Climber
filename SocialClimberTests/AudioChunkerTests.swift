import XCTest
@testable import SocialClimber

/// Tests chunk-window computation and timestamp-preserving recombination —
/// including the overlap-dedup at seams.
final class AudioChunkerTests: XCTestCase {

    func testShortAudioIsSingleChunk() {
        let chunks = AudioChunker.chunks(totalDuration: 30)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].start, 0)
        XCTAssertEqual(chunks[0].end, 30)
    }

    func testZeroDurationHasNoChunks() {
        XCTAssertTrue(AudioChunker.chunks(totalDuration: 0).isEmpty)
    }

    func testLongAudioSplitsWithOverlap() {
        let chunks = AudioChunker.chunks(totalDuration: 100, maxChunk: 45, overlap: 2)
        XCTAssertGreaterThan(chunks.count, 1)
        // First chunk is a full window.
        XCTAssertEqual(chunks[0].start, 0)
        XCTAssertEqual(chunks[0].end, 45)
        // Consecutive chunks overlap by exactly `overlap`.
        let stride = chunks[1].start - chunks[0].start
        XCTAssertEqual(stride, 43, accuracy: 0.0001) // 45 - 2
        // Last chunk ends exactly at the total duration.
        XCTAssertEqual(chunks.last!.end, 100, accuracy: 0.0001)
    }

    func testChunksCoverEntireTimeline() {
        let total: TimeInterval = 200
        let chunks = AudioChunker.chunks(totalDuration: total, maxChunk: 45, overlap: 2)
        // No gaps: each chunk starts before the previous one ended.
        for i in 1..<chunks.count {
            XCTAssertLessThanOrEqual(chunks[i].start, chunks[i - 1].end)
        }
        XCTAssertEqual(chunks.last!.end, total, accuracy: 0.0001)
    }

    func testRecombineRebasesTimestamps() {
        // Two chunks; each reports chunk-relative segment times starting at 0.
        let chunk0 = AudioChunker.Chunk(index: 0, start: 0, end: 45)
        let chunk1 = AudioChunker.Chunk(index: 1, start: 43, end: 88)
        let seg0 = [TranscriptSegment(text: "hello", start: 1, end: 2, confidence: 0.9)]
        let seg1 = [TranscriptSegment(text: "world", start: 5, end: 6, confidence: 0.8)]

        let merged = AudioChunker.recombine([(chunk0, seg0), (chunk1, seg1)])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].start, 1, accuracy: 0.0001)   // 0 + 1
        XCTAssertEqual(merged[1].start, 48, accuracy: 0.0001)  // 43 + 5
    }

    func testRecombineDropsOverlapDuplicates() {
        // A word captured in the tail of chunk0 AND the head of chunk1 (the
        // overlap) must not appear twice.
        let chunk0 = AudioChunker.Chunk(index: 0, start: 0, end: 45)
        let chunk1 = AudioChunker.Chunk(index: 1, start: 43, end: 88)
        // "seam" occurs at absolute t≈44 in both chunks.
        let seg0 = [TranscriptSegment(text: "seam", start: 44, end: 44.5, confidence: 0.9)]
        let seg1 = [
            TranscriptSegment(text: "seam", start: 1, end: 1.5, confidence: 0.9),   // abs 44
            TranscriptSegment(text: "after", start: 3, end: 3.5, confidence: 0.9),  // abs 46
        ]
        let merged = AudioChunker.recombine([(chunk0, seg0), (chunk1, seg1)])
        let words = merged.map(\.text)
        XCTAssertEqual(words, ["seam", "after"])
    }

    func testJoinedTextCollapsesWhitespace() {
        let segs = [
            TranscriptSegment(text: " hello ", start: 0, end: 1, confidence: 1),
            TranscriptSegment(text: "", start: 1, end: 1, confidence: 1),
            TranscriptSegment(text: "world", start: 1, end: 2, confidence: 1),
        ]
        XCTAssertEqual(AudioChunker.joinedText(segs), "hello world")
    }

    func testUncertainSegmentFlag() {
        let low = TranscriptSegment(text: "mumble", start: 0, end: 1, confidence: 0.2)
        let high = TranscriptSegment(text: "clear", start: 0, end: 1, confidence: 0.9)
        XCTAssertTrue(low.isUncertain)
        XCTAssertFalse(high.isUncertain)
    }
}
