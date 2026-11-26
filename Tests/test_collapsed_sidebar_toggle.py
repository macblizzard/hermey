"""A collapsed panel keeps its toggle on the window's floor, not on the title bar.

Collapsing the bot panel used to move one control: the panel's own floor bar (Settings left,
search and the toggle right) went away with the panel, and the only copy of the toggle reappeared
in the chat header's leading `HStack` — the window's top-left corner, padded past the traffic
lights. The control did not disappear, it *jumped*, which is what the owner reported: "when sidebar
is closed the sidebar icon moves to the top of the sidebar, instead it should be placed near the
actual position when sidebar is shown".

The door is drawn on the floor now (`SidebarFloorToggle`), sharing the panel bar's line, so the
glyph does not move a point when the panel goes. These guards pin each half of that: the header
copy is gone, exactly one copy exists, its centre comes from the bar's own constants, the shown
state's bar is untouched, and nothing leaked into the phone.
"""
from __future__ import annotations

import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAC = ROOT / "Apps" / "HermesMac"
MOBILE = ROOT / "Apps" / "HermesMobile"

HEADER = (MAC / "Conversation" / "ConversationHeader.swift").read_text(encoding="utf-8")
PANE = (MAC / "Conversation" / "ConversationPane.swift").read_text(encoding="utf-8")
SIDEBAR = (MAC / "Sidebar" / "BotSidebarView.swift").read_text(encoding="utf-8")
STORE = (MAC / "Workspace" / "WorkspaceStore.swift").read_text(encoding="utf-8")
TOGGLE_PATH = MAC / "Conversation" / "SidebarFloorToggle.swift"
TOGGLE = TOGGLE_PATH.read_text(encoding="utf-8")


def swift_files(directory: Path) -> list[Path]:
    return sorted(directory.rglob("*.swift"))


def block(source: str, start: str, end: str = "\n    }") -> str:
    """The text from `start` to the first `end` after it."""
    return source.split(start, 1)[1].split(end, 1)[0]


class TheHeaderNoLongerCarriesIt(unittest.TestCase):
    def test_the_branch_is_gone(self) -> None:
        self.assertNotIn("isSidebarHidden", HEADER)
        self.assertNotIn('"sidebar.leading"', HEADER)
        self.assertNotIn("toggleSidebar", HEADER)

    def test_it_is_not_in_the_headers_leading_hstack(self) -> None:
        leading = block(HEADER, "private func header(width: CGFloat) -> some View {",
                        ".frame(width: width, height: Geometry.chatHeaderPill + 2)")
        self.assertIn("HStack(spacing: 8) {", leading)
        self.assertIn("Spacer(minLength: 12)", leading)
        for gone in ('"sidebar.leading"', "HermeyIconButton", "toggleSidebar", "isSidebarHidden"):
            self.assertNotIn(gone, leading,
                             f"{gone} in the header is the control jumping to the title bar again")

    def test_the_traffic_light_padding_went_with_it(self) -> None:
        # The clearance only existed because a control was on the lights' own line. Nothing in the
        # header is there now, so the padding would be a reservation for a control that is gone.
        self.assertNotIn("trafficLightClearance", HEADER)


class ThereIsExactlyOneCopyWhileHidden(unittest.TestCase):
    def test_the_app_draws_the_collapsed_glyph_once(self) -> None:
        # The palette's row also names the glyph, but a palette row is not a door on screen: the
        # button itself must be built in exactly one place.
        hits = [path.name for path in swift_files(MAC)
                if 'HermeyIconButton("sidebar.leading"' in path.read_text(encoding="utf-8")]
        self.assertEqual(hits, ["SidebarFloorToggle.swift"],
                         "a second copy is a second door: one of them is in the wrong place")

    def test_the_pane_draws_it_once_and_only_while_hidden(self) -> None:
        self.assertEqual(PANE.count("SidebarFloorToggle"), 1)
        start = PANE.index(".overlay(alignment: .bottomLeading) {")
        gate = PANE[start:start + 400]
        self.assertIn("if store.isSidebarHidden {", gate)
        self.assertIn("SidebarFloorToggle { store.toggleSidebar() }", gate)

    def test_the_shown_state_glyph_is_still_the_panels(self) -> None:
        hits = [path.name for path in swift_files(MAC)
                if '"sidebar.left"' in path.read_text(encoding="utf-8")]
        self.assertEqual(hits, ["BotSidebarView.swift"])


class ItsCentreIsTheBarsOwnLine(unittest.TestCase):
    def test_the_vertical_inset_is_the_bars_constant(self) -> None:
        # `bottomBarHeight` is 30 + barInset * 2 and the bar centres its 30 pt controls, so a 30 pt
        # box inset by `barInset` has the bar's centre — 25 pt up. Read from the panel, never
        # copied: a magic number here is the glyph sitting a few points off the line it shares.
        self.assertIn("private static let inset: CGFloat = BotSidebarView.barInset", TOGGLE)
        self.assertIn("Self.inset", TOGGLE)
        self.assertIn("padding(.bottom, Self.inset)", TOGGLE)

    def test_no_numeric_vertical_padding(self) -> None:
        self.assertIsNone(re.search(r"\.padding\(\.(?:top|bottom), [0-9]", TOGGLE),
                          "the floor line must come from the bar's constants, not a magic number")

    def test_the_box_is_the_bars_control_size(self) -> None:
        self.assertIn("size: .bar", TOGGLE)
        # `.bar` on macOS is `BarIconScale.of(24)`; the bar's own frame is `30 + barInset * 2` and
        # its controls are that same 30 pt box, which is what makes the two centres equal.
        self.assertIn("case .bar: return BarIconScale.of(24)",
                      (ROOT / "Sources" / "HermeyUI" / "Controls.swift").read_text(encoding="utf-8"))
        self.assertIn("public static let factor: CGFloat = 1.25",
                      (ROOT / "Sources" / "HermeyUI" / "Controls.swift").read_text(encoding="utf-8"))
        self.assertIn("private static let bottomBarHeight: CGFloat = 30 + barInset * 2", SIDEBAR)

    def test_the_arithmetic_is_written_down(self) -> None:
        # A comment a reviewer can check against the bar, rather than a number to trust.
        self.assertIn("barInset + 15 == (30 + barInset * 2) / 2", TOGGLE)


