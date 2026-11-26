"""Idle faces float in the bot list — on one slow clock, and only while you can see them.

0.1.681 gave the drawn avatar an idle float (`OpenBotAvatarState.hover`), and the owner could not see
it where he looks for his bots: the list. Every row there drew with `animates: false`, because
seventeen always-animating `Canvas` faces at a busy face's cadence were part of the scroll cost the
panel had just been cured of. The answer he approved, word for word:

> At 3 Hz and only the rows actually on screen, no — that's roughly what one hovered row costs
> today... I'll animate visible idle rows at ~3 Hz, paused when the window isn't focused or a row is
> scrolled away.

What this file pins, all of it readable out of the Swift:

* **one clock for the list** — `BotListClock`, one `Timer`, no per-row timer, no display link, no
  `TimelineView` of its own in a row;
* the list cadence is **one constant** and slower than the chat header's;
* the clock publishes one `Double` and the rows read it, so a tick cannot invalidate the list's body
  (the filter, the grouping, the `LazyVStack`) — the cost stays at the faces that are on screen;
* every way of not being seen stops it: off screen, empty or collapsed panel, more rows than the
  ceiling, Reduce Motion, the app's own switch, a background scene, an inactive app, a window that is
  not key or is occluded;
* the float is a **pose term** (`BotAvatarWake`'s settled idle float) applied as an offset/scale, so
  a row's height and hit shape cannot change;
* a visible idle row is handed an instant where it used to be handed nothing, and `animates:` is
  still the busy-only rule — the drift never becomes a per-row timeline;
* the scroll work (the `LazyVStack`, `AppModel.botGroups`) is untouched.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAC = ROOT / "Apps" / "HermesMac"
UI = ROOT / "Sources" / "HermeyUI"
CLOCK = MAC / "Sidebar" / "BotListClock.swift"
SIDEBAR = MAC / "Sidebar" / "SidebarBotList.swift"
AVATAR = UI / "BotAvatarView.swift"
MOTION = UI / "BotAvatarMotion.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def code(path: Path) -> str:
    """The file with its comments removed: prose naming a symbol is not the symbol."""
    return "\n".join(line.split("//")[0] for line in read(path).splitlines())


def swift_declaration(text: str, marker: str) -> str:
    """The brace-balanced body of the first declaration containing `marker`."""
    start = text.index(marker)
    opening = text.index("{", start)
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    raise AssertionError(f"{marker!r} has no balanced body")


class OneClockForTheWholeList(unittest.TestCase):
    """One timer, in one file, publishing one instant — never one per row."""

    def setUp(self) -> None:
        self.clock = code(CLOCK)
        self.sidebar = code(SIDEBAR)

    def test_the_sidebar_owns_no_timer_and_no_display_link(self) -> None:
        for symbol in ("Timer(", "Timer.scheduledTimer", "CADisplayLink", "DispatchSourceTimer",
                       "TimelineView"):
            self.assertNotIn(symbol, self.sidebar,
                             f"the list's rows must not run their own {symbol}")

    def test_the_clock_is_the_one_timer_and_it_publishes_one_instant(self) -> None:
        self.assertEqual(1, self.clock.count("Timer(timeInterval:"),
                         "one timer for the list, not one per row")
        self.assertIn("@Published private(set) var time: Double?", self.clock)

    def test_the_list_holds_the_clock_without_subscribing_to_it(self) -> None:
        # A `@StateObject` on the clock itself would re-evaluate the whole list on every tick — the
        # filter, the grouping, the `LazyVStack` — which is exactly the cost this feature avoids.
        box = swift_declaration(self.sidebar, "private final class FaceClockBox: ObservableObject")
        self.assertIn("let clock = BotListClock()", box)
        self.assertNotIn("@Published", box)
        self.assertNotIn("objectWillChange", box)
        self.assertIn("@StateObject private var faceClocks = FaceClockBox()", self.sidebar)
        self.assertIn("private var faceClock: BotListClock { faceClocks.clock }", self.sidebar)

    def test_the_clock_is_invalidated_not_merely_ignored(self) -> None:
        # "Paused" has to mean no timer, or a still list still costs three wake-ups a second.
        stop = swift_declaration(self.clock, "private func stop()")
        self.assertIn("timer?.invalidate()", stop)
        self.assertIn("timer = nil", stop)
        self.assertIn("if allowed { start() } else { stop() }",
                      swift_declaration(self.clock, "private func sync()"))

    def test_the_rows_read_the_instant_and_nothing_else_does(self) -> None:
        read_sites = re.findall(r"clock\.time", self.sidebar)
        self.assertEqual(1, len(read_sites),
                         "one read of the clock's value: the row's `idleDriftAt`")


class TheCadenceIsOneConstantAndSlowerThanTheHeader(unittest.TestCase):
    """Three frames a second, said once, and provably below the chat header's beat."""

    def setUp(self) -> None:
        self.clock = code(CLOCK)
        self.motion = code(MOTION)

    def test_the_list_cadence_is_three_hertz_and_one_constant(self) -> None:
        match = re.search(r"static let cadence: Double = 1\.0 / (\d+)", self.clock)
        self.assertIsNotNone(match, "the cadence must be one named constant")
        self.assertEqual("3", match.group(1) if match else "")
        # The timer takes the constant, never a literal of its own.
        self.assertIn("Timer(timeInterval: Self.cadence,", self.clock)
        self.assertNotRegex(self.clock, r"timeInterval: 0\.\d",
                            "no second interval may be spelled out beside the constant")

    def test_the_header_and_the_pet_keep_the_ten_hertz_idle_beat(self) -> None:
        self.assertIn("activity == .idle ? 1.0 / 10.0 : frameInterval", self.motion,
                      "the one face being looked at keeps its own, faster beat")
        header = (MAC / "Conversation" / "ConversationHeader.swift").read_text(encoding="utf-8")
        self.assertIn("BotAvatarView(identity:", header)
        # The list's three frames a second must be slower than that tenth of a second.
        list_interval = 1.0 / 3.0
        header_interval = 1.0 / 10.0
        self.assertGreater(list_interval, header_interval)


