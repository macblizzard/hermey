import XCTest
@testable import HermesKit

/// The New Routine form's two pure decisions: the schedule string each mode produces, and the rule
/// that decides whether the Create button is allowed.
///
/// Both are pinned here rather than in a SwiftUI test because they are the parts a wrong answer
/// actually reaches the host with: a schedule the scheduler cannot parse, or a routine with nothing
/// to do.
final class RoutineDraftTests: XCTestCase {

    func testEachModeProducesTheScheduleShapeItMeans() {
        var schedule = RoutineSchedule()
        schedule.hour = 9
        schedule.minute = 0

        schedule.mode = .daily
        XCTAssertEqual(schedule.expression, "0 9 * * *")

        // Calendar counts Sunday as 1 and cron counts it as 0; Monday is 2 → cron 1.
        schedule.mode = .weekly
        schedule.weekday = 2
        XCTAssertEqual(schedule.expression, "0 9 * * 1")
        schedule.weekday = 1
        XCTAssertEqual(schedule.expression, "0 9 * * 0", "Sunday must wrap to cron's 0, not 7")

        schedule.mode = .monthly
        schedule.dayOfMonth = 15
        XCTAssertEqual(schedule.expression, "0 9 15 * *")

        schedule.mode = .repeat
        schedule.repeatCount = 15
        schedule.repeatUnit = .minutes
        XCTAssertEqual(schedule.expression, "every 15m")
        schedule.repeatUnit = .hours
        XCTAssertEqual(schedule.expression, "every 15h")

        schedule.mode = .custom
        schedule.custom = "  30 6 * * 1-5 "
        XCTAssertEqual(schedule.expression, "30 6 * * 1-5", "a custom expression is trimmed, not rewritten")
    }

    func testAOneShotIsAnAbsoluteTimestamp() {
        var schedule = RoutineSchedule()
        schedule.mode = .once
        var components = DateComponents()
        components.year = 2026
        components.month = 11
        components.day = 18
        components.hour = 9
        components.minute = 30
        schedule.onceAt = Calendar.current.date(from: components)!
        XCTAssertEqual(schedule.expression, "2026-11-18T09:30:00")
    }

    func testTheSummarySpeaksTheAppsLanguage() {
        var schedule = RoutineSchedule()
        schedule.hour = 9
        schedule.minute = 0
        schedule.mode = .daily
        XCTAssertEqual(schedule.summary, "Daily at 09:00")

        schedule.mode = .weekly
        schedule.weekday = 2
        XCTAssertEqual(schedule.summary, "Weekly on Monday at 09:00")

        schedule.mode = .monthly
        schedule.dayOfMonth = 1
        XCTAssertEqual(schedule.summary, "Monthly on the 1st at 09:00")
        schedule.dayOfMonth = 22
        XCTAssertEqual(schedule.summary, "Monthly on the 22nd at 09:00")

        schedule.mode = .repeat
        schedule.repeatCount = 1
        schedule.repeatUnit = .hours
        XCTAssertEqual(schedule.summary, "Every 1 hour", "one of them is not \"every 1 hours\"")

        schedule.mode = .custom
        schedule.custom = ""
        XCTAssertEqual(schedule.summary, "Custom schedule", "an empty custom field still needs a summary")
    }

    func testARoutineNeedsAPromptASkillOrAScript() {
        var draft = RoutineDraft()
        XCTAssertEqual(draft.problem, "This routine needs a prompt, a skill, or a script.")
        XCTAssertFalse(draft.isCreatable)

        draft.prompt = "   "
        XCTAssertNotNil(draft.problem, "whitespace is not a prompt")

        draft.prompt = "Check the weather and my calendar."
        XCTAssertNil(draft.problem)
        XCTAssertTrue(draft.isCreatable)

        // Any one of the three is enough, and each on its own.
        var scriptOnly = RoutineDraft()
        scriptOnly.script = "/root/.hermes/profiles/cody/scripts/audit.sh"
        XCTAssertNil(scriptOnly.problem)

        var skillOnly = RoutineDraft()
        skillOnly.skills = ["homelab-inventory-and-digest"]
        XCTAssertNil(skillOnly.problem)

        var skillBlank = RoutineDraft()
        skillBlank.skills = ["  ", ""]
        XCTAssertNotNil(skillBlank.problem, "blank skill names are not a skill")
    }

    func testAnEmptyScheduleIsRefusedBeforeTheHostSeesIt() {
        var draft = RoutineDraft()
        draft.prompt = "Do the thing."
        draft.schedule.mode = .custom
        draft.schedule.custom = "   "
        XCTAssertEqual(draft.problem, "Pick when this routine should run.")
    }

    func testThePayloadCarriesOnlyWhatWasFilledIn() {
        var draft = RoutineDraft()
        draft.schedule.mode = .daily
        draft.schedule.hour = 9
        draft.schedule.minute = 0
        draft.name = "  Morning summary "
        draft.prompt = " Check the weather. "
        draft.skills = [" skill-a ", "", "skill-b"]
        draft.deliver = "local"

        let payload = draft.payload()
        XCTAssertEqual(payload["schedule"] as? String, "0 9 * * *")
        XCTAssertEqual(payload["name"] as? String, "Morning summary")
        XCTAssertEqual(payload["prompt"] as? String, "Check the weather.")
        XCTAssertEqual(payload["skills"] as? [String], ["skill-a", "skill-b"])
        XCTAssertEqual(payload["deliver"] as? String, "local")
        XCTAssertNil(payload["script"], "an empty script must not be sent as \"\"")

        var scriptOnly = RoutineDraft()
        scriptOnly.script = "/tmp/x.sh"
        let scriptPayload = scriptOnly.payload()
        XCTAssertEqual(scriptPayload["script"] as? String, "/tmp/x.sh")
        XCTAssertNil(scriptPayload["prompt"])
        XCTAssertNil(scriptPayload["name"], "the name is optional and omitted when empty")
    }

    func testTheCreateResponseIsOneRow() {
        let json = """
        {"routine": {"id": "abc123", "name": "Morning summary", "schedule": "0 9 * * *",
                     "next_run_at": "2026-11-18T08:00:00Z", "paused": false, "completed": false}}
        """.data(using: .utf8)!
        let routine = BotRoutine.decodeOne(json)
        XCTAssertEqual(routine?.id, "abc123")
        XCTAssertEqual(routine?.name, "Morning summary")
        XCTAssertEqual(routine?.schedule, "0 9 * * *")
        XCTAssertNil(BotRoutine.decodeOne(Data("{}".utf8)))
    }
}
