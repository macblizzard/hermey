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

GALLERY = (ROOT / "Sources" / "OpenBotUI" / "BotIconGallery.swift").read_text(encoding="utf-8")
HEADER = (ROOT / "Apps" / "HermesMac" / "Conversation" / "ConversationHeader.swift").read_text(encoding="utf-8")
PANE = (ROOT / "Apps" / "HermesMac" / "Conversation" / "ConversationPane.swift").read_text(encoding="utf-8")
COMPOSER_BAR = (ROOT / "Apps" / "HermesMac" / "Conversation" / "MacComposerBar.swift").read_text(encoding="utf-8")
COMPOSER = (ROOT / "Sources" / "OpenBotUI" / "Composer.swift").read_text(encoding="utf-8")
TRANSCRIPT = (ROOT / "Apps" / "HermesMac" / "Conversation" / "TranscriptScroll.swift").read_text(encoding="utf-8")
SIDEBAR = (ROOT / "Apps" / "HermesMac" / "Sidebar" / "BotSidebarView.swift").read_text(encoding="utf-8")
ROSTER = (ROOT / "Apps" / "HermesMac" / "Sidebar" / "SidebarBotList.swift").read_text(encoding="utf-8")


class TheFaceSaysWhatItIsDoing(unittest.TestCase):
    def test_three_states_and_three_animations(self) -> None:
        self.assertIn("public enum PortraitStatus", GALLERY)
        for case in ("case needsYou", "case working", "case compacting"):
            self.assertIn(case, GALLERY)

    def test_each_state_draws_something_that_moves(self) -> None:
        # A flashing mark, sparks that travel, a seam that closes. Each is a view of its own so a
        # caller cannot get a static badge by forgetting a flag.
        self.assertIn("NeedsYouFlash", GALLERY)
        self.assertIn("CompactingZip", GALLERY)
        self.assertIn("BotWorkingSparks(size: size, color: tint, isWorking: true)", GALLERY)
        # Reduce Motion gets the mark without the movement, never nothing.
        self.assertIn("accessibilityReduceMotion", GALLERY)
        flash = GALLERY.split("public struct NeedsYouFlash", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("reduceMotion ? 1.0", flash)
        zip_view = GALLERY.split("public struct CompactingZip", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("guard !reduceMotion else", zip_view)

    def test_a_request_outranks_a_turn_and_both_outrank_a_compaction(self) -> None:
        block = HEADER.split("private var portraitStatus", 1)[1].split("\n    }", 1)[0]
        order = [block.index(".needsYou"), block.index(".compacting"), block.index(".working")]
        self.assertEqual(order, sorted(order), "the state that needs a person wins the face")


class TheSidebarRowIsOneCluster(unittest.TestCase):
    def test_every_control_is_on_the_right(self) -> None:
        row = SIDEBAR.split("private var header: some View", 1)[1].split("private var closeSearch", 1)[0]
        # The spacer comes first: nothing is drawn on the leading edge at all.
        self.assertLess(row.index("Spacer(minLength: 0)"),
                        row.index('OpenBotIconButton("magnifyingglass"'))
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
        # Floating, the field carries a hairline of its own rather than nothing: a material with no
        # edge at all dissolves into a dark canvas and reads as a smudge.
        self.assertIn("floats ? Tokens.border.opacity(0.55)", COMPOSER)
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
