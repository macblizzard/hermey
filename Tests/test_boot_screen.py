"""The launch screen: one gate, one static picture, and nothing loading behind it.

The app used to open onto a bot list that was still finding itself — a spinner here, "Asking the
host which bots it serves…" there — and a phone that had been launched a hundred times still showed
a white window for a frame first. Now a still launch screen covers that window in both shells, it
goes away the moment `LaunchReadiness` says the app is usable (or the deadline says it never will
be), and the bot list no longer has a loading state of its own to be caught in.

These are structural guards: the SwiftUI itself typechecks on CI, not here.
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

MOBILE_APP = ROOT / "Apps/HermesMobile/HermesMobileApp.swift"
MAC_APP = ROOT / "Apps/HermesMac/HermesMacApp.swift"
BOOT_SCREEN = ROOT / "Sources/HermeyUI/BootScreen.swift"
GATE = ROOT / "Sources/HermesAppKit/LaunchGateView.swift"
READINESS = ROOT / "Sources/HermesKit/LaunchReadiness.swift"
APP_MODEL = ROOT / "Sources/HermesAppKit/AppModel.swift"
MOBILE_LIST = ROOT / "Apps/HermesMobile/Views/BotListScreen.swift"
MAC_SIDEBAR = ROOT / "Apps/HermesMac/Sidebar/BotSidebarView.swift"
MAC_ROSTER = ROOT / "Apps/HermesMac/Sidebar/SidebarBotList.swift"
PROJECT = ROOT / "project.yml"
LAUNCH_COLOUR = ROOT / "Apps/HermesMobile/Assets.xcassets/LaunchBackground.colorset/Contents.json"
THEME = ROOT / "Sources/HermeyUI/Theme.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def yaml_uncommented(text: str) -> str:
    """The file with `#` comments dropped, for assertions about keys rather than prose."""
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


def number(pattern: str, text: str) -> float:
    """The one number in `text` matching `pattern`, as a float."""
    match = re.search(pattern, text)
    if match is None:
        raise AssertionError(f"nothing matched {pattern!r}")
    return float(match.group(1))


class BootScreenExistsInBothShells(unittest.TestCase):
    def test_ios_entry_point_draws_the_launch_screen_behind_the_gate(self) -> None:
        source = read(MOBILE_APP)
        self.assertIn("LaunchGateView(model: app.model", source,
                      "the phone's window root must be the gate")
        self.assertEqual(source.count("BootScreen()"), 1,
                         "the phone draws the launch screen exactly once, as the gate's picture")

    def test_mac_entry_point_draws_the_launch_screen_behind_the_gate(self) -> None:
        source = read(MAC_APP)
        self.assertIn("LaunchGateView(model: store.model", source,
                      "the Mac's window root must be the gate")
        self.assertEqual(source.count("BootScreen()"), 1)

    def test_the_mac_overlay_wraps_the_whole_window_root(self) -> None:
        # The splash has to cover the shell, not sit beside it: the gate is what the WindowGroup
        # returns, and `WorkspaceRoot` is inside it.
        source = read(MAC_APP)
        window = source.split('WindowGroup("Hermey") {', 1)[1]
        self.assertLess(window.index("LaunchGateView("), window.index("WorkspaceRoot(store: store)"))

    def test_both_apps_pass_the_one_fade_constant(self) -> None:
        for path in (MOBILE_APP, MAC_APP):
            self.assertIn("fadeOut: BootScreen.fadeOutDuration", read(path),
                          f"{path.name} must use the design system's fade, not a second number")

    def test_each_shell_wires_the_gate_exactly_once(self) -> None:
        # A second gate anywhere would be a second launch screen, and a second answer to when the
        # app is usable.
        uses = [path for path in sorted((ROOT / "Apps").rglob("*.swift"))
                if "LaunchGateView(" in read(path)]
        self.assertEqual(sorted(path.name for path in uses),
                         ["HermesMacApp.swift", "HermesMobileApp.swift"])


class ReadinessIsTheOnlyDecider(unittest.TestCase):
    def test_the_view_reads_the_phase_and_nothing_else(self) -> None:
        source = read(GATE)
        self.assertIn(".opacity(readiness.showsBootScreen ? 1 : 0)", source,
                      "visibility must be the gate's one property, applied as opacity")
        # No second opinion: no model emptiness, no timer, no `bots` check inside the gate's body.
        self.assertNotIn("model.bots", source)
        self.assertNotIn("showsBootScreen =", source)

    def test_the_launch_screen_is_only_up_while_waiting(self) -> None:
        source = read(READINESS)
        self.assertIn("public var showsBootScreen: Bool { phase == .waiting }", source,
                      "a phase other than waiting must never leave the splash up")

    def test_both_failures_are_terminal_hand_offs(self) -> None:
        source = read(READINESS)
        self.assertIn("guard !isTerminal else { return phase }", source)
        # A failure is a hand-off to the app's own UI, never a retry on the splash.
        self.assertIn("case notPaired", source)
        self.assertIn("case connection", source)
        self.assertIn("case deadline", source)

    def test_behind_the_gate_the_shell_is_always_drawn(self) -> None:
        # The splash sits *over* the app: an `if` that swapped the content out would make the fade
        # uncover an empty window.
        source = read(GATE)
        self.assertIn("content\n", source)
        self.assertIn(".accessibilityHidden(readiness.showsBootScreen)", source)


class TheLaunchScreenIsStill(unittest.TestCase):
    def test_it_draws_a_face_and_never_animates(self) -> None:
        source = read(BOOT_SCREEN)
        self.assertIn("animates: false", source,
                      "the face's own switch is what makes it the resting pose at any size")
        # Identifiers, not prose: the file explains at length what it deliberately does not do.
        for forbidden in ("TimelineView(", "withAnimation(", ".animation(", "accessibilityReduceMotion",
                          "reduceMotion", "BotAvatarMotion.bodyPose"):
            self.assertNotIn(forbidden, source,
                             f"a still launch screen has no business with {forbidden}")

    def test_it_fills_with_the_active_theme(self) -> None:
        source = read(BOOT_SCREEN)
        self.assertIn("Tokens.canvas", source,
                      "the fill is the theme's canvas, read at draw time")

    def test_the_face_is_the_size_the_brief_asked_for(self) -> None:
        side = number(r"public static let faceSide: CGFloat = ([0-9.]+)", read(BOOT_SCREEN))
        self.assertGreaterEqual(side, 96.0)
        self.assertLessEqual(side, 120.0)

    def test_the_fade_is_short(self) -> None:
        self.assertLessEqual(number(r"public static let fadeOutDuration: Double = ([0-9.]+)",
                                     read(BOOT_SCREEN)),
                             0.25, "leaving must be quick — this is a transition, not a showreel")

    def test_the_gate_defaults_to_the_same_fade(self) -> None:
        boot = number(r"fadeOutDuration: Double = ([0-9.]+)", read(BOOT_SCREEN))
        gate = number(r"fadeOut: TimeInterval = ([0-9.]+)", read(GATE))
        self.assertEqual(boot, gate, "the design system's fade and the gate's default must not drift")


class TheDeadlineExists(unittest.TestCase):
    def test_the_machine_has_a_hard_stop(self) -> None:
        source = read(READINESS)
        self.assertIn("public static let defaultDeadline: TimeInterval", source)
        self.assertIn("elapsed >= deadline", source)
        self.assertGreater(number(r"public static let defaultDeadline: TimeInterval = ([0-9.]+)", source),
                           0.0, "a zero deadline would blind the splash")

    def test_the_gate_uses_it(self) -> None:
        self.assertIn("deadline: TimeInterval = LaunchReadiness.defaultDeadline", read(GATE))

    def test_the_deadline_ends_in_the_app_not_on_an_animation(self) -> None:
        # The failed path is a hand-off: the same fade, then the app's own connect/pair UI — this
        # view never draws a message of its own.
        source = read(GATE)
        self.assertIn("case .failed", read(READINESS))
        self.assertNotIn("Text(", source, "the gate owns no copy: words belong to the shells")


class NoSecondLoadingStateInTheRoster(unittest.TestCase):
    """Pre-roster, the launch screen is the only thing that says "not yet"."""

    def test_the_phone_list_has_no_loading_row_or_block(self) -> None:
        source = read(MOBILE_LIST)
        for gone in ('Text("Loading bots', 'Text("Looking for bots', "loadingRow", "loadingBlock",
                     "SpinningRing(color: Tokens.textMuted"):
            self.assertNotIn(gone, source, f"{gone} is a placeholder under a placeholder")

    def test_the_phone_list_still_renders_nothing_while_the_roster_is_out(self) -> None:
        source = read(MOBILE_LIST)
        self.assertIn("if model.bots.isEmpty && model.botsLoading {", source)
        self.assertIn("EmptyView()", source)
        # The empty state must still not swallow a query's message findings.
        self.assertIn("} else if filtered.isEmpty && trimmedQuery.isEmpty", source)

    def test_the_mac_sidebar_has_no_finding_bots_state(self) -> None:
        source = read(MAC_SIDEBAR)
        for gone in ("discoveringBotsState", "FINDING BOTS", "Asking the host which bots"):
            self.assertNotIn(gone, source)
        # What remains is the truth of a host that has already answered or failed.
        self.assertIn("if let error = model.botsError {", source)
        self.assertIn("notConnectedState", source)

    def test_the_mac_roster_says_nothing_while_loading(self) -> None:
        source = read(MAC_ROSTER)
        self.assertNotIn("Asking the host which bots", source)
        loading = source.split("} else if model.botsLoading {", 1)
        self.assertEqual(len(loading), 2, "the loading branch should still exist, saying nothing")
        self.assertIn("EmptyView()", loading[1].split("} else {", 1)[0])

    def test_no_app_source_still_asks_which_bots_it_serves(self) -> None:
        for path in sorted((ROOT / "Apps").rglob("*.swift")):
            self.assertNotIn("Asking the host which bots it serves", read(path),
                             f"{path.relative_to(ROOT)} still draws a pre-roster spinner")


class TheGateHasRealSignals(unittest.TestCase):
    def test_the_two_answers_exist_and_are_published(self) -> None:
        source = read(APP_MODEL)
        self.assertIn("@Published public private(set) var rosterAnswered = false", source)
        self.assertIn("@Published public private(set) var sessionsAnswered = false", source)

    def test_each_answer_is_written_where_the_ask_returns(self) -> None:
        source = read(APP_MODEL)
        bots = source.split("public func loadBots() async {", 1)[1].split("private func", 1)[0]
        self.assertIn("rosterAnswered = true", bots)
        sessions = source.split("public func loadSessions() async {", 1)[1].split("\n    }", 1)[0]
        self.assertIn("sessionsAnswered = true", sessions)

    def test_a_new_dial_re_asks(self) -> None:
        source = read(APP_MODEL)
        start = source.split("public func start() async {", 1)[1].split("do {", 1)[0]
        self.assertIn("rosterAnswered = false", start)
        self.assertIn("sessionsAnswered = false", start)

    def test_the_gate_maps_every_signal(self) -> None:
        gate = read(GATE)
        for signal in ("isPaired:", "isConnected:", "connectionFailed:", "rosterAnswered:",
                       "sessionsAnswered:"):
            self.assertIn(signal, gate, f"launchSignals must hand over {signal}")
        self.assertIn("connection.isLive", gate)
        self.assertIn("connection.isFailed", gate)


class TheSystemLaunchScreenIsDark(unittest.TestCase):
    """iOS cannot animate its launch screen and cannot read a runtime theme. It gets a colour."""

    def test_project_points_the_launch_screen_at_a_colour_asset(self) -> None:
        source = yaml_uncommented(read(PROJECT))
        self.assertIn("UILaunchScreen:", source)
        self.assertIn("UIColorName: LaunchBackground", source)
        self.assertNotIn("UILaunchScreen: {}", source,
                         "an empty launch screen is the system's own background: white")

    def test_the_colour_asset_exists_and_is_the_default_theme_canvas(self) -> None:
        asset = json.loads(read(LAUNCH_COLOUR))
        components = asset["colors"][0]["color"]["components"]
        asset_hex = "".join(str(components[channel]).replace("0x", "")
                            for channel in ("red", "green", "blue"))

        theme = read(THEME)
        midnight = theme.split("public static let midnight = ThemePalette.make(", 1)[1]
        canvas = re.search(r"canvas: 0x([0-9A-Fa-f]{6})", midnight)
        if canvas is None:
            raise AssertionError("ThemeCatalog.midnight has no canvas colour")
        self.assertEqual(asset_hex.upper(), canvas.group(1).upper(),
                         "the static launch screen must be the default theme's canvas")


if __name__ == "__main__":
    unittest.main()
