import XCTest
@testable import SocialClimber

/// Tests quiet-hours math and its time-zone correctness.
final class QuietHoursTests: XCTestCase {

    func testSameDayWindow() {
        // Quiet 1:00–6:00.
        XCTAssertTrue(QuietHours.isQuiet(hour: 3, startHour: 1, endHour: 6))
        XCTAssertFalse(QuietHours.isQuiet(hour: 7, startHour: 1, endHour: 6))
        XCTAssertFalse(QuietHours.isQuiet(hour: 0, startHour: 1, endHour: 6))
    }

    func testOvernightWindow() {
        // Quiet 22:00–8:00.
        XCTAssertTrue(QuietHours.isQuiet(hour: 23, startHour: 22, endHour: 8))
        XCTAssertTrue(QuietHours.isQuiet(hour: 2, startHour: 22, endHour: 8))
        XCTAssertFalse(QuietHours.isQuiet(hour: 9, startHour: 22, endHour: 8))
        XCTAssertFalse(QuietHours.isQuiet(hour: 21, startHour: 22, endHour: 8))
    }

    func testEqualStartEndMeansNeverQuiet() {
        for h in 0..<24 {
            XCTAssertFalse(QuietHours.isQuiet(hour: h, startHour: 9, endHour: 9))
        }
    }

    private func calendar(tz: String) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz)!
        return cal
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, tz: String) -> Date {
        var cal = calendar(tz: tz)
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d; comps.hour = h
        return cal.date(from: comps)!
    }

    func testNonQuietTimeUnchanged() {
        let cal = calendar(tz: "America/New_York")
        let d = date(2026, 7, 12, 14, tz: "America/New_York") // 2 PM
        let adjusted = QuietHours.adjustedFireDate(d, startHour: 22, endHour: 8, calendar: cal)
        XCTAssertEqual(adjusted, d)
    }

    func testQuietTimePushedToWindowEnd() {
        let cal = calendar(tz: "America/New_York")
        let d = date(2026, 7, 12, 2, tz: "America/New_York") // 2 AM, inside 22–8
        let adjusted = QuietHours.adjustedFireDate(d, startHour: 22, endHour: 8, calendar: cal)
        XCTAssertEqual(cal.component(.hour, from: adjusted), 8)
        XCTAssertEqual(cal.component(.day, from: adjusted), 12) // same morning
    }

    func testLateNightPushedToNextMorning() {
        let cal = calendar(tz: "America/New_York")
        let d = date(2026, 7, 12, 23, tz: "America/New_York") // 11 PM
        let adjusted = QuietHours.adjustedFireDate(d, startHour: 22, endHour: 8, calendar: cal)
        XCTAssertEqual(cal.component(.hour, from: adjusted), 8)
        XCTAssertEqual(cal.component(.day, from: adjusted), 13) // next day
    }

    func testTimeZoneChangesResult() {
        // The same absolute instant reads as a different local hour in two
        // zones, so quiet-hours adjustment must follow the calendar's zone.
        let instant = date(2026, 7, 12, 2, tz: "America/New_York") // 2 AM in NY
        let tokyo = calendar(tz: "Asia/Tokyo") // same instant is 3 PM in Tokyo
        XCTAssertEqual(tokyo.component(.hour, from: instant), 15)
        let adjusted = QuietHours.adjustedFireDate(instant, startHour: 22, endHour: 8, calendar: tokyo)
        // 3 PM Tokyo is not quiet → unchanged.
        XCTAssertEqual(adjusted, instant)
    }
}
