"""The bot-activity tracker: the app's one reducer from gateway events to a face.

`BotActivityTracker` is Swift and needs a toolchain to run, so this file pins the three things a
source review cannot keep straight on its own:

* **where the rules live.** The precedence is `BotAvatarActivity.from(...)`'s, and the tracker must
  pass it inputs rather than repeat the ladder — a second copy is how the roster and the reference
  drift apart;
* **the transitions.** A tool that finishes has to leave the in-flight set, or the face stays on the
  pose of a call that is already done;
* **the wiring.** One tracker, fed where events are already reduced, and one accessor per platform.

The behavioural half of the same contract is `Tests/HermesKitTests/BotActivityTrackerTests.swift`,
which drives the events and asserts the face after each one.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KIT = ROOT / "Sources" / "HermesKit"
TRACKER = (KIT / "BotActivityTracker.swift").read_text(encoding="utf-8")
ACTIVITY = (KIT / "BotAvatarActivity.swift").read_text(encoding="utf-8")
APP_MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")
WORKSPACE = (ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceStore.swift").read_text(encoding="utf-8")
SWIFT_TESTS = (ROOT / "Tests" / "HermesKitTests" / "BotActivityTrackerTests.swift").read_text(encoding="utf-8")


def body(symbol: str, source: str = TRACKER) -> str:
    """The opening brace's contents of `symbol`, by brace balance."""
    start = source.index(symbol)
    open_brace = source.index("{", start)
    depth = 0
    for index in range(open_brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[open_brace:index + 1]
    raise AssertionError(f"{symbol} is not closed")


class TheTrackerLivesOnTheWireSide(unittest.TestCase):
    def test_it_is_in_hermeskit_and_declares_a_bot_id(self) -> None:
        # The wire layer reduces, the design system draws. The tracker cannot live in `HermeyUI`
        # (that target depends on `HermesKit`) and it cannot be generic over an activity, because a
        # UI-side translation table is a second copy of the rules.
        self.assertTrue((KIT / "BotActivityTracker.swift").exists())
        self.assertFalse((ROOT / "Sources" / "HermeyUI" / "BotActivityTracker.swift").exists())
        self.assertIn("public typealias BotID = String", TRACKER)
        self.assertIn("public func activity(for botID: BotID) -> BotAvatarActivity", TRACKER)

    def test_the_activity_vocabulary_is_shared_not_forked(self) -> None:
        self.assertTrue((KIT / "BotAvatarActivity.swift").exists())
        self.assertFalse((ROOT / "Sources" / "HermeyUI" / "BotAvatarActivity.swift").exists())
        self.assertIn("public enum BotAvatarActivity", ACTIVITY)

    def test_it_is_pure(self) -> None:
        # No view, no socket: a test drives it with values and reads a value back. The one piece of
        # time it needs — how long `done` is held — arrives through the injected clock, never from a
        # `Date()` in the middle of a transition.
        for forbidden in ("import SwiftUI", "Date()", "TimelineView", "Task {", "await "):
            self.assertNotIn(forbidden, TRACKER, forbidden)
        self.assertIn("public struct BotActivityTracker: Sendable", TRACKER)
        self.assertIn("private let clock: @Sendable () -> Date", TRACKER)
        self.assertIn("public init(now: @escaping @Sendable () -> Date = { Date.now })", TRACKER)


class ThePrecedenceIsTheReferenceOnes(unittest.TestCase):
    def test_the_face_is_derived_by_the_activity_rules(self) -> None:
        block = body("public func activity(for botID: BotID)")
        self.assertIn("BotAvatarActivity.from(", block)
        self.assertIn("toolNames: state.openCalls.map(\\.name)", block)
        self.assertIn("composing: state.composing", block)
        self.assertIn("thinking: state.thinking", block)
        self.assertIn("background: state.background", block)

    def test_the_tracker_does_not_repeat_the_ladder(self) -> None:
        # The one place a status may be rewritten is `status(of:)`, which folds a paused run into the
        # waiting vocabulary. Any other copy of "failed first, then waiting, then working" is a bug.
        block = body("public func activity(for botID: BotID)")
        for needle in ("if background", 'if status == "failed"', "isWorking(status:"):
            self.assertNotIn(needle, block, needle)
        status_helper = body("private func status(of state: State)")
        order = [status_helper.index('== "failed"'), status_helper.index("waitingOnUser")]
        self.assertEqual(order, sorted(order), "a failure outranks a request")

    def test_background_is_checked_by_the_rules_not_the_tracker(self) -> None:
        self.assertIn("if background { return .idle }", ACTIVITY)
        # The tracker only carries the flag to the rules.
        self.assertIn("background: state.background", TRACKER)


class TheTransitions(unittest.TestCase):
    def test_a_tool_leaves_the_set_when_it_completes(self) -> None:
        block = body("public mutating func toolCompleted")
        self.assertIn("state.openCalls.remove(at: index)", block)
        # A completion whose start was never seen still closes a call of that name.
        self.assertIn("state.openCalls.lastIndex(where: { $0.name == name })", block)

    def test_a_completion_is_not_an_error(self) -> None:
        # `ok` is accepted and deliberately unused: the reference's error is a failed *run*.
        block = body("public mutating func toolCompleted")
        self.assertNotIn('ok:', block.split("\n")[0])
        self.assertNotIn(".error", block)
        self.assertIn("public mutating func toolCompleted(botID: BotID, name: String?, callID: String, ok: Bool)",
                      TRACKER)

    def test_a_tool_start_stops_the_bot_composing(self) -> None:
        block = body("public mutating func toolStarted")
        self.assertIn("state.composing = false", block)
        # Thinking is *not* cleared: it is what the face falls back to when the tool returns.
        self.assertNotIn("state.thinking = false", block)

    def test_a_replayed_start_does_not_double_the_call(self) -> None:
        block = body("public mutating func toolStarted")
        self.assertIn("firstIndex(where: { $0.callID == callID })", block)

    def test_settling_clears_everything(self) -> None:
        block = body("public mutating func settled")
        for line in ("state.openCalls = []", "state.composing = false",
                     "state.thinking = false", "state.waitingOnUser = false"):
            self.assertIn(line, block)

    def test_stopping_the_stream_ends_the_turn(self) -> None:
        block = body("public mutating func setStreaming")
        self.assertIn("state.openCalls = []", block)
        self.assertIn('state.status = "completed"', block)

    def test_the_event_reduction_covers_the_four_families(self) -> None:
        block = body("public mutating func apply")
        for case in (".toolStart(", ".toolProgress(", ".toolComplete(", ".thinkingDelta(",
                     ".messageDelta", ".messageComplete", ".request:", ".error"):
            self.assertIn(case, block, case)
        # A heartbeat with no text must not make the face think.
        self.assertIn("if !text.isEmpty { thinking(botID: botID) }", block)
        # A host error is the run's failure, so it reaches the face as `blocked`.
        self.assertIn("hostFailed(botID: botID)", block)
        # A transport event is not a bot's event — and neither is a reaction: an emoji another
        # device set says nothing about whether this bot is working.
        self.assertIn("case .ready, .state, .contextUsage, .sessionUpdated,", block)
        self.assertIn(".reactionUpdated, .unknown:", block)

    def test_every_transition_has_a_test(self) -> None:
        # The behavioural half lives in Swift. These names are the contract this file describes.
        for name in ("testABotNobodyHasHeardFromIsIdle",
                     "testComposingIsWriting",
                     "testThinkingIsThinking",
                     "testEveryToolFamilyPicksItsOwnPose",
                     "testAFinishedToolFallsBackToWorking",
                     "testAFinishedToolFallsBackToThinking",
                     "testARequestIsWaitingAndOutranksATool",
                     "testAFailureOutranksARequest",
                     "testBackgroundWorkIsIdleOverEverything",
                     "testASettledTurnIsIdleAgain",
                     "testEventsAreReducedTheWayTheClientReceivesThem",
                     "testTwoBotsKeepTwoFaces"):
            self.assertIn(f"func {name}(", SWIFT_TESTS, name)

    def test_the_swift_tests_check_the_rules_against_the_shared_vocabulary(self) -> None:
        self.assertIn("BotAvatarActivity.from(status: status)", SWIFT_TESTS)
        self.assertIn("XCTAssertFalse(tracker.activity(for: bot).isAnimated", SWIFT_TESTS)


class OneTrackerOneAccessor(unittest.TestCase):
    def test_the_model_owns_the_tracker(self) -> None:
        self.assertIn("@Published public private(set) var botActivityTracker = BotActivityTracker()", APP_MODEL)
        self.assertIn("public func activity(forBot botID: BotID) -> BotAvatarActivity", APP_MODEL)
        self.assertIn("botActivityTracker.activity(for: botID)", APP_MODEL)

    def test_events_are_reduced_before_the_open_conversation_guards(self) -> None:
        # Every branch of `apply` returns early for a session that is not on screen. The tracker is
        # fed first, so a turn on a bot you are not looking at still moves that bot's row.
        block = body("private func apply(_ event: ClientEvent) async", APP_MODEL)
        self.assertLess(block.index("trackActivity(event)"), block.index("switch event"))
        self.assertIn("defer { syncActivityWithRunState() }", block)

    def test_a_session_is_mapped_back_to_its_bot(self) -> None:
        self.assertIn("private var sessionBots: [SessionID: BotID] = [:]", APP_MODEL)
        self.assertIn("private func noteSessionOwner(", APP_MODEL)
        self.assertIn("noteSessionOwner(id)", APP_MODEL)
        self.assertIn("noteSessionOwner(session)", APP_MODEL)

    def test_the_model_s_resync_is_the_other_authority(self) -> None:
        block = body("private func syncActivityWithRunState()", APP_MODEL)
        self.assertIn("setStreaming(", block)
        self.assertIn("isCompressing", block)
        self.assertIn("setWaitingOnUser(!pendingRequests.isEmpty", block)

    def test_the_mac_forwards_the_same_answer(self) -> None:
        self.assertIn("func activity(for botID: BotID) -> BotAvatarActivity", WORKSPACE)
        self.assertIn("model.activity(forBot: botID)", WORKSPACE)


if __name__ == "__main__":
    unittest.main()
