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

    func testLargePartialExportJumpReplacesBaseline() {
        XCTAssertTrue(InstagramSyncService.isLikelyBaselineReplacement(previous: 73, current: 1_500))
        XCTAssertTrue(InstagramSyncService.isLikelyBaselineReplacement(previous: 1_500, current: 73))
        XCTAssertFalse(InstagramSyncService.isLikelyBaselineReplacement(previous: 1_500, current: 1_510))
        XCTAssertFalse(InstagramSyncService.isLikelyBaselineReplacement(previous: 73, current: 80))
    }

    func testMonthlyRelationshipTimestampsAreDetectedAsDateLimited() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let records = [
            InstagramExportParser.RelationshipRecord(username: "a", date: now.addingTimeInterval(-28 * 86_400)),
            InstagramExportParser.RelationshipRecord(username: "b", date: now.addingTimeInterval(-2 * 86_400)),
        ]
        XCTAssertTrue(InstagramSyncService.isDateLimited(records: records, now: now))

        let fullHistory = [
            InstagramExportParser.RelationshipRecord(username: "old", date: now.addingTimeInterval(-700 * 86_400)),
            InstagramExportParser.RelationshipRecord(username: "new", date: now.addingTimeInterval(-2 * 86_400)),
        ]
        XCTAssertFalse(InstagramSyncService.isDateLimited(records: fullHistory, now: now))
    }

    /// Builds an export whose follower/following lists carry per-account
    /// timestamps, the way a monthly (date-limited) Meta export does.
    private func makeExport(
        followers: [(String, Date?)] = [],
        following: [(String, Date?)] = []
    ) -> InstagramExportParser.Export {
        var export = InstagramExportParser.Export()
        var lists = InstagramExportParser.FollowerLists()
        lists.followerRecords = followers.map { .init(username: $0.0, date: $0.1) }
        lists.followers = followers.map { $0.0 }
        lists.followerFiles = followers.isEmpty ? [] : ["followers_1.json"]
        lists.followingRecords = following.map { .init(username: $0.0, date: $0.1) }
        lists.following = following.map { $0.0 }
        lists.followingFiles = following.isEmpty ? [] : ["following.json"]
        export.followerLists = lists
        return export
    }

    func testPartialExportSurfacesNewFollowersEvenAfterEventsExist() throws {
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        // A prior monthly sync established a partial baseline of two accounts.
        let month1 = makeExport(followers: [
            ("ava", now.addingTimeInterval(-40 * 86_400)),
            ("ben", now.addingTimeInterval(-30 * 86_400)),
        ])
        _ = InstagramSyncService.shared.applyFollowerDiffForTesting(export: month1, context: context)

        // This month's export re-lists the same two (Meta windows overlap) plus
        // five genuinely new followers.
        let newcomers = ["cara", "dan", "eve", "finn", "gia"]
        let month2 = makeExport(followers:
            [("ava", now.addingTimeInterval(-40 * 86_400)), ("ben", now.addingTimeInterval(-30 * 86_400))]
            + newcomers.map { ($0, now.addingTimeInterval(-2 * 86_400)) }
        )
        let result = InstagramSyncService.shared.applyFollowerDiffForTesting(export: month2, context: context)

        XCTAssertTrue(result.followerDataIsDateLimited)
        XCTAssertEqual(result.newFollowers.sorted(), newcomers.sorted())
        // A partial export never infers unfollows.
        XCTAssertTrue(result.lostFollowers.isEmpty)
    }

    func testResyncingTheSamePartialExportReportsNoNewFollowers() throws {
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let baseline = makeExport(followers: [
            ("ava", now.addingTimeInterval(-40 * 86_400)),
            ("ben", now.addingTimeInterval(-30 * 86_400)),
        ])
        _ = InstagramSyncService.shared.applyFollowerDiffForTesting(export: baseline, context: context)

        let export = makeExport(followers:
            [("ava", now.addingTimeInterval(-40 * 86_400)), ("ben", now.addingTimeInterval(-30 * 86_400))]
            + [("newbie", now.addingTimeInterval(-1 * 86_400))]
        )
        let first = InstagramSyncService.shared.applyFollowerDiffForTesting(export: export, context: context)
        XCTAssertEqual(first.newFollowers, ["newbie"])

        // Re-running the identical export is idempotent: no phantom repeats.
        let second = InstagramSyncService.shared.applyFollowerDiffForTesting(export: export, context: context)
        XCTAssertTrue(second.newFollowers.isEmpty)
        XCTAssertTrue(second.lostFollowers.isEmpty)
    }

    func testPartialExportNeverReportsUnfollowsWhenAccountsAreMissing() throws {
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        // Baseline knows three accounts.
        let baseline = makeExport(followers: [
            ("ava", now.addingTimeInterval(-40 * 86_400)),
            ("ben", now.addingTimeInterval(-38 * 86_400)),
            ("cara", now.addingTimeInterval(-36 * 86_400)),
        ])
        _ = InstagramSyncService.shared.applyFollowerDiffForTesting(export: baseline, context: context)

        // Next partial export only mentions one of them plus a newcomer; the two
        // missing accounts must not be read as unfollows.
        let next = makeExport(followers: [
            ("ava", now.addingTimeInterval(-40 * 86_400)),
            ("dee", now.addingTimeInterval(-1 * 86_400)),
        ])
        let result = InstagramSyncService.shared.applyFollowerDiffForTesting(export: next, context: context)
        XCTAssertEqual(result.newFollowers, ["dee"])
        XCTAssertTrue(result.lostFollowers.isEmpty)

        let snapshots = try context.fetch(FetchDescriptor<FollowerSnapshot>(sortBy: [SortDescriptor(\.takenAt, order: .reverse)]))
        // The known set accumulated rather than shrinking to the latest slice.
        XCTAssertEqual(Set(snapshots.first?.followerUsernames ?? []), ["ava", "ben", "cara", "dee"])
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
