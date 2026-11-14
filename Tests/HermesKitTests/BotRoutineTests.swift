import XCTest
@testable import HermesKit

/// The routines sheet draws four lines per row from one wire shape, and every one of them has to
/// survive a host that omits a field. The two interesting decisions are also here: a finished
/// one-shot is not a paused one, and "off" has two spellings on the host.
final class BotRoutineTests: XCTestCase {
    private func rows(_ json: String) -> [BotRoutine] {
        BotRoutine.decodeList(Data(json.utf8))
    }

    private func routine(_ json: String) -> BotRoutine {
        rows("{\"routines\": [\(json)]}")[0]
    }

    func testItReadsTheRowAListDraws() {
        let row = routine("""
        {"id": "fbc2fb0f324d", "name": "nightly-audit", "schedule": "every day at 3am",
         "next_run_at": "2026-11-16T03:00:00+01:00", "last_run_at": "2026-11-15T03:21:37+01:00",
         "last_status": "ok", "last_error": null, "paused": false, "completed": false}
        """)

        XCTAssertEqual(row.id, "fbc2fb0f324d")
        XCTAssertEqual(row.name, "nightly-audit")
        XCTAssertEqual(row.schedule, "every day at 3am")
        XCTAssertEqual(row.lastStatus, "ok")
        XCTAssertFalse(row.paused)
        XCTAssertFalse(row.completed)
        XCTAssertTrue(row.canToggle)
    }

    func testARowWithoutANameFallsBackToItsId() {
        // A job created from the CLI can have no name; a blank first line reads as a missing row.
        XCTAssertEqual(routine("{\"id\": \"abc123\", \"schedule\": \"hourly\"}").name, "abc123")
        XCTAssertEqual(routine("{\"id\": \"abc123\", \"name\": \"\"}").name, "abc123")
    }

    func testARowWithoutAnIdIsDropped() {
        // `id` is the only field a list cannot work without — it is the switch's key.
        XCTAssertTrue(rows("{\"routines\": [{\"name\": \"nameless\"}]}").isEmpty)
        XCTAssertTrue(rows("{\"routines\": [{\"id\": \"\"}]}").isEmpty)
    }

    func testAMissingListIsNoRowsRatherThanACrash() {
        XCTAssertTrue(rows("{}").isEmpty)
        XCTAssertTrue(rows("not json").isEmpty)
    }

    func testOffAndFinishedAreDifferentStates() {
        let paused = routine("{\"id\": \"a\", \"paused\": true}")
        let completed = routine("{\"id\": \"b\", \"completed\": true}")

        XCTAssertEqual(paused.timingText(), "Paused")
        XCTAssertEqual(completed.timingText(), "Finished")
        XCTAssertTrue(paused.canToggle, "a paused routine is exactly the one you resume")
        XCTAssertFalse(completed.canToggle, "re-arming a finished one-shot is a different decision")
    }

    func testTheScheduleIsTheHostsOwnWords() {
        // Never re-derive "every day at 3am" from a cron expression here: the host already did it,
        // and two derivations disagree the day one of them learns about a new form.
        let row = routine("{\"id\": \"a\", \"schedule\": \"every monday 9am\"}")
        XCTAssertEqual(row.timingText(), "every monday 9am", "no next run yet: the schedule stands")
    }

    func testTheNextRunReadsAsTextNotAsAStamp() {
        let row = routine("{\"id\": \"a\", \"schedule\": \"daily\", "
                          + "\"next_run_at\": \"2026-11-16T03:00:00+01:00\"}")
        let text = row.timingText(now: Date(timeIntervalSince1970: 1_794_000_000))
        XCTAssertTrue(text.hasPrefix("Next "), text)
        XCTAssertFalse(text.contains("2026"), "an ISO stamp is not something to show a person")
    }

    func testAFailedRunSaysWhy() {
        let failed = routine("""
        {"id": "a", "last_run_at": "2026-11-15T03:21:37+01:00", "last_status": "error",
         "last_error": "dashboard unreachable"}
        """)
        let text = failed.lastRunText(now: Date(timeIntervalSince1970: 1_794_000_000))
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.hasPrefix("Failed ") == true, text ?? "")
        XCTAssertTrue(text?.contains("dashboard unreachable") == true,
                      "a row that only said 'failed' sends the owner to the desktop to find out why")
    }

    func testASuccessfulRunIsJustTheTime() {
        let ok = routine("""
        {"id": "a", "last_run_at": "2026-11-15T03:21:37+01:00", "last_status": "ok"}
        """)
        XCTAssertEqual(ok.lastRunText(now: Date(timeIntervalSince1970: 1_794_000_000))?.hasPrefix("Ran "),
                       true)
    }

    func testANeverRunRoutineHasNoLastRunLine() {
        XCTAssertNil(routine("{\"id\": \"a\"}").lastRunText())
    }

    func testStampsWithAndWithoutFractionalSecondsBothParse() {
        // The host writes `.123456` on some fields and not on others; a row must not go blank
        // because of a trailing decimal.
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        let plain = routine("{\"id\": \"a\", \"last_run_at\": \"2026-11-15T03:21:37+01:00\"}")
        let fractional = routine("{\"id\": \"a\", \"last_run_at\": \"2026-11-15T03:21:37.919813+01:00\"}")
        XCTAssertNotNil(plain.lastRunText(now: now))
        XCTAssertNotNil(fractional.lastRunText(now: now))
    }

    func testTheRelativeTextIsShortAndPointedBothWays() {
        // Fixed clock, so this is a test of the rule and not of the day it ran.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func text(seconds: TimeInterval) -> String {
            BotRoutine.relativeText(from: now.addingTimeInterval(seconds), now: now)
        }
        XCTAssertEqual(text(seconds: -30), "now")
        XCTAssertEqual(text(seconds: 300), "in 5 m")
        XCTAssertEqual(text(seconds: -7_200), "2 h ago")
        XCTAssertEqual(text(seconds: 3 * 86_400), "in 3 d")
        XCTAssertEqual(text(seconds: -20 * 86_400), "2 w ago")
    }

    func testGarbageStampsAreNoLastRunRatherThanNaN() {
        XCTAssertNil(routine("{\"id\": \"a\", \"last_run_at\": \"yesterday\"}").lastRunText())
    }
}
