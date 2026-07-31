import XCTest
import SwiftData
@testable import SocialClimber

/// Guards the bug this scoring rewrite exists to fix: the Social Health
/// score reporting the identical number for weeks because every term
/// feeding it was a step function or a saturated cap.
@MainActor
final class SocialHealthScoreTests: XCTestCase {
    private var container: ModelContainer!

    override func setUp() {
        super.setUp()
        let schema = Schema([
            Person.self, Interaction.self, GiftIdea.self, Reminder.self,
            ImportantDate.self, VoiceNote.self, ConversationSummary.self,
            Event.self, CapturedMemory.self, MemoryFact.self,
            LifeEvent.self,
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

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func daysAgo(_ n: Double) -> Date {
        now.addingTimeInterval(-n * 86_400)
    }

    /// Three people with a realistic run of recent conversations.
    @discardableResult
    private func seedActivity() -> (people: [Person], interactions: [Interaction]) {
        let context = container.mainContext
        var people: [Person] = []
        var interactions: [Interaction] = []
        for (index, name) in ["Alex Rivera", "Maya Chen", "Dev Patel"].enumerated() {
            let person = Person(name: name)
            person.createdAt = daysAgo(400)
            context.insert(person)
            people.append(person)
            // Irregular spacing, the way real conversations land.
            for offset in [2.0, 6.5, 13.0, 21.5, 34.0, 48.0, 63.0] {
                let interaction = Interaction(
                    type: .message,
                    date: daysAgo(offset + Double(index) * 1.5),
                    quality: index == 2 ? 4 : 3
                )
                interaction.people = [person]
                context.insert(interaction)
                interactions.append(interaction)
            }
            person.recomputeContactDates()
        }
        return (people, interactions)
    }

    /// The reported symptom: replaying the score across the last month used
    /// to produce one flat line. It has to actually move.
    func testScoreChangesAcrossTheLastMonth() {
        let seeded = seedActivity()
        let totals = stride(from: 0, through: 29, by: 1).map { offset in
            SocialHealthReport.compute(
                people: seeded.people,
                interactions: seeded.interactions,
                now: daysAgo(Double(offset))
            ).total
        }
        XCTAssertGreaterThanOrEqual(
            Set(totals).count, 5,
            "Social Health was flat across 30 days: \(totals)"
        )
    }

    /// Logging a conversation today has to register today, not on whatever
    /// day some bucket boundary happens to fall.
    func testLoggingAnInteractionMovesTheScoreImmediately() {
        let seeded = seedActivity()
        let before = SocialHealthReport.compute(
            people: seeded.people,
            interactions: seeded.interactions,
            now: now
        ).total

        let person = Person(name: "Jordan Lee")
        person.createdAt = daysAgo(400)
        container.mainContext.insert(person)
        let fresh = Interaction(type: .inPerson, date: now, quality: 5)
        fresh.people = [person]
        container.mainContext.insert(fresh)
        person.recomputeContactDates()

        let after = SocialHealthReport.compute(
            people: seeded.people + [person],
            interactions: seeded.interactions + [fresh],
            now: now
        ).total
        XCTAssertNotEqual(before, after)
    }

    /// The per-person score has to respond to a day passing too, since the
    /// aggregate is built from it.
    func testRelationshipScoreDriftsDayToDay() {
        let seeded = seedActivity()
        let person = try! XCTUnwrap(seeded.people.first)
        let totals = stride(from: 0, through: 20, by: 1).map { offset in
            RelationshipScore.rawTotal(for: person, now: daysAgo(Double(offset)))
        }
        XCTAssertGreaterThanOrEqual(Set(totals.map { Int($0 * 100) }).count, 10)
    }

    /// The transparency contract: the itemized factors the UI lists must add
    /// up to exactly the number on the ring, even though the score is
    /// computed in fractions.
    func testFactorsSumToTheReportedTotal() {
        let seeded = seedActivity()
        for offset in [0.0, 5.0, 12.0, 25.0] {
            let report = SocialHealthReport.compute(
                people: seeded.people,
                interactions: seeded.interactions,
                now: daysAgo(offset)
            )
            XCTAssertEqual(report.factors.reduce(0) { $0 + $1.points }, report.total)
        }
        for person in seeded.people {
            let score = RelationshipScore.compute(for: person, now: now)
            XCTAssertEqual(score.factors.reduce(0) { $0 + $1.points }, score.total)
        }
    }

    /// A person (or interaction) that didn't exist yet must not affect a
    /// historical point on the trend chart.
    func testHistoricalPointsIgnoreLaterData() {
        let seeded = seedActivity()
        let baseline = SocialHealthReport.compute(
            people: seeded.people,
            interactions: seeded.interactions,
            now: daysAgo(10)
        )

        let newcomer = Person(name: "Priya Nair")
        newcomer.createdAt = daysAgo(3)
        container.mainContext.insert(newcomer)
        let recent = Interaction(type: .call, date: daysAgo(1), quality: 5)
        recent.people = [newcomer]
        container.mainContext.insert(recent)
        newcomer.recomputeContactDates()

        let replayed = SocialHealthReport.compute(
            people: seeded.people + [newcomer],
            interactions: seeded.interactions + [recent],
            now: daysAgo(10)
        )
        XCTAssertEqual(baseline.total, replayed.total)
    }
}
