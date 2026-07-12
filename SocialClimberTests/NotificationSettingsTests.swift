import XCTest
@testable import SocialClimber

/// Tests category gating (the mechanism that prevents unwanted notifications),
/// category metadata, and dedup-relevant identifier stability.
final class NotificationSettingsTests: XCTestCase {

    private var suite: UserDefaults!
    private let suiteName = "NotificationSettingsTests"

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: suiteName)
        suite.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        suite = nil
        super.tearDown()
    }

    func testMasterOffDisablesEverything() {
        suite.set(false, forKey: NotificationSettings.Key.masterEnabled)
        suite.set(true, forKey: NotificationSettings.Key.events)
        let settings = NotificationSettings(defaults: suite)
        XCTAssertFalse(settings.isEnabled(.event))
        XCTAssertFalse(settings.isEnabled(.birthday))
    }

    func testCategoryToggleGates() {
        suite.set(true, forKey: NotificationSettings.Key.masterEnabled)
        suite.set(false, forKey: NotificationSettings.Key.events)
        suite.set(true, forKey: NotificationSettings.Key.birthdays)
        let settings = NotificationSettings(defaults: suite)
        XCTAssertFalse(settings.isEnabled(.event))
        XCTAssertTrue(settings.isEnabled(.birthday))
    }

    func testFollowUpAndOverdueShareOneKey() {
        suite.set(true, forKey: NotificationSettings.Key.masterEnabled)
        suite.set(false, forKey: NotificationSettings.Key.followUps)
        let settings = NotificationSettings(defaults: suite)
        XCTAssertFalse(settings.isEnabled(.followUp))
        XCTAssertFalse(settings.isEnabled(.overdueFollowUp))
    }

    func testUnsetCategoryDefaultsOn() {
        suite.set(true, forKey: NotificationSettings.Key.masterEnabled)
        // No explicit value for relationshipMaintenance.
        let settings = NotificationSettings(defaults: suite)
        XCTAssertTrue(settings.isEnabled(.relationshipMaintenance))
    }

    func testEveryCategoryHasIdentifierAndText() {
        var identifiers = Set<String>()
        for category in NotificationCategory.allCases {
            XCTAssertTrue(category.identifier.hasPrefix("sc."))
            XCTAssertFalse(category.genericBody.isEmpty)
            XCTAssertFalse(category.genericTitle.isEmpty)
            // Identifiers must be unique so dedup/action-routing is stable.
            XCTAssertTrue(identifiers.insert(category.identifier).inserted, "duplicate id \(category.identifier)")
        }
    }

    func testGenericTextIsPrivacySafe() {
        // Privacy-safe bodies must not contain placeholders for names.
        for category in NotificationCategory.allCases {
            XCTAssertFalse(category.genericBody.contains("%@"))
        }
    }

    func testQuietHourDefaults() {
        let settings = NotificationSettings(defaults: suite)
        // With nothing registered in this isolated suite, reads fall back to
        // the documented defaults rather than zero.
        XCTAssertEqual(settings.quietHoursStartHour, 22)
        XCTAssertEqual(settings.quietHoursEndHour, 8)
        XCTAssertEqual(settings.defaultSnoozeMinutes, 60)
    }
}