class ItDoesNotShiftTheConversation(unittest.TestCase):
    def test_it_is_an_overlay_not_a_row(self) -> None:
        self.assertIn(".overlay(alignment: .bottomLeading) {", PANE)
        # The composer keeps its own overlay and its own height; the toggle is a sibling drawing
        # over the floor, not a member of the stack that measures the composer.
        self.assertIn(".overlay(alignment: .bottom) {", PANE)
        self.assertIn("Color.clear.preference(key: ComposerHeightKey.self, value: proxy.size.height)",
                      PANE)
        floating = block(PANE, ".overlay(alignment: .bottom) {", "\n            }")
        self.assertNotIn("SidebarFloorToggle", floating)

    def test_it_sits_in_the_windows_leading_corner(self) -> None:
        self.assertIn("padding(.leading, Self.inset)", TOGGLE)
        # Not the bar's trailing position: with the panel hidden the composer owns the whole
        # window, and that x is inside its card at any ordinary width.
        body = block(TOGGLE, "var body: some View {")
        self.assertNotIn("sidebarWidth", body)


class ItComesBackAndStaysQuiet(unittest.TestCase):
    def test_the_first_click_brings_the_panel_back(self) -> None:
        self.assertIn("SidebarFloorToggle { store.toggleSidebar() }", PANE)
        self.assertIn("isSidebarHidden.toggle()", STORE)

    def test_its_label_and_help_say_what_it_does(self) -> None:
        self.assertIn('static let label = "Show the bot panel"', TOGGLE)
        self.assertIn('HermeyIconButton("sidebar.leading", label: Self.label, size: .bar)', TOGGLE)
        # The same sentence as the tooltip and the accessibility label, like the panel's own
        # "Hide the bot panel" — no shortcut is claimed, because the menu's (⌘S) and the palette's
        # (⌘⌥S) disagree and neither belongs on a floor control's tooltip.
        self.assertIn(".help(Self.label)", TOGGLE)
        self.assertIn('accessibilityIdentifier("sidebar.collapsedToggle")', TOGGLE)

    def test_it_does_not_wear_the_system_ring(self) -> None:
        self.assertIn(".hermeyFocusQuiet()", TOGGLE)

    def test_it_has_its_own_surface(self) -> None:
        # The bar's fill left with the panel; a bare glyph on the floor would read as part of
        # whatever it is drawn over.
        self.assertIn("Circle().fill(Tokens.surface)", TOGGLE)


class TheShownStateBarIsUnchanged(unittest.TestCase):
    def test_settings_left_search_and_toggle_right(self) -> None:
        bar = block(SIDEBAR, "private var bottomBar: some View {", ".accessibilityIdentifier(\"sidebar.bottomBar\")")
        settings = bar.index("SettingsLink {")
        search = bar.index('"magnifyingglass"')
        toggle = bar.index('HermeyIconButton("sidebar.left"')
        self.assertLess(settings, search)
        self.assertLess(search, toggle)
        self.assertIn("Spacer(minLength: 0)", bar)
        self.assertIn(".padding(.horizontal, Self.barInset)", bar)
        self.assertIn(".frame(height: Self.bottomBarHeight)", bar)

    def test_the_bar_is_still_the_panels_own_width(self) -> None:
        root_view = (MAC / "Workspace" / "WorkspaceRoot.swift").read_text(encoding="utf-8")
        self.assertIn("BotSidebarView(model: model, store: store)", root_view)
        self.assertIn(".frame(width: store.sidebarWidth)", root_view)
        self.assertIn("if !store.isSidebarHidden {", root_view)


class ThePhoneIsUntouched(unittest.TestCase):
    def test_no_mac_only_panel_code_reaches_it(self) -> None:
        for path in swift_files(MOBILE):
            source = path.read_text(encoding="utf-8")
            for leak in ("SidebarFloorToggle", "BotSidebarView", "sidebar.collapsedToggle"):
                self.assertNotIn(leak, source, f"{path.name} grew a Mac-only panel control")

    def test_no_mobile_file_is_modified(self) -> None:
        """The panel's vocabulary must not reach the phone — checked on the diff, not on `git status`.

        This used to assert that `git status` reported no mobile file at all, which only ever held on
        a clean tree: any other change that legitimately touches the phone (a login card, say) turned
        this into a tripwire for work that has nothing to do with the sidebar. The guarantee that
        matters is the same one the test above makes, applied to what this change actually wrote.
        """
        try:
            changed = subprocess.run(["git", "diff", "--", "Apps/HermesMobile"],
                                     cwd=ROOT, capture_output=True, text=True, timeout=20)
        except (OSError, subprocess.SubprocessError):  # pragma: no cover - no git in the sandbox
            self.skipTest("git is not available here")
        if changed.returncode != 0:
            self.skipTest("not a git checkout")
        for leak in ("SidebarFloorToggle", "BotSidebarView", "sidebar.collapsedToggle",
                     "isSidebarHidden", "sidebarWidth"):
            self.assertNotIn(leak, changed.stdout, "the phone grew part of this panel")


if __name__ == "__main__":
    unittest.main()
