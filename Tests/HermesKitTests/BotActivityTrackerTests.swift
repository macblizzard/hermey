import XCTest
@testable import HermesKit

// The tracker is the only thing in the app that knows what a bot's face should be doing, so these
// are the rules a surface relies on. Each test drives the *events* — not the setters alone — because
// the bugs worth guarding against are the ones where an event is attributed to the wrong bot, or
// where a finished tool leaves the face stuck on the pose it already used.
final class BotActivityTrackerTests: XCTestCase {

    private let bot = "research"

    // MARK: - Nothing known

    func testABotNobodyHasHeardFromIsIdle() {
        let tracker = BotActivityTracker()
        XCTAssertEqual(tracker.activity(for: bot), .idle)
        XCTAssertEqual(tracker.state(for: bot), BotActivityTracker.State())
        XCTAssertFalse(tracker.isActive(bot))
    }

    // MARK: - Composing and thinking

    func testComposingIsWriting() {
        var tracker = BotActivityTracker()
        tracker.setComposing(true, for: bot)
        XCTAssertEqual(tracker.activity(for: bot), .writing)
    }

    func testThinkingIsThinking() {
        var tracker = BotActivityTracker()
        tracker.thinking(botID: bot)
        XCTAssertEqual(tracker.activity(for: bot), .thinking)
    }

    func testComposingOutranksThinking() {
        // The model stopped deliberating and started writing; `from` checks composing first.
        var tracker = BotActivityTracker()
        tracker.thinking(botID: bot)
        tracker.setComposing(true, for: bot)
        XCTAssertEqual(tracker.activity(for: bot), .writing)
    }

    // MARK: - Tools

    func testEveryToolFamilyPicksItsOwnPose() {
        for (tool, expected) in [("read_file", BotAvatarActivity.reading),
                                 ("web_fetch", .reading),
                                 ("write_file", .writing),
                                 ("computer_observe", .computer),
                                 ("shell", .computer),
                                 ("terminal", .working),
                                 ("anything-else", .working)] {
            var tracker = BotActivityTracker()
            tracker.toolStarted(botID: bot, name: tool, callID: "c1")
            XCTAssertEqual(tracker.activity(for: bot), expected, tool)
        }
    }

    func testAToolBeatsComposing() {
        var tracker = BotActivityTracker()
        tracker.setComposing(true, for: bot)
        tracker.toolStarted(botID: bot, name: "read_file", callID: "c1")
        XCTAssertEqual(tracker.activity(for: bot), .reading)
        XCTAssertFalse(tracker.state(for: bot).composing)
    }

    func testComputerOutranksReadingWhenBothAreOpen() {
        // The reference checks the computer set first, so a shell that also read a file is a bot at
        // a machine. Ordering this wrongly is the difference between `computer` and `reading`.
        var tracker = BotActivityTracker()
        tracker.toolStarted(botID: bot, name: "read_file", callID: "c1")
        tracker.toolStarted(botID: bot, name: "shell", callID: "c2")
        XCTAssertEqual(tracker.activity(for: bot), .computer)
        tracker.toolCompleted(botID: bot, name: "shell", callID: "c2", ok: true)
        XCTAssertEqual(tracker.activity(for: bot), .reading)
    }

    func testTheLastToolCalledIsTheOneDrawn() {
        var tracker = BotActivityTracker()
        tracker.toolStarted(botID: bot, name: "read_file", callID: "c1")
        tracker.toolStarted(botID: bot, name: "write_file", callID: "c2")
        XCTAssertEqual(tracker.activity(for: bot), .writing,
                       "the most recent call in flight decides the pose")
    }

    func testAFinishedToolFallsBackToWorking() {
        // No reasoning was seen, so the honest face after the tool returns is plain work.
        var tracker = BotActivityTracker()
        tracker.toolStarted(botID: bot, name: "read_file", callID: "c1")
        tracker.toolCompleted(botID: bot, name: "read_file", callID: "c1", ok: true)
        XCTAssertEqual(tracker.activity(for: bot), .working)
        XCTAssertTrue(tracker.state(for: bot).openCalls.isEmpty)
    }

