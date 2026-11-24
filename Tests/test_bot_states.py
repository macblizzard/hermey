"""One vocabulary: the eight bot states and the one word each of them prints.

The enum and the tracker are Swift, so this file reads the sources and pins the four things a
copy can silently get wrong:

* **the case set.** `idle, thinking, reading, working, computer, waiting, blocked, done`, in that
  order, and no `writing`/`error` case left anywhere — a surface that still switches on the old
  names is a surface that can no longer be reached;
* **the words.** `BotStateWord` is the only place the eight strings exist, and every surface asks
  it: the roster badge, the pet, and the Live Activity's phase word;
* **`done`.** Derived from *when* a turn ended, held for four seconds, then `idle`; a new turn
  clears the hold;
* **`blocked`.** Derived from a host error for that bot, cleared by the first event of the next
  turn, and ranked above a pending request.

The behavioural half lives in `Tests/HermesKitTests/BotActivityTrackerTests.swift` (it drives the
events and asserts the face); this file is the contract that the same behaviour stays wired.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KIT = ROOT / "Sources" / "HermesKit"
UI = ROOT / "Sources" / "HermeyUI"
ACTIVITY = (KIT / "BotAvatarActivity.swift").read_text(encoding="utf-8")
WORDS = (KIT / "BotStateWord.swift").read_text(encoding="utf-8")
TRACKER = (KIT / "BotActivityTracker.swift").read_text(encoding="utf-8")
APP_MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")
BADGE = (UI / "BotStateBadge.swift").read_text(encoding="utf-8")
COORDINATOR = (ROOT / "Apps" / "HermesMobile" / "Views" / "LiveActivityCoordinator.swift").read_text(encoding="utf-8")
ATTRIBUTES = (ROOT / "Apps" / "HermesLiveActivity" / "HermeyTurnAttributes.swift").read_text(encoding="utf-8")
WIDGET = (ROOT / "Apps" / "HermesLiveActivity" / "HermeyTurnLiveActivity.swift").read_text(encoding="utf-8")
SIDEBAR = (ROOT / "Apps" / "HermesMac" / "Sidebar" / "SidebarBotList.swift").read_text(encoding="utf-8")
LIST = (ROOT / "Apps" / "HermesMobile" / "Views" / "BotListScreen.swift").read_text(encoding="utf-8")
PET = (ROOT / "Apps" / "HermesMac" / "Pets" / "PetView.swift").read_text(encoding="utf-8")
SWIFT_TESTS = (ROOT / "Tests" / "HermesKitTests" / "BotActivityTrackerTests.swift").read_text(encoding="utf-8")

STATES = ["idle", "thinking", "reading", "working", "computer", "waiting", "blocked", "done"]
LABELS = {
    "idle": "Idle",
    "thinking": "Thinking",
    "reading": "Reading",
    "working": "Working",
    "computer": "Using the computer",
    "waiting": "Waiting for you",
    "blocked": "Blocked",
    "done": "Done",
}

# Every surface that prints a bot's state. None of these may spell one of the eight words itself.
SURFACES = {
    "activity": ACTIVITY,
    "words": WORDS,
    "tracker": TRACKER,
    "badge": BADGE,
    "coordinator": COORDINATOR,
    "attributes": ATTRIBUTES,
    "widget": WIDGET,
    "sidebar": SIDEBAR,
    "list": LIST,
    "pet": PET,
}


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


def code(source: str) -> str:
    """Source with whole-line comments removed: a doc may name a word, code may not spell it."""
    return "\n".join(line for line in source.splitlines()
                     if not line.lstrip().startswith("//"))


def cases(source: str) -> list[str]:
    """The `case` declarations of an enum at one indent, in source order."""
    return re.findall(r"^    case (\w+)$", source, re.M)


class TheEightStatesAreExactlyThese(unittest.TestCase):
    def test_the_case_list_is_the_eight_in_order(self) -> None:
        self.assertEqual(cases(ACTIVITY), STATES)

    def test_the_shape_callers_compile_against_is_kept(self) -> None:
        self.assertIn("public enum BotAvatarActivity: String, CaseIterable, Hashable, Sendable", ACTIVITY)

    def test_writing_and_error_are_gone(self) -> None:
        self.assertNotIn("case writing", ACTIVITY)
        self.assertNotIn("case error", ACTIVITY)
        # …and nothing in the app still names them as a member: that would not compile, and the
        # point of the guard is to fail here, before a Mac does.
        for path in sorted(ROOT.glob("Sources/**/*.swift")) + sorted(ROOT.glob("Apps/**/*.swift")):
            source = path.read_text(encoding="utf-8")
            self.assertNotIn(".writing", source, f"{path.name} still uses the old writing state")
            for old in ("BotAvatarActivity.error", "activity == .error", "activity != .error"):
                self.assertNotIn(old, source, f"{path.name} still uses the old error state")

    def test_write_file_is_a_working_tool_not_a_state(self) -> None:
        # The tool set survives; only the pose it picks changed.
        self.assertIn('public static let writingTools: Set<String> = ["write_file"]', ACTIVITY)
        from_block = body("public static func from", ACTIVITY)
        self.assertNotIn("writingTools.contains", from_block)
        self.assertIn("return .working", from_block)
        self.assertIn("if composing { return .working }", from_block)

    def test_a_failed_run_is_blocked(self) -> None:
        from_block = body("public static func from", ACTIVITY)
        self.assertIn('if status == "failed" { return .blocked }', from_block)


class TheWordsLiveInOneFunction(unittest.TestCase):
    def test_the_word_table_has_the_eight_labels(self) -> None:
        self.assertEqual(cases(WORDS), STATES)
        found = dict(re.findall(r"case \.(\w+): return \"([^\"]+)\"", WORDS))
        self.assertEqual(found, LABELS)

    def test_the_activity_delegates_instead_of_restating(self) -> None:
        label = body("public var label", ACTIVITY)
        self.assertIn("BotStateWord(rawValue: rawValue)?.label", label)
        self.assertNotIn('"', label, "the activity spells a word itself")

    def test_no_surface_spells_a_word_itself(self) -> None:
        # `BotStateWord.swift` is the one file allowed to contain them; every other surface asks
        # for `label`. "Done" is the dangerous one — it is also a sheet button — which is why the
        # check is per surface rather than a blanket grep of the tree.
        for name, source in SURFACES.items():
            if name == "words":
                continue
            for state, word in LABELS.items():
                self.assertNotIn(f'"{word}"', code(source),
                                 f"{name} spells {state} as {word!r} itself")

    def test_the_badge_is_the_word_and_nothing_else(self) -> None:
        self.assertIn("Text(activity.label)", BADGE)
        self.assertIn("if activity == .idle", BADGE)

    def test_the_roster_and_the_pet_read_the_badge(self) -> None:
        self.assertIn("BotStateBadge(activity:", SIDEBAR)
        self.assertIn("BotStateBadge(activity:", LIST)
        self.assertIn("BotStateBadge(activity: pet.activity", PET)
        # The pet takes the tracker's answer rather than deriving one of its own.
        self.assertIn("pet.model.setActivity(store.activity(for: botID))",
                      (ROOT / "Apps" / "HermesMac" / "Pets" / "DesktopPetController.swift").read_text(encoding="utf-8"))


class DoneIsHeldThenFallsToIdle(unittest.TestCase):
    def test_the_hold_is_four_seconds(self) -> None:
        self.assertIn("public static let doneHold: TimeInterval = 4", TRACKER)

    def test_both_ways_a_turn_ends_stamp_the_clock(self) -> None:
        settled = body("public mutating func settled")
        self.assertIn("state.finishedAt = clock()", settled)
        streaming = body("public mutating func setStreaming")
        self.assertIn("state.finishedAt = clock()", streaming)
        self.assertIn('state.status = "completed"', streaming)

    def test_the_face_reads_the_hold_before_the_ladder(self) -> None:
        activity = body("public func activity(for botID: BotID)")
        self.assertIn("if !state.background,", activity)
        self.assertIn("clock().timeIntervalSince(finished) < Self.doneHold", activity)
        self.assertIn("return .done", activity)
        # Blocked first, then done, then the ladder.
        self.assertLess(activity.index("state.blocked"), activity.index("state.finishedAt"))
        self.assertLess(activity.index("state.finishedAt"), activity.index("BotAvatarActivity.from("))

    def test_a_new_turn_clears_the_hold(self) -> None:
        for symbol in ("public mutating func setStreaming", "public mutating func toolStarted",
                       "public mutating func setComposing", "public mutating func setStatus"):
            self.assertIn("state.finishedAt = nil", body(symbol), symbol)

    def test_the_hold_expires_on_screen(self) -> None:
        expiry = body("public mutating func expireDone")
        self.assertIn("state.finishedAt = nil", expiry)
        hold = body("private func holdDone", APP_MODEL)
        self.assertIn("Task.sleep(for: .seconds(BotActivityTracker.doneHold))", hold)
        self.assertIn("self.botActivityTracker.expireDone(for: botID)", hold)
        self.assertIn("holdDone(for: bot)", body("private func syncActivityWithRunState", APP_MODEL))


class BlockedClearsOnANewTurn(unittest.TestCase):
    def test_a_host_error_blocks_the_bot(self) -> None:
        apply_block = body("public mutating func apply")
        self.assertIn("case .error:", apply_block)
        self.assertIn("hostFailed(botID: botID)", apply_block)
        failed = body("public mutating func hostFailed")
        self.assertIn("state.blocked = true", failed)
        self.assertIn("state.openCalls = []", failed, "the stopped tool must not stay on the face")

    def test_blocked_outranks_a_request_and_a_tool(self) -> None:
        activity = body("public func activity(for botID: BotID)")
        self.assertIn("if state.blocked { return .blocked }", activity)
        # Nothing else may precede it — not the request fold, not the ladder.
        self.assertEqual(min([activity.index("if state.blocked"),
                              activity.index("state.finishedAt"),
                              activity.index("BotAvatarActivity.from(")]),
                         activity.index("if state.blocked"))

    def test_the_next_turn_takes_it_off(self) -> None:
        # The next turn's own work clears it. `setStreaming` is deliberately not in this list: the
        # model re-asserts it on every event, including the one that reported the failure.
        for symbol, needle in (("public mutating func toolStarted", "state.blocked = false"),
                               ("public mutating func setComposing", "state.blocked = false"),
                               ("public mutating func setStatus", "state.blocked = false"),
                               ("public mutating func setWaitingOnUser", "state.blocked = false")):
            self.assertIn(needle, body(symbol), symbol)
        self.assertNotIn("state.blocked = false", body("public mutating func setStreaming"))

    def test_the_model_attributes_an_error_to_its_own_bot(self) -> None:
        track = body("private func trackActivity", APP_MODEL)
        self.assertIn(".error(let session, _, _):", track)
        self.assertIn("botActivityTracker.apply(event, bot: bot)", track)
        # …and no longer files it under "not a bot's state".
        self.assertIn("case .ready, .state, .requestCancelled, .contextUsage, .sessionUpdated,",
                      track)
        self.assertIn(".reactionUpdated, .unknown:", track)

    def test_the_swift_behavioural_half_is_named(self) -> None:
        for name in ("testAFailureOutranksARequest",
                     "testABlockedBotClearsOnTheNextTurn",
                     "testAFinishedTurnIsDoneThenIdle"):
            self.assertIn(f"func {name}(", SWIFT_TESTS, name)


class TheLiveActivitySaysTheSameWords(unittest.TestCase):
    def test_the_phase_word_is_the_state_word(self) -> None:
        word = body("public static func word", ATTRIBUTES)
        self.assertIn("case .working: return BotStateWord.working.label", word)
        self.assertIn("case .needsYou: return BotStateWord.waiting.label", word)
        self.assertIn("case .done: return BotStateWord.done.label", word)
        self.assertNotIn('return "', word, "the phase spells a word itself")

    def test_the_step_line_asks_the_activity(self) -> None:
        step = body("private func stepLine()", COORDINATOR)
        self.assertIn("return activity.label", step)
        self.assertIn("BotAvatarActivity.waiting.label", step)
        # The stop outranks the tool, and a failure outranks the stop.
        self.assertLess(step.index("activity == .blocked"), step.index("model.hasPendingRequests"))
        self.assertLess(step.index("model.hasPendingRequests"), step.index("model.liveTools.last"))

    def test_the_old_second_vocabulary_is_gone(self) -> None:
        for source in (COORDINATOR, ATTRIBUTES, WIDGET):
            rendered = code(source)
            self.assertNotIn('"Needs you"', rendered)
            self.assertNotIn('"Finished"', rendered)
            self.assertNotIn('"Waiting on you"', rendered)


if __name__ == "__main__":
    unittest.main()
