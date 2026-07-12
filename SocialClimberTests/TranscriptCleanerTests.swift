import XCTest
@testable import SocialClimber

/// Tests the conservative transcript cleaner: filler removal, repeat collapse,
/// and strong-only contact-name normalisation (no hallucination).
final class TranscriptCleanerTests: XCTestCase {

    func testRemovesStandaloneFiller() {
        let cleaned = TranscriptCleaner.clean("So um I uh went to the store")
        XCTAssertFalse(cleaned.lowercased().contains(" um "))
        XCTAssertFalse(cleaned.lowercased().contains(" uh "))
        XCTAssertTrue(cleaned.contains("went to the store"))
    }

    func testDoesNotRemoveFillerInsideWords() {
        // "umbrella" contains "um" but must survive.
        let cleaned = TranscriptCleaner.clean("I bought an umbrella")
        XCTAssertTrue(cleaned.contains("umbrella"))
    }

    func testCollapsesImmediateRepeats() {
        let cleaned = TranscriptCleaner.clean("I I went to the the park")
        XCTAssertEqual(cleaned, "I went to the park")
    }

    func testPreservesMeaningfulWords() {
        // "like" and "so" are meaningful — not stripped.
        let cleaned = TranscriptCleaner.clean("I like it so much")
        XCTAssertTrue(cleaned.contains("like"))
        XCTAssertTrue(cleaned.contains("so"))
    }

    func testExactNameNormalizesCasing() {
        let cleaned = TranscriptCleaner.normalizeNames(in: "met sarah today", contactNames: ["Sarah Chen"])
        XCTAssertTrue(cleaned.contains("Sarah"))
        XCTAssertFalse(cleaned.contains("sarah "))
    }

    func testStrongTypoIsCorrected() {
        // Single-edit typo of a ≥5-char name, unambiguous → corrected.
        // "Sarrah" is one deletion away from "Sarah".
        let cleaned = TranscriptCleaner.normalizeNames(in: "talked to Sarrah", contactNames: ["Sarah"])
        XCTAssertTrue(cleaned.contains("Sarah"))
    }

    func testWeakMatchIsNotReplaced() {
        // "Sam" vs "Sarah" is not a strong match — left exactly as spoken.
        let cleaned = TranscriptCleaner.normalizeNames(in: "talked to Sam", contactNames: ["Sarah"])
        XCTAssertTrue(cleaned.contains("Sam"))
        XCTAssertFalse(cleaned.contains("Sarah"))
    }

    func testAmbiguousNearMatchNotReplaced() {
        // Two contacts both one edit away → ambiguous, don't guess.
        let cleaned = TranscriptCleaner.normalizeNames(in: "with Jonn", contactNames: ["John", "Joan"])
        XCTAssertTrue(cleaned.contains("Jonn"))
    }

    func testDoesNotInventText() {
        // Cleaning never adds words.
        let input = "quick note"
        let cleaned = TranscriptCleaner.clean(input, contactNames: ["Alexandra"])
        XCTAssertEqual(cleaned, "quick note")
    }

    func testLevenshtein() {
        XCTAssertEqual(TranscriptCleaner.levenshtein("kitten", "kitten"), 0)
        XCTAssertEqual(TranscriptCleaner.levenshtein("kitten", "sitten"), 1)
        XCTAssertEqual(TranscriptCleaner.levenshtein("kitten", "sitting"), 3)
        XCTAssertEqual(TranscriptCleaner.levenshtein("", "abc"), 3)
    }

    func testEmptyInput() {
        XCTAssertEqual(TranscriptCleaner.clean(""), "")
        XCTAssertEqual(TranscriptCleaner.clean("   \n  "), "")
    }
}
