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

    // MARK: Regressions from real captured conversations

    /// Every one of these was on screen in the first build of Past Events.
    /// They are the reason the detector now validates subject and object
    /// instead of matching a marker anywhere in a line.
    func testJunkFromRealConversationsIsRejected() {
        // "broke my" fired on any object at all. A scale is not a body part.
        assertNoEvents(in: "Sarah: broke my scale", knownPeople: ["Sarah"])

        // A question about somebody else, stored as something that happened
        // to the user, quote mark and all.
        assertNoEvents(
            in: "Sarah: yo rmb that like transfer u got into",
            knownPeople: ["Sarah"]
        )

        // "bro" is a vocative, not a subject; this said nothing about who.
        assertNoEvents(in: "Oliver: Bro got into ucb", knownPeople: ["Oliver"])

        // Further shapes the same flaw would have accepted.
        assertNoEvents(in: "Sarah: he got into ucla", knownPeople: ["Sarah"])
        assertNoEvents(in: "Sarah: we got into a fight", knownPeople: ["Sarah"])
        assertNoEvents(in: "Sarah: did u get the job", knownPeople: ["Sarah"])
        assertNoEvents(in: "Sarah: my cousin graduated", knownPeople: ["Sarah"])
    }

    /// The real thing still has to come through, and the stored title has to
    /// read as a statement rather than a quoted chat line.
    func testGenuineEventsSurviveTheTighterRules() throws {
        let events = LifeEventDetector.detect(
            in: "Oliver: bro i got into ucb\njerry: LETS GOOO",
            knownPeople: ["Oliver"],
            reference: reference
        )
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.personNames, ["Oliver"])
        XCTAssertFalse(event.aboutMe)
        XCTAssertEqual(event.kind, LifeEventKind.education.rawValue)
        // Built from the marker and its object, not lifted from the line.
        XCTAssertEqual(event.title, "Got into ucb")

        let broken = LifeEventDetector.detect(
            in: "Sarah: i broke my wrist at practice",
            knownPeople: ["Sarah"],
            reference: reference
        )
        XCTAssertEqual(broken.first?.kind, LifeEventKind.health.rawValue)
        XCTAssertEqual(broken.first?.personNames, ["Sarah"])
    }

    private func assertNoEvents(
        in text: String,
        knownPeople: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let events = LifeEventDetector.detect(in: text, knownPeople: knownPeople, reference: reference)
        XCTAssertTrue(events.isEmpty, "Expected nothing from \(text), got \(events.map(\.title))", file: file, line: line)
    }

    // MARK: Backfill of pre-existing history

    /// The whole point of `HistoryBackfill`: conversations logged before
    /// these features existed must still produce past events and a
    /// relationship, not start the feed at zero.
    func testBackfillReadsConversationsLoggedBeforeTheFeatureExisted() throws {
        let schema = Schema([
            Person.self, Interaction.self, GiftIdea.self, Reminder.self,
            ImportantDate.self, VoiceNote.self, ConversationSummary.self,
            Event.self, CapturedMemory.self, MemoryFact.self,
            LifeEvent.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        let person = Person(name: "Maya Chen", category: .acquaintance)
        context.insert(person)

        // An Instagram import from months ago, of the shape the old build
        // stored: the full transcript in `rawImportText`, and no life events
        // anywhere, because there was nowhere to put one.
        let old = Interaction(type: .socialMedia, date: Date(timeIntervalSince1970: 1_790_000_000))
        old.isImported = true
        old.rawImportText = "Maya Chen: i got into berkeley\n"
            + "jerry: YOOO\n"
            + "Maya Chen: also we're roommates next year right\n"
            + "jerry: obviously"
        old.people = [person]
        context.insert(old)

        XCTAssertTrue(try context.fetch(FetchDescriptor<LifeEvent>()).isEmpty)

        let summary = HistoryBackfill.run(context: context)

        let events = try context.fetch(FetchDescriptor<LifeEvent>())
        XCTAssertEqual(summary.eventsCreated, events.count)
        let acceptance = try XCTUnwrap(events.first { $0.kind == .education })
        XCTAssertEqual(acceptance.person?.name, "Maya Chen")
        XCTAssertFalse(acceptance.aboutMe)
        // Dated to the conversation, and honest that the exact day is a guess.
        XCTAssertEqual(acceptance.date, old.date)
        XCTAssertTrue(acceptance.isDateApproximate)
        XCTAssertEqual(acceptance.sourceInteractionUUID, old.uuid)
        // And the relationship stops being the placeholder it was created with.
        XCTAssertEqual(person.category, .roommate)
    }

    /// Running the sweep twice must not double the feed.
    func testBackfillIsIdempotent() throws {
        let schema = Schema([
            Person.self, Interaction.self, GiftIdea.self, Reminder.self,
            ImportantDate.self, VoiceNote.self, ConversationSummary.self,
            Event.self, CapturedMemory.self, MemoryFact.self,
            LifeEvent.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        let person = Person(name: "Maya Chen")
        context.insert(person)
        let interaction = Interaction(type: .socialMedia, date: Date(timeIntervalSince1970: 1_790_000_000))
        interaction.rawImportText = "Maya Chen: i got into berkeley"
        interaction.people = [person]
        context.insert(interaction)

        HistoryBackfill.run(context: context)
        let firstPass = try context.fetch(FetchDescriptor<LifeEvent>()).count
        XCTAssertGreaterThan(firstPass, 0)

        let second = HistoryBackfill.run(context: context)
        XCTAssertEqual(second.eventsCreated, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LifeEvent>()).count, firstPass)
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