    func testAFinishedToolFallsBackToThinking() {
        // A run that was deliberating when it reached for a tool goes back to deliberating.
        var tracker = BotActivityTracker()
        tracker.thinking(botID: bot)
        tracker.toolStarted(botID: bot, name: "read_file", callID: "c1")
        XCTAssertEqual(tracker.activity(for: bot), .reading)
        tracker.toolCompleted(botID: bot, name: "read_file", callID: "c1", ok: true)
        XCTAssertEqual(tracker.activity(for: bot), .thinking)
    }

    func testAFailedToolIsNotAFailedRun() {
        // The reference's `error` is a failed run. A tool that failed is one the model works around,
        // so the face goes back to thinking instead of turning red over it.
        var tracker = BotActivityTracker()
        tracker.thinking(botID: bot)
        tracker.toolStarted(botID: bot, name: "shell", callID: "c1")
        tracker.toolCompleted(botID: bot, name: "shell", callID: "c1", ok: false)
        XCTAssertEqual(tracker.activity(for: bot), .thinking)
    }

    func testACompletionForAnUnseenStartStillClosesTheCall() {
        // A replay, or a tool that began before the socket reattached: the call must not stay open
        // forever and pin the face to a pose nothing is doing any more.
        var tracker = BotActivityTracker()
        tracker.toolStarted(botID: bot, name: "shell", callID: "c1")
        tracker.toolCompleted(botID: bot, name: "shell", callID: "a-different-id", ok: true)
        XCTAssertTrue(tracker.state(for: bot).openCalls.isEmpty)
        XCTAssertEqual(tracker.activity(for: bot), .working)
    }

    // MARK: - Lifecycle

    func testStreamingWithNoOtherSignalIsWorking() {
        var tracker = BotActivityTracker()
        tracker.setStreaming(true, for: bot)
        XCTAssertEqual(tracker.activity(for: bot), .working)
    }

    func testARequestIsWaitingAndOutranksATool() {
        var tracker = BotActivityTracker()
        tracker.toolStarted(botID: bot, name: "shell", callID: "c1")
        tracker.setWaitingOnUser(true, for: bot)
        XCTAssertEqual(tracker.activity(for: bot), .waiting)
        XCTAssertTrue(tracker.activity(for: bot).needsAttention)
        tracker.setWaitingOnUser(false, for: bot)
        XCTAssertEqual(tracker.activity(for: bot), .computer)
    }

    func testAFailureOutranksARequest() {
        var tracker = BotActivityTracker()
        tracker.setWaitingOnUser(true, for: bot)
        tracker.setStatus("failed", for: bot)
        XCTAssertEqual(tracker.activity(for: bot), .error)
        XCTAssertFalse(tracker.activity(for: bot).isAnimated, "error rests")
    }

    func testBackgroundWorkIsIdleOverEverything() {
        var tracker = BotActivityTracker()
        tracker.toolStarted(botID: bot, name: "shell", callID: "c1")
        tracker.setStreaming(true, for: bot)
        tracker.setBackground(true, for: bot)
        XCTAssertEqual(tracker.activity(for: bot), .idle)
    }

    func testASettledTurnIsIdleAgain() {
        var tracker = BotActivityTracker()
        tracker.toolStarted(botID: bot, name: "read_file", callID: "c1")
        tracker.setComposing(true, for: bot)
        tracker.settled(botID: bot)
        XCTAssertEqual(tracker.activity(for: bot), .idle)
        let state = tracker.state(for: bot)
        XCTAssertTrue(state.openCalls.isEmpty)
        XCTAssertFalse(state.composing)
        XCTAssertFalse(state.thinking)
        XCTAssertFalse(state.waitingOnUser)
    }

