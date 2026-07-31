import XCTest
import SwiftData
@testable import SocialClimber

/// Covers the two things the app now works out from a conversation itself:
/// how the user knows someone, and what has actually happened to them.
///
/// Most of these assertions are about *restraint*. Both features are only
/// useful if they stay quiet on ordinary chat, so the negative cases matter
/// more than the positive ones.
@MainActor
final class ConversationInferenceTests: XCTestCase {

    private let reference = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Relationship inference

    func testExplicitRelationshipIsReadFromTheConversation() {
        let guesses = RelationshipInference.guesses(
            in: "Grabbed dinner with Maya Chen, my roommate this year",
            subjectNames: ["Maya Chen"]
        )
        let guess = guesses.first
        XCTAssertEqual(guess?.category, PersonCategory.roommate.rawValue)
        XCTAssertEqual(guess?.personName, "Maya Chen")
        XCTAssertGreaterThanOrEqual(guess?.confidence ?? 0, 0.8)
    }

    /// A relationship word about somebody else ("her sister") describes a
    /// third party, not the contact being written about.
    func testThirdPartyRelationshipWordIsNotReadAsTheContactsOwn() {
        let guesses = RelationshipInference.guesses(
            in: "Maya Chen said her sister is visiting next week.",
            subjectNames: ["Maya Chen"]
        )
        XCTAssertTrue(guesses.isEmpty)
    }

    func testOrdinaryChatProducesNoRelationshipGuess() {
        let guesses = RelationshipInference.guesses(
            in: "Maya Chen: lol ok\nMe: bet\nMaya Chen: ts is crazy",
            subjectNames: ["Maya Chen"]
        )
        XCTAssertTrue(guesses.isEmpty)
    }

    func testAppliedRelationshipNeverOverwritesAUserChoice() {
        let person = Person(name: "Maya Chen", category: .family)
        person.categoryIsUserSet = true
        person.relationshipToMe = "My cousin"
        person.relationshipIsUserSet = true

        let guess = ExtractedRelationship(
            personName: "Maya Chen",
            category: PersonCategory.professional.rawValue,
            descriptor: "Coworker",
            confidence: 0.95
        )
        if case .applied = RelationshipInference.apply(guess, to: person) {
            XCTFail("A category the user picked must never be overwritten")
        }
        XCTAssertEqual(person.category, .family)
        XCTAssertEqual(person.relationshipToMe, "My cousin")
    }

    func testInferenceFillsInAnUntouchedContactAndThenOnlyImproves() {
        let person = Person(name: "Maya Chen", category: .acquaintance)

        let weak = ExtractedRelationship(
            personName: "Maya Chen",
            category: PersonCategory.classmate.rawValue,
            descriptor: "",
            confidence: 0.55
        )
        RelationshipInference.apply(weak, to: person)
        XCTAssertEqual(person.category, .classmate)

        // A weaker later read must not undo a stronger earlier one…
        let weaker = ExtractedRelationship(
            personName: "Maya Chen",
            category: PersonCategory.professional.rawValue,
            descriptor: "",
            confidence: 0.5
        )
        RelationshipInference.apply(weaker, to: person)
        XCTAssertEqual(person.category, .classmate)

        // …but a stronger one may.
        let strong = ExtractedRelationship(
            personName: "Maya Chen",
            category: PersonCategory.roommate.rawValue,
            descriptor: "Roommate",
            confidence: 0.85
        )
        RelationshipInference.apply(strong, to: person)
        XCTAssertEqual(person.category, .roommate)
        XCTAssertEqual(person.relationshipToMe, "Roommate")
    }

    // MARK: Past events

    func testRealEventIsDetectedAndAttributedToTheSpeaker() {
        let events = LifeEventDetector.detect(
            in: "Maya Chen: i got into berkeley\nMe: yooo congrats",
            knownPeople: ["Maya Chen"],
            reference: reference
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, LifeEventKind.education.rawValue)
        XCTAssertEqual(events.first?.personNames, ["Maya Chen"])
        XCTAssertEqual(events.first?.aboutMe, false)
    }

    /// Once one sender resolves to a contact, the other sender is the user.
    func testNarratorLineIsAttributedToTheUser() {
        let events = LifeEventDetector.detect(
            in: "Maya Chen: any news\njerry: i got the internship at stripe",
            knownPeople: ["Maya Chen"],
            reference: reference
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.aboutMe, true)
        XCTAssertEqual(events.first?.kind, LifeEventKind.career.rawValue)
    }

    func testPlansAndHypotheticalsAreNotEvents() {
        let events = LifeEventDetector.detect(
            in: """
            Maya Chen: i might get into berkeley if the waitlist moves
            jerry: i'm gonna quit my job eventually
            Maya Chen: would be nice to move to nyc
            jerry: did you get the internship?
            """,
            knownPeople: ["Maya Chen"],
            reference: reference
        )
        XCTAssertTrue(events.isEmpty, "Got: \(events.map(\.title))")
    }

    func testEverydayChatProducesNoEvents() {
        let events = LifeEventDetector.detect(
            in: """
            Maya Chen: lol
            jerry: ts assignment is brutal
            Maya Chen: fr. did u eat
            jerry: nah gonna get boba later
            """,
            knownPeople: ["Maya Chen"],
            reference: reference
        )
        XCTAssertTrue(events.isEmpty, "Got: \(events.map(\.title))")
    }

    /// Something that happened to an untracked third party must not be
    /// pinned on the speaker.
    func testThirdPartyEventIsDropped() {
        let events = LifeEventDetector.detect(
            in: "Maya Chen: my brother got into berkeley",
            knownPeople: ["Maya Chen"],
            reference: reference
        )
        XCTAssertTrue(events.isEmpty, "Got: \(events.map(\.title))")
    }

    /// The bar applies to whatever a real AI provider returns too, not just
    /// the offline heuristic.
    func testQualityGateRejectsWeakAICandidates() {
        XCTAssertFalse(LifeEventDetector.isWorthKeeping(
            ExtractedLifeEvent(title: "Talked", significance: 3)
        ))
        XCTAssertFalse(LifeEventDetector.isWorthKeeping(
            ExtractedLifeEvent(title: "Might move to New York", significance: 4)
        ))
        XCTAssertFalse(LifeEventDetector.isWorthKeeping(
            ExtractedLifeEvent(title: "Did she get the job?", significance: 4)
        ))
        XCTAssertFalse(LifeEventDetector.isWorthKeeping(
            ExtractedLifeEvent(title: "Mentioned liking ramen", significance: 1)
        ))
        XCTAssertTrue(LifeEventDetector.isWorthKeeping(
            ExtractedLifeEvent(title: "Got into Berkeley", significance: 5)
        ))
    }
}
