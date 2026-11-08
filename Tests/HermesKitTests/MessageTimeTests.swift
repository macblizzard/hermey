import Foundation
import XCTest
@testable import HermesKit

/// A clock on a message is only useful if it says the right thing about *when*: today's rows keep
/// the time alone, yesterday names itself, and anything older carries a date.
final class MessageTimeTests: XCTestCase {

    /// Noon UTC on a fixed day, so the assertions do not depend on when the suite runs.
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    func testTodayIsTheClockAlone() {
        let fourPM = calendar.date(bySettingHour: 16, minute: 5, second: 0, of: now)!
        XCTAssertEqual(MessageTime.label(for: fourPM, now: now, calendar: calendar), "16:05")
    }

    func testYesterdaySaysSo() {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let time = calendar.date(bySettingHour: 9, minute: 30, second: 0, of: yesterday)!
        XCTAssertEqual(MessageTime.label(for: time, now: now, calendar: calendar), "Yesterday, 09:30")
    }

    func testOlderRowsCarryTheirDate() {
        let older = calendar.date(byAdding: .day, value: -5, to: now)!
        let time = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: older)!
        let label = MessageTime.label(for: time, now: now, calendar: calendar)
        XCTAssertTrue(label.contains("14:59") == false, "23:59 must not be re-formatted as 14:59")
        XCTAssertTrue(label.hasSuffix("23:59"), label)
        // "d MMM, HH:mm" — a day number, a month name, then the clock.
        XCTAssertTrue(label.split(separator: ",").count == 2, label)
    }

    func testMidnightIsNotTomorrow() {
        let midnight = calendar.startOfDay(for: now)
        XCTAssertEqual(MessageTime.label(for: midnight, now: now, calendar: calendar), "00:00")
    }
}
