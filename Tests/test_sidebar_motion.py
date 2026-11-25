"""A pane opening is one horizontal move, and nothing in the conversation moves vertically.

Reported 2026-11-25, with the Mac window in front of them: "when i open and close the left sidebar
(bot list) and the right sidebar (bot menu), the middle section (conversation) jumps up or down to
make room for the sidebars. can we make this smoother with animations without this janky motion?"

What was actually moving, all of it vertical and all of it on the *same tick* as the horizontal move:

* the column's width was an animated value, so the transcript was handed a new width on every frame
  of the pane's 180 ms — the text re-wrapped per frame, every row's height changed with it, and the
  scroll view's document grew and shrank under the reader;
* `ConversationPane.composerHeight` is measured from the composer, so a composer that re-wrapped
  mid-animation dribbled a new `bottomInset` into the transcript's layout on the same frames;
* `ScrollViewportProbe.contentGrew()` fired on *any* document frame change and took a width change for
  a new message at the foot, jumping the clip to the end once per frame — against an easing move;
* and the state change had two animation owners (the store's `withAnimation` and a
  `.animation(_:value:)` at the root), which is two transactions for one flag.

The fix is a single owner, a single pane timing, a layout resolved once at its final width, and a
follow that only answers height. These tests pin the shape of it: they read the Swift, not the frames.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAC = ROOT / "Apps" / "HermesMac"

ROOT_VIEW = (MAC / "Workspace" / "WorkspaceRoot.swift").read_text(encoding="utf-8")
STORE = (MAC / "Workspace" / "WorkspaceStore.swift").read_text(encoding="utf-8")
MOTION = (MAC / "Workspace" / "WorkspaceMotion.swift").read_text(encoding="utf-8")
PANE = (MAC / "Conversation" / "ConversationPane.swift").read_text(encoding="utf-8")
HEADER = (MAC / "Conversation" / "ConversationHeader.swift").read_text(encoding="utf-8")
SCROLL = (MAC / "Conversation" / "TranscriptScroll.swift").read_text(encoding="utf-8")
COMPOSER = (MAC / "Conversation" / "MacComposerBar.swift").read_text(encoding="utf-8")
PANEL = (MAC / "Workspace" / "MacBotPanel.swift").read_text(encoding="utf-8")
PROBE = (MAC / "Support" / "ScrollViewportProbe.swift").read_text(encoding="utf-8")


def without_comments(source: str) -> str:
    """The file with its line comments removed.

    The doc comments are where this repo explains the bug it is replacing, so a `not in` assertion
    has to read the code and not the prose that names the old shape.
    """
    return "\n".join(line for line in source.splitlines() if not line.strip().startswith("//"))


def block(source: str, start: str, end: str = "\n    }") -> str:
    """The text from `start` to the first `end` after it."""
    return source.split(start, 1)[1].split(end, 1)[0]


def holds(case: unittest.TestCase, needle: str, source: str, why: str = "this guard pins it") -> None:
    """`assertIn` that names the needle instead of echoing a whole Swift file into the log."""
    case.assertTrue(needle in source, f"{why}: expected {needle!r}")


class TheMiddleColumnIsWidthOnly(unittest.TestCase):
    """No vertical value in the conversation may read a sidebars' state."""

    PANE_FLAGS = ("isSidebarHidden", "isBotPanelPresented", "isComputerPanelPresented", "sidebarWidth")

    def test_the_conversation_reads_no_pane_state(self) -> None:
        # The one legal mention is the collapsed panel's floor toggle, which is drawn as an overlay on
        # the pane's own floor: it appears with the hidden state and adds no height (`ConversationPane`
        # says so, and `test_collapsed_sidebar_toggle` pins it). Cut that block out and the rest of the
        # reading surface must be blind to both panes.
        pane = without_comments(PANE)
        overlay = pane.split(".overlay(alignment: .bottomLeading) {", 1)
        self.assertEqual(len(overlay), 2, "the floor toggle's overlay is the one allowed mention")
        tail = overlay[1]
        rest = overlay[0] + tail.split("\n        }\n", 1)[1]
        for source, name in ((rest, "ConversationPane"), (without_comments(HEADER), "ConversationHeader"),
                             (without_comments(SCROLL), "TranscriptScroll"),
                             (without_comments(COMPOSER), "MacComposerBar")):
            for flag in self.PANE_FLAGS:
                self.assertFalse(flag in source,
                                 f"{name} reads {flag}: a vertical value in the middle column now "
                                 f"changes when a sidebar opens")

    def test_the_header_keeps_its_own_height_and_inset(self) -> None:
        # The pill's strip is a constant, measured from the pane's own width only where the *chips* are
        # dropped — never its height or its top inset.
        holds(self, ".frame(height: Geometry.chatHeader, alignment: .top)", HEADER)
        holds(self, ".padding(.top, 6)", HEADER)
        holds(self, ".frame(width: width, height: Geometry.chatHeaderPill + 2)", HEADER)

    def test_the_transcripts_vertical_insets_are_constants(self) -> None:
        holds(self, ".padding(.top, Geometry.chatHeaderPill + 20)", SCROLL)
        # The foot is the composer's measured height, which is the pane's own number — not a pane flag.
        holds(self, ".padding(.bottom, 10 + bottomInset)", SCROLL)
        holds(self, "private struct ComposerHeightKey: PreferenceKey", PANE)
        holds(self, ".onPreferenceChange(ComposerHeightKey.self)", PANE)

    def test_the_panel_is_a_width_and_nothing_else(self) -> None:
        holds(self, ".frame(width: WindowLayout.botPanelWidth)", PANEL)
        slot = block(without_comments(ROOT_VIEW), "} else if store.isBotPanelPresented {", "\n            }")
        self.assertIn("MacBotPanel(model: model, store: store)", slot)
        self.assertIn(".frame(maxHeight: .infinity)", slot)
        for vertical in (".padding(", ".frame(height", ".offset(y:"):
            self.assertNotIn(vertical, slot,
                             f"{vertical} in the panel's slot is vertical space the panel takes from "
                             f"the conversation")

    def test_the_column_resolves_its_layout_once(self) -> None:
        # An animated width is a layout per frame: without this the text re-wraps for the whole 180 ms.
        column = block(without_comments(ROOT_VIEW), "Group {\n                    if let room = model.activeRoom {",
                       "\n            // The bot's own panel")
        self.assertIn(".geometryGroup()", column)
        self.assertLess(column.index(".id(model.activeRoom.map"), column.index(".geometryGroup()"),
                        "the group has to wrap the column's identity and its frame")


