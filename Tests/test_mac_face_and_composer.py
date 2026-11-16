"""The face carries the state, and the composer floats.

Two decisions pinned here, both from the two screenshots the owner marked up:

* **No status chips.** A chip is a word you have to read; a bot that flashes, sparks or zips is a
  thing you notice while looking at something else. The three states live on the portrait.
* **The composer floats.** It has no bar, no canvas strip and no frame at rest, the transcript runs
  under it and fades into it, and it grows *upward* — bottom edge fixed — with the transcript's
  foot following the measured height instead of an assumed one.
"""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

GALLERY = (ROOT / "Sources" / "HermeyUI" / "BotIconGallery.swift").read_text(encoding="utf-8")
HEADER = (ROOT / "Apps" / "HermesMac" / "Conversation" / "ConversationHeader.swift").read_text(encoding="utf-8")
PANE = (ROOT / "Apps" / "HermesMac" / "Conversation" / "ConversationPane.swift").read_text(encoding="utf-8")
COMPOSER_BAR = (ROOT / "Apps" / "HermesMac" / "Conversation" / "MacComposerBar.swift").read_text(encoding="utf-8")
COMPOSER = (ROOT / "Sources" / "HermeyUI" / "Composer.swift").read_text(encoding="utf-8")
TRANSCRIPT = (ROOT / "Apps" / "HermesMac" / "Conversation" / "TranscriptScroll.swift").read_text(encoding="utf-8")
SIDEBAR = (ROOT / "Apps" / "HermesMac" / "Sidebar" / "BotSidebarView.swift").read_text(encoding="utf-8")
ROSTER = (ROOT / "Apps" / "HermesMac" / "Sidebar" / "SidebarBotList.swift").read_text(encoding="utf-8")


class TheFaceSaysWhatItIsDoing(unittest.TestCase):
    """The eight activity states are the reference's, and no surface keeps its own copy."""

    ACTIVITY = (ROOT / "Sources" / "HermesKit" / "BotAvatarActivity.swift").read_text(encoding="utf-8")
    AVATAR_VIEW = (ROOT / "Sources" / "HermeyUI" / "BotAvatarView.swift").read_text(encoding="utf-8")

    def test_eight_states_and_their_precedence(self) -> None:
        self.assertIn("public enum BotAvatarActivity", self.ACTIVITY)
        for case in ("case idle", "case reading", "case writing", "case thinking",
                     "case computer", "case working", "case waiting", "case error"):
            self.assertIn(case, self.ACTIVITY)
        # A request is waiting; a failure outranks it; neither is a working run.
        order = [
            self.ACTIVITY.index("if background"),
            self.ACTIVITY.index('if status == "failed"'),
            self.ACTIVITY.index("if isWaitingOnUser"),
        ]
        self.assertEqual(order, sorted(order), "the state that needs a person wins the face")

    def test_the_face_is_what_moves_and_it_rests_on_error(self) -> None:
        # A body that breathes, sways, turns or pulses — and an error that holds still, which is
        # what makes "asleep" readable at a glance.
        motion = (ROOT / "Sources" / "HermeyUI" / "BotAvatarMotion.swift").read_text(encoding="utf-8")
        self.assertIn("public enum BotAvatarMotion", motion)
        self.assertIn("self != .error", self.ACTIVITY)
        # Reduce Motion, the app's switch and the size floor all stop it.
        self.assertIn("accessibilityReduceMotion", self.AVATAR_VIEW)
        self.assertIn("animates && appAllowsMotion", self.AVATAR_VIEW)
        self.assertIn("minimumSize: Double = minimumAnimatingSize", motion)
        self.assertIn("return size >= minimumSize", motion)

    def test_the_header_asks_the_tracker_instead_of_deriving(self) -> None:
        self.assertIn("store.activity(for: bot.id)", HEADER)
        self.assertNotIn("portraitStatus", HEADER)


class TheSidebarRowIsOneCluster(unittest.TestCase):
    def test_every_control_is_on_the_right(self) -> None:
        row = SIDEBAR.split("private var header: some View", 1)[1].split("private var closeSearch", 1)[0]
        # The spacer comes first: nothing is drawn on the leading edge at all.
        self.assertLess(row.index("Spacer(minLength: 0)"),
                        row.index('HermeyIconButton("magnifyingglass"'))
        for glyph in ("magnifyingglass", "sidebar.left", "gearshape"):
            self.assertGreater(row.index(glyph), row.index("Spacer(minLength: 0)"))

    def test_no_captions_over_the_lists(self) -> None:
        # "CHATS" over a list of chats cost a line above the first row and said nothing.
        self.assertNotIn('SectionCaption("CHATS")', ROSTER)
        self.assertNotIn('SectionCaption("GROUP CHATS")', ROSTER)
        # The divider between rooms and bots is what separates them now.
        self.assertIn("Divider().padding(.horizontal, 8).padding(.vertical, 4)", ROSTER)


class TheComposerFloats(unittest.TestCase):
    def test_no_bar_and_no_canvas_strip(self) -> None:
        # The preview keeps its own canvas; the view must not paint one.
        body = COMPOSER_BAR.split("private struct MacComposerBarPreview", 1)[0]
        self.assertNotIn(".background(Tokens.canvas)", body)
        # Floating, the field carries no rule at all: the glass's own edge is the edge.
        self.assertNotIn("floats ? Tokens.border.opacity(0.55)", COMPOSER)
        self.assertIn("floats: true", COMPOSER_BAR)

    def test_it_is_drawn_over_the_transcript(self) -> None:
        self.assertIn(".overlay(alignment: .bottom)", PANE)
        self.assertIn("MacComposerBar(model: model, store: store)", PANE)

    def test_the_transcript_fades_into_it(self) -> None:
        self.assertIn("LinearGradient(colors: [.black, .clear]", PANE)
        self.assertIn("frame(height: max(28, composerHeight))", PANE)

    def test_it_grows_upward_because_the_rows_follow_its_height(self) -> None:
        # Measured from the view, not assumed: a draft that reaches eight lines would otherwise
        # sit on top of the last message.
        self.assertIn("ComposerHeightKey", PANE)
        self.assertIn("composerHeight", PANE)
        self.assertIn("bottomInset: composerHeight", PANE)
        self.assertIn("bottomInset", TRANSCRIPT)
        self.assertIn(".padding(.bottom, 10 + bottomInset)", TRANSCRIPT)


if __name__ == "__main__":
    unittest.main()
