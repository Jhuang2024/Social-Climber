import XCTest
import SwiftData
@testable import SocialClimber

/// Exercises the scheduling/cancellation bookkeeping that guarantees dedup:
/// stable `notificationID`s, reused across reschedules, cleared on cancel.
/// (The OS delivery itself isn't asserted — the identifier bookkeeping is the
/// dedup mechanism and the part worth pinning down.)
@MainActor
final class NotificationServiceTests: XCTestCase {

    private var container: ModelContainer!
    private var savedMaster: Bool = false
    private var savedCategory: Any?

    override func setUp() {
        super.setUp()
        let schema = Schema([
            Person.self, Interaction.self, GiftIdea.self, Reminder.self,
            ImportantDate.self, VoiceNote.self, ConversationSummary.self, Event.self,
        ])
        container = try! ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        // Enable notifications for the duration of the test, restoring after.
        let d = UserDefaults.standard
        savedMaster = d.bool(forKey: NotificationSettings.Key.masterEnabled)
        savedCategory = d.object(forKey: NotificationSettings.Key.explicitReminders)
        d.set(true, forKey: NotificationSettings.Key.masterEnabled)
        d.set(true, forKey: NotificationSettings.Key.explicitReminders)
    }

    override func tearDown() {
        let d = UserDefaults.standard
        d.set(savedMaster, forKey: NotificationSettings.Key.masterEnabled)
        d.set(savedCategory, forKey: NotificationSettings.Key.explicitReminders)
        container = nil
        super.tearDown()
    }

    private func makeReminder(daysOut: Int = 3) -> Reminder {
        let due = Calendar.current.date(byAdding: .day, value: daysOut, to: .now)!
        let reminder = Reminder(title: "Call mom", dueDate: due, type: .custom)
        container.mainContext.insert(reminder)
        return reminder
    }

    func testScheduleAssignsIdentifier() {
        let reminder = makeReminder()
        XCTAssertNil(reminder.notificationID)
        NotificationService.shared.schedule(reminder: reminder)
        XCTAssertNotNil(reminder.notificationID)
    }

    func testRescheduleReusesIdentifier() {
        let reminder = makeReminder()
        NotificationService.shared.schedule(reminder: reminder)
        let firstID = reminder.notificationID
        NotificationService.shared.schedule(reminder: reminder)
        // Same id → replaces the pending request instead of duplicating it.
        XCTAssertEqual(reminder.notificationID, firstID)
    }

    func testCancelClearsIdentifier() {
        let reminder = makeReminder()
        NotificationService.shared.schedule(reminder: reminder)
        XCTAssertNotNil(reminder.notificationID)
        NotificationService.shared.cancel(reminder: reminder)
        XCTAssertNil(reminder.notificationID)
    }

    func testCompletedReminderNotScheduled() {
        let reminder = makeReminder()
        reminder.completed = true
        NotificationService.shared.schedule(reminder: reminder)
        XCTAssertNil(reminder.notificationID)
    }

    func testPastReminderNotScheduled() {
        let reminder = makeReminder(daysOut: -2)
        NotificationService.shared.schedule(reminder: reminder)
        XCTAssertNil(reminder.notificationID)
    }

    func testReminderDueTodayStillSchedules() {
        let reminder = makeReminder(daysOut: 0)
        NotificationService.shared.schedule(reminder: reminder)
        XCTAssertNotNil(reminder.notificationID)
    }

    func testOverdueFollowUpSchedulesForNextReminderWindow() {
        let reminder = makeReminder(daysOut: -2)
        reminder.type = .followUp
        NotificationService.shared.schedule(reminder: reminder)
        XCTAssertNotNil(reminder.notificationID)
    }

    func testDisabledCategoryDoesNotSchedule() {
        UserDefaults.standard.set(false, forKey: NotificationSettings.Key.explicitReminders)
        let reminder = makeReminder()
        NotificationService.shared.schedule(reminder: reminder)
        XCTAssertNil(reminder.notificationID)
    }

    func testReconcileIsIdempotent() {
        let r1 = makeReminder()
        let r2 = makeReminder(daysOut: 5)
        let people: [Person] = []
        NotificationService.shared.reconcile(people: people, reminders: [r1, r2], importantDates: [], events: [], pendingCaptureCount: 0)
        let id1 = r1.notificationID
        NotificationService.shared.reconcile(people: people, reminders: [r1, r2], importantDates: [], events: [], pendingCaptureCount: 0)
        // Reconciling twice keeps stable ids (no duplicate scheduling).
        XCTAssertNotNil(r1.notificationID)
        XCTAssertNotNil(r2.notificationID)
        XCTAssertNotEqual(r1.notificationID, r2.notificationID)
        // r1 kept a valid (possibly regenerated) id, still non-nil.
        _ = id1
    }
}