class OneMotionForBothPanes(unittest.TestCase):
    def test_one_pane_duration_for_both_edges(self) -> None:
        # Two numbers are how 160 ms and 180 ms met in the first place (2026-11-17).
        code = without_comments(MOTION)
        self.assertEqual(code.count("paneDuration"), 2,
                         "one declaration and one use: the trailing pane aliases the leading one")
        holds(self, "private static let paneDuration: Double = 0.18", MOTION)
        holds(self, "static var sidebar: Animation", MOTION)
        self.assertNotIn("static var panel", code,
                         "a second pane timing is a second pair of numbers waiting to diverge")
        durations = re.findall(r"duration: ([0-9.]+)", code)
        self.assertEqual(sorted(set(durations)), ["0", "0.14"],
                         f"a pane duration was written inline: {durations}")
        self.assertEqual(code.count("0.18"), 1,
                         "the pane's 180 ms may only be spelled once, in `paneDuration`")

    def test_both_toggles_wrap_that_one_constant(self) -> None:
        sidebar = block(without_comments(STORE), "func toggleSidebar() {")
        panel = block(without_comments(STORE), "func toggleBotPanel() {", "\n    /// ")
        self.assertIn("withAnimation(WorkspaceMotion.sidebar) {", sidebar)
        self.assertIn("withAnimation(WorkspaceMotion.sidebar) {", panel)
        self.assertNotIn("WorkspaceMotion.panel", without_comments(STORE),
                         "a call site naming its own timing is a call site that can drift")

    def test_the_door_is_the_only_animation_owner(self) -> None:
        # Counted as a modifier, not as the `transition(.opacity.animation(...))` argument: one
        # `.animation(_:value:)` in this file, and it belongs to the palette.
        code = without_comments(ROOT_VIEW)
        owners = [line.strip() for line in code.splitlines() if line.strip().startswith(".animation(")]
        self.assertEqual(len(owners), 1, f"a second animation owner: {owners}")
        self.assertEqual(owners[0], ".animation(WorkspaceMotion.sheet, value: store.isPalettePresented)")
        for flag in ("isSidebarHidden", "isBotPanelPresented", "isComputerPanelPresented"):
            self.assertFalse(f"value: store.{flag}" in code,
                             f"{flag} grew a second animation owner in the view tree")

    def test_every_pane_door_is_animated(self) -> None:
        # The computer borrowed the panel's slot with no animation at all, which was the one door that
        # snapped; its ✕ and Escape went round it as well.
        for name in ("func toggleComputerPanel()", "func closeComputerPanel()", "func closeBotPanel()",
                     "func dismissBotPanelFromOutsideClick()"):
            body = block(without_comments(STORE), name)
            self.assertIn("withAnimation(WorkspaceMotion.sidebar) {", body, f"{name} snaps")


