"""Desktop controls answer on hover.

A glyph in a toolbar is a question. The answer was already written down — every icon button carries a
`label` for VoiceOver and every action glyph a `help:` argument — but nothing showed it, so the
knowledge lived only in the accessibility tree. On the desktop it now costs one `.help(...)`.

The emoji picker is part of this: six bare emoji with no names are the same question, and the popover
used to hand keyboard focus to the first one, drawing a square selection ring around 👍.
"""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAC = ROOT / "Apps" / "HermesMac"
CONTROLS = (ROOT / "Sources" / "OpenBotUI" / "Controls.swift").read_text(encoding="utf-8")
ROW = (ROOT / "Sources" / "OpenBotUI" / "QuickReactionRow.swift").read_text(encoding="utf-8")


def source(relative: str) -> str:
    return (MAC / relative).read_text(encoding="utf-8")


class SharedControlsCarryTooltips(unittest.TestCase):
    def test_every_icon_button_takes_its_label_as_its_tooltip(self) -> None:
        icon = CONTROLS.split("public struct OpenBotIconButton", 1)[1]
        self.assertIn(".help(label)", icon,
                      "the label is already written for VoiceOver; a glyph should say it on hover")

    def test_the_tooltip_is_macos_only(self) -> None:
        icon = CONTROLS.split("public struct OpenBotIconButton", 1)[1]
        block = icon.split("#if os(macOS)", 1)
        self.assertEqual(len(block), 2, "iOS has no hover, so the modifier is compiled out there")
        self.assertIn(".help(label)", block[1].split("#endif", 1)[0])


class MessageControls(unittest.TestCase):
    def test_the_action_glyphs_use_the_help_they_were_passed(self) -> None:
        text = source("Conversation/TranscriptRowView.swift")
        glyph = text.split("private func actionGlyph", 1)[1].split("// MARK:", 1)[0]
        self.assertIn(".help(help)", glyph,
                      "actionGlyph took `help:` and never showed it — speak/copy/reply silently unnamed")
        self.assertEqual(glyph.count(".help(help)"), 1, "a doubled modifier is a merge artefact")

    def test_read_aloud_and_the_reaction_chip_are_named(self) -> None:
        text = source("Conversation/TranscriptRowView.swift")
        self.assertIn('.help(isSpeaking ? "Stop reading this message" : "Read this message aloud")', text)
        self.assertIn('.help("Remove your \\(ReactionEmoji.name(emoji)) reaction")', text)


class ComposerAndScroller(unittest.TestCase):
    def test_composer_chips_explain_their_x(self) -> None:
        text = source("Conversation/MacComposerBar.swift")
        for help in ('help("Dismiss this notice")', 'help("Cancel this reply")',
                     'help("Remove \\(attachment.name)")'):
            self.assertIn(help, text)

    def test_the_way_back_down_is_named_once(self) -> None:
        text = source("Conversation/TranscriptScroll.swift")
        self.assertIn('.help("Scroll to latest message")', text)
        self.assertEqual(text.count('.help("Scroll to latest message")'), 1)


class TheEmojiPicker(unittest.TestCase):
    def test_no_focus_ring_on_the_first_emoji(self) -> None:
        self.assertIn(".focusEffectDisabled()", ROW)
        self.assertIn(".focusable(false)", ROW)

    def test_each_emoji_has_a_name(self) -> None:
        self.assertIn(".help(ReactionEmoji.name(emoji))", ROW)
        for name in ("Thumbs Up", "Heart", "Laughing", "Surprised", "Sad", "Celebrate"):
            self.assertIn(f'return "{name}"', ROW)

    def test_the_picker_hangs_off_the_smiley_not_the_row(self) -> None:
        text = source("Conversation/TranscriptRowView.swift")
        self.assertIn("attachmentAnchor: .rect(.bounds)", text)
        self.assertIn("arrowEdge: .bottom", text)
        # The popover must be attached where the reaction glyph is built, not to the row's VStack.
        glyph = text.split('actionGlyph("react"', 1)[1]
        self.assertIn(".popover(isPresented: $showingReactions", glyph.split("actionGlyph(", 1)[0])


if __name__ == "__main__":
    unittest.main()
