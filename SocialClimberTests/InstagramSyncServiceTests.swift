import XCTest
import SwiftData
@testable import SocialClimber

@MainActor
final class InstagramSyncServiceTests: XCTestCase {
    private var container: ModelContainer!

    override func setUp() {
        super.setUp()
        let schema = Schema([
            Person.self, Interaction.self, GiftIdea.self, Reminder.self,
            ImportantDate.self, VoiceNote.self, ConversationSummary.self,
            Event.self, CapturedMemory.self, MemoryFact.self,
            FollowerSnapshot.self, FollowerEvent.self,
        ])
        container = try! ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    func testExistingInstagramInteractionIsBackfilledAsOneRecentCapture() async throws {
        let context = container.mainContext
        let person = Person(name: "Alex Rivera")
        context.insert(person)

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let message = InstagramExportParser.Message(sender: "Alex Rivera", date: date, text: "See you tomorrow")
        let candidate = InstagramSyncService.ThreadCandidate(
            title: "Alex Rivera",
            otherParticipant: "Alex Rivera",
            messages: [message],
            matchedPerson: person,
            threadKey: "alex rivera|jerry"
        )
        let interaction = Interaction(type: .socialMedia, date: date, note: candidate.digestText)
        interaction.isImported = true
        interaction.platform = .instagram
        interaction.rawImportText = candidate.digestText
        interaction.messageSummary = "Made plans for tomorrow"
        interaction.people = [person]
        context.insert(interaction)

        await InstagramSyncService.shared.apply(candidate: candidate, to: person, context: context)
        await InstagramSyncService.shared.apply(candidate: candidate, to: person, context: context)

        let captures = try context.fetch(FetchDescriptor<CapturedMemory>())
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first?.source, .instagram)
        XCTAssertEqual(captures.first?.status, .processed)
        XCTAssertEqual(captures.first?.title, "Instagram with Alex")
        XCTAssertEqual(interaction.sourceCaptureUUID, captures.first?.uuid)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Interaction>()).count, 1)
    }

    func testLegacyInstagramArtifactsAreMigratedToSuggestionsAndDeduplicated() throws {
        let context = container.mainContext
        let person = Person(name: "Tony Yang")
        person.interests = ["Golf", "Selling my grades"]
        person.personalityNotes = "Existing manual note\nTony Yang: that's not always true"
        context.insert(person)

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        func makeImport() -> Interaction {
            let interaction = Interaction(type: .socialMedia, date: date, note: "Tony Yang: that's not always true")
            interaction.isImported = true
            interaction.platform = .instagram
            interaction.rawImportText = "Tony Yang: that's not always true"
            interaction.followUpNeeded = true
            interaction.people = [person]
            let extraction = AIExtraction(
                summary: "Talked about school.",
                interests: ["Selling my grades"],
                importantDates: [ExtractedDate(title: "Important date", date: date, display: "May 1")],
                reminders: [ExtractedReminder(title: "Follow up about deadlines", dueDate: date)],
                personalityNotes: ["Tony Yang: that's not always true"]
            )
            let summary = ConversationSummary(extraction: extraction)
            summary.interaction = interaction
            context.insert(interaction)
            context.insert(summary)
            return interaction
        }
        let first = makeImport()
        _ = makeImport()

        let badDate = ImportantDate(title: "Important date", date: date, person: person)
        let badReminder = Reminder(title: "Follow up about deadlines", dueDate: date, type: .followUp, person: person)
        badDate.createdAt = first.createdAt
        badReminder.createdAt = first.createdAt
        context.insert(badDate)
        context.insert(badReminder)

        InstagramSyncService.shared.repairLegacyImportArtifacts(people: [person], context: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Interaction>()).count, 1)
        let keptInteraction = try XCTUnwrap(context.fetch(FetchDescriptor<Interaction>()).first)
        XCTAssertFalse(keptInteraction.followUpNeeded)
        let captures = try context.fetch(FetchDescriptor<CapturedMemory>())
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first?.source, .instagram)
        XCTAssertEqual(keptInteraction.sourceCaptureUUID, captures.first?.uuid)
        XCTAssertEqual(person.interests, ["Golf"])
        XCTAssertEqual(person.personalityNotes, "Existing manual note")
        XCTAssertTrue(person.importantDates.isEmpty)
        XCTAssertTrue(person.reminders.isEmpty)
        let facts = try context.fetch(FetchDescriptor<MemoryFact>())
        XCTAssertTrue(facts.contains { $0.type == .interest && $0.value == "Selling my grades" && $0.status == .suggested })
        XCTAssertTrue(facts.contains { $0.type == .importantDate && $0.status == .suggested })
        XCTAssertTrue(facts.contains { $0.type == .reminderSuggestion && $0.status == .suggested })
        XCTAssertFalse(facts.contains { $0.type == .personality && $0.value.contains("Tony Yang:") })
    }
}