class ReduceMotionLandsInstantly(unittest.TestCase):
    def test_the_pane_motion_is_zero_duration(self) -> None:
        holds(self, "reduceMotion ? .linear(duration: 0) : .easeInOut(duration: paneDuration)", MOTION)
        holds(self, "NSWorkspace.shared.accessibilityDisplayShouldReduceMotion", MOTION)

    def test_reduce_motion_changes_no_geometry(self) -> None:
        # The state still changes; the layout it lands on must be the same one, or "no animation" would
        # be a different window rather than the same window reached instantly.
        for source, name in ((ROOT_VIEW, "WorkspaceRoot"), (PANE, "ConversationPane"),
                             (HEADER, "ConversationHeader"), (SCROLL, "TranscriptScroll")):
            for line in without_comments(source).splitlines():
                if "reduceMotion" not in line:
                    continue
                for geometry in (".frame(", ".padding(", "minWidth", "maxHeight"):
                    self.assertNotIn(geometry, line,
                                     f"{name} derives geometry from Reduce Motion: {line.strip()}")


class TheScrollDoesNotFollowAWidth(unittest.TestCase):
    def test_the_follow_answers_height_only(self) -> None:
        holds(self, "private var lastDocumentHeight: CGFloat?", PROBE)
        holds(self, "if grew { followGrowth() } else { report() }", PROBE)
        # The search's own gate has to survive the change: it is the other reason not to follow.
        holds(self, "if followsGrowth, lastVerdict != false {", PROBE)

    def test_one_follow_is_in_flight(self) -> None:
        # Four retrying jumps per frame of a resize is the "jumps up or down" in the report.
        holds(self, "guard !followInFlight else { return }", PROBE)
        holds(self, "scrollToBottom(attempts: 4) { [weak self] in self?.followInFlight = false }", PROBE)

    def test_a_pane_toggle_asks_the_transcript_for_nothing(self) -> None:
        for name in ("func toggleSidebar() {", "func toggleBotPanel() {"):
            body = block(without_comments(STORE), name, "\n    /// ")
            for scrollable in ("scrollRequest", "followsBottom", "anchorHold", "TranscriptScroll"):
                self.assertFalse(scrollable in body, f"{name} moves the reading position")
        for flag in ("isSidebarHidden", "isBotPanelPresented"):
            self.assertFalse(f".onChange(of: store.{flag})" in ROOT_VIEW,
                             f"the view tree re-lays out on {flag}")
            self.assertFalse(f".onChange(of: {flag})" in without_comments(SCROLL),
                             f"the transcript reacts to {flag}")


if __name__ == "__main__":
    unittest.main()
