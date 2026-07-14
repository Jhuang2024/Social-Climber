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
}