class NothingRunsWhenItCannotBeSeen(unittest.TestCase):
    """Each way of not being looked at, and where it is refused."""

    def setUp(self) -> None:
        self.clock = code(CLOCK)
        self.sidebar = read(SIDEBAR)
        self.avatar = code(AVATAR)

    def test_a_row_is_counted_only_while_it_is_on_screen(self) -> None:
        face = swift_declaration(self.sidebar, "private struct DriftingFace: View")
        self.assertIn("idleDriftAt: onScreen ? clock.time : nil", face,
                      "an off-screen row must be handed no instant at all")
        self.assertIn(".onAppear { report(onScreen: true) }", face)
        self.assertIn(".onDisappear { report(onScreen: false) }", face)
        # ...and the clock refuses to run with no row to draw.
        allowed = swift_declaration(self.clock, "private var allowed: Bool")
        self.assertIn("visibleRows > 0", allowed)
        self.assertIn("visibleRows = max(0, visibleRows - 1)",
                      swift_declaration(self.clock, "func rowDisappeared()"))

    def test_a_list_with_too_many_rows_keeps_every_face_still(self) -> None:
        self.assertIn("static let maximumDriftingRows = 32", self.clock)
        allowed = swift_declaration(self.clock, "private var allowed: Bool")
        self.assertIn("visibleRows <= Self.maximumDriftingRows", allowed)

    def test_a_background_or_unfocused_window_stops_it(self) -> None:
        allowed = swift_declaration(self.clock, "private var allowed: Bool")
        for gate in ("app.isActive", "window.isVisible", "window.isKeyWindow",
                     "window.occlusionState.contains(.visible)"):
            self.assertIn(gate, allowed, f"the clock does not check {gate!r}")
        # Focus and occlusion are heard, not polled.
        observe = swift_declaration(self.clock, "private func observe()")
        for name in ("NSApplication.didResignActiveNotification",
                     "NSWindow.didResignKeyNotification",
                     "NSWindow.didChangeOcclusionStateNotification",
                     "NSWindow.didMiniaturizeNotification"):
            self.assertIn(name, observe)
        # And the tick re-answers the question, because a window can slide behind another without a
        # notification the run loop delivers in time.
        self.assertIn("guard allowed else { stop(); return }",
                      swift_declaration(self.clock, "private func tick()"))

    def test_the_list_reads_its_own_window_not_the_apps_key_window(self) -> None:
        self.assertIn("BotListWindowProbe { window in faceClock.attach(window: window) }",
                      self.sidebar)
        probe = swift_declaration(self.clock, "struct BotListWindowProbe: NSViewRepresentable")
        self.assertIn("override func viewDidMoveToWindow()", probe)
        self.assertIn("override func hitTest(_ point: NSPoint) -> NSView? { nil }", probe)
        self.assertNotIn("NSApp.keyWindow", self.clock,
                         "the list must ask for its own window, not whichever one is key")

    def test_reduce_motion_and_the_apps_switch_stop_both_ends(self) -> None:
        self.assertIn("faceClock.setMotionAllowed(!systemReduceMotion && appAllowsMotion "
                      "&& scenePhase == .active",
                      self.sidebar)
        self.assertIn(".onChange(of: systemReduceMotion) { _, _ in syncFaceClock() }", self.sidebar)
        self.assertIn(".onChange(of: appAllowsMotion) { _, _ in syncFaceClock() }", self.sidebar)
        drift = swift_declaration(self.avatar, "private var driftInstant: Double?")
        self.assertIn("guard let idleDriftAt, activity == .idle else { return nil }", drift)
        self.assertIn("!(reduceMotion || systemReduceMotion), appAllowsMotion, "
                      "scenePhase == .active", drift)