    func testStoppingTheStreamClearsTheTurn() {
        var tracker = BotActivityTracker()
        tracker.toolStarted(botID: bot, name: "read_file", callID: "c1")
        tracker.setStreaming(true, for: bot)
        tracker.setStreaming(false, for: bot)
        XCTAssertEqual(tracker.activity(for: bot), .idle)
    }

    // MARK: - Events, and two bots

    func testEventsAreReducedTheWayTheClientReceivesThem() {
        var tracker = BotActivityTracker()
        tracker.apply(.messageDelta(session: "s1", text: "on it"), bot: bot)
        XCTAssertEqual(tracker.activity(for: bot), .writing)

        tracker.apply(.toolStart(session: "s1", name: "read_file", callID: "c1", input: "{}"), bot: bot)
        XCTAssertEqual(tracker.activity(for: bot), .reading)

        tracker.apply(.toolProgress(session: "s1", callID: "c1", text: "half"), bot: bot)
        XCTAssertEqual(tracker.activity(for: bot), .reading)

        tracker.apply(.toolComplete(session: "s1", name: "read_file", callID: "c1",
                                    output: "done", ok: true, durationMS: 12), bot: bot)
        XCTAssertEqual(tracker.activity(for: bot), .working)

        tracker.apply(.thinkingDelta(session: "s1", text: "hmm"), bot: bot)
        XCTAssertEqual(tracker.activity(for: bot), .thinking)

        tracker.apply(.messageComplete(session: "s1", text: "here"), bot: bot)
        XCTAssertEqual(tracker.activity(for: bot), .idle)
    }

    func testAnEmptyThinkingHeartbeatDoesNotMakeTheFaceThink() {
        var tracker = BotActivityTracker()
        tracker.apply(.thinkingDelta(session: "s1", text: ""), bot: bot)
        XCTAssertEqual(tracker.activity(for: bot), .idle)
    }

    func testAnEventWithNoBotChangesNothing() {
        var tracker = BotActivityTracker()
        tracker.apply(.toolStart(session: "s1", name: "shell", callID: "c1", input: "{}"), bot: nil)
        XCTAssertEqual(tracker.activity(for: bot), .idle)
    }

    func testTwoBotsKeepTwoFaces() {
        var tracker = BotActivityTracker()
        tracker.toolStarted(botID: "research", name: "read_file", callID: "a")
        tracker.toolStarted(botID: "ops", name: "shell", callID: "b")
        XCTAssertEqual(tracker.activity(for: "research"), .reading)
        XCTAssertEqual(tracker.activity(for: "ops"), .computer)
        tracker.settled(botID: "ops")
        XCTAssertEqual(tracker.activity(for: "research"), .reading)
        XCTAssertEqual(tracker.activity(for: "ops"), .idle)
    }

    func testResettingForgetsOnlyThatBot() {
        var tracker = BotActivityTracker()
        tracker.toolStarted(botID: "research", name: "read_file", callID: "a")
        tracker.toolStarted(botID: "ops", name: "shell", callID: "b")
        tracker.reset("research")
        XCTAssertEqual(tracker.activity(for: "research"), .idle)
        XCTAssertEqual(tracker.activity(for: "ops"), .computer)
        tracker.resetAll()
        XCTAssertEqual(tracker.activity(for: "ops"), .idle)
    }

    // MARK: - The precedence is not re-implemented here

    func testTheTrackerAgreesWithTheActivityRulesForEveryStatus() {
        // One source of truth: whatever `from` says about a status, the tracker says too — the
        // tracker only supplies the inputs.
        for status in ["queued", "leased", "running", "waiting_input", "waiting_takeover",
                       "completed", "failed", "cancelled", nil] {
            var tracker = BotActivityTracker()
            tracker.setStatus(status, for: bot)
            XCTAssertEqual(tracker.activity(for: bot),
                           BotAvatarActivity.from(status: status),
                           "status \(status ?? "nil")")
        }
    }
}