class TheFloatIsAPoseTerm(unittest.TestCase):
    """Motion inside a fixed box: no height, no hit shape, no second motion language."""

    def setUp(self) -> None:
        self.avatar = read(AVATAR)
        self.sidebar = read(SIDEBAR)

    def test_the_drift_is_the_float_a_settled_hover_draws(self) -> None:
        frame = swift_declaration(self.avatar, "private func motionFrame(")
        self.assertIn("BotAvatarWake.frame(at: drift, since: nil, traits: traits)", frame,
                      "the list's float is the hover's settled float, not a third motion")
        # Order of precedence: the pointer, then a busy face, then the drift, then rest.
        self.assertLess(frame.index("if awake"), frame.index("if moves"))
        self.assertLess(frame.index("if moves"), frame.index("if let drift"))
        self.assertLess(frame.index("if let drift"), frame.index("return .rest"))

    def test_the_row_keeps_its_fixed_height_and_hit_shape(self) -> None:
        row = swift_declaration(self.sidebar, "private func row(for bot: Bot,")
        self.assertIn(".frame(height: metrics.rowHeight)", row)
        self.assertIn("static let rowHeight: CGFloat = 54", self.sidebar)
        # The drift adds no modifier to the row: it is inside the face, which is a fixed square.
        self.assertNotIn("idleDriftAt", row)

    def test_a_visible_idle_row_is_handed_an_instant(self) -> None:
        row = swift_declaration(self.sidebar, "private func row(for bot: Bot,")
        self.assertIn("DriftingFace(clock: faceClock,", row)
        self.assertIn("size: metrics.avatar", row)
        # The resting rule is still the busy-only one: the drift never becomes `animates: true`.
        self.assertIn("animates: store.activity(for: bot.id) != .idle", row)
        self.assertNotIn("animates: true", row)
        face = swift_declaration(self.sidebar, "private struct DriftingFace: View")
        self.assertIn("idleDriftAt: onScreen ? clock.time : nil", face)

    def test_the_hover_and_a_busy_row_still_win(self) -> None:
        row = swift_declaration(self.sidebar, "private func row(for bot: Bot,")
        self.assertIn("wakesOnHover: isHovered", row)
        # Hover fill and hairline are the row's own, untouched.
        self.assertIn("Tokens.controlHover", row)
        self.assertIn("Tokens.borderStrong", row)
        # A hovered face still runs at `BotAvatarWake.frameInterval` (the busy beat).
        drawn = swift_declaration(self.avatar, "private func drawnBody(")
        self.assertIn("minimumInterval: awake ? BotAvatarWake.frameInterval", drawn)


class TheScrollWorkIsUntouched(unittest.TestCase):
    """The list is still lazy, still grouped by the model, and still 54 pt a row."""

    def setUp(self) -> None:
        self.sidebar = read(SIDEBAR)

    def test_the_rows_are_still_a_lazy_stack_of_the_models_groups(self) -> None:
        self.assertIn("LazyVStack(alignment: .leading, spacing: 1)", self.sidebar)
        self.assertIn("ForEach(model.botGroups)", self.sidebar)
        self.assertIn("ForEach(group.bots)", self.sidebar)
        self.assertIn("private var visibleBots: [Bot] { model.orderedBots.filter(matches) }",
                      self.sidebar)
        # The clock's tick must not have grown a second path into the list's content.
        self.assertNotIn("faceClock.time", swift_declaration(self.sidebar, "private var rows"))

    def test_the_clock_does_not_reach_the_grouping(self) -> None:
        grouping = (ROOT / "Sources" / "HermesAppKit" / "BotGrouping.swift").read_text(encoding="utf-8")
        self.assertNotIn("Clock", grouping)
        self.assertIn("public var botGroups: [BotGroup]", read(ROOT / "Sources" / "HermesAppKit"
                                                               / "AppModel.swift"))


if __name__ == "__main__":
    unittest.main()
