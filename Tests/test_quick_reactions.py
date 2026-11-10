"""Reactions belong on the surface a long press already raises — on both shells.

Mac had no emoji on the message action row (only speak, copy, reply). The phone had every verb in a
system context menu taller than the message, with the emoji behind a second menu ("Add reaction").
One list of six emojis, one row component, two shells.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ROW = (ROOT / "Sources" / "OpenBotUI" / "QuickReactionRow.swift").read_text(encoding="utf-8")
MAC = (ROOT / "Apps" / "HermesMac" / "Conversation" / "TranscriptRowView.swift").read_text(encoding="utf-8")
IOS = (ROOT / "Apps" / "HermesMobile" / "Views" / "MobileTranscript.swift").read_text(encoding="utf-8")


class QuickReactions(unittest.TestCase):
    def test_one_list_of_emojis_for_both_shells(self) -> None:
        self.assertIn('public static let basic = ["👍", "❤️", "😂", "😮", "😢", "🎉"]', ROW)
        for name, text in (("Mac", MAC), ("phone", IOS)):
            self.assertNotIn('static let emojis = [', text,
                             f"{name} must not keep a second copy of the list")

    def test_the_mac_row_has_the_button(self) -> None:
        self.assertIn('systemImage: "face.smiling"', MAC)
        self.assertIn("showingReactions = true", MAC)
        actions = MAC.split("private var messageActions", 1)[1].split("private func actionGlyph", 1)[0]
        for glyph in ('"face.smiling"', '"speaker.wave.2"', '"doc.on.doc"', '"arrowshape.turn.up.left"'):
            self.assertIn(glyph, actions, f"the action row lost {glyph}")

    def test_the_phone_long_press_carries_the_emojis(self) -> None:
        self.assertIn("QuickReactionRow(selected:", IOS)
        self.assertIn("showingActions = true", IOS)
        self.assertNotIn('Label("Add reaction"', IOS,
                         "the emoji are on the card now, not behind another menu")

    def test_the_phone_card_is_compact(self) -> None:
        card = IOS.split("private var actionCard", 1)[1].split("private func actionRow", 1)[0]
        self.assertIn(".frame(width: 232)", card)
        self.assertIn(".frame(height: 32)", card, "one row per verb, 32 pt")
        self.assertNotIn(".font(.system(size: 20)", card)
        # The system menu it replaced is gone from the two message kinds that have the card.
        for view in ("private var bubbleText", "private var assistant"):
            body = IOS.split(view, 1)[1].split("private var messageTime", 1)[0]
            self.assertNotIn("contextMenu", body, f"{view} must raise the card, not a system menu")
            self.assertIn("onLongPressGesture", body)

    def test_tool_rows_keep_their_system_menu(self) -> None:
        self.assertIn("content.contextMenu { menu }", IOS,
                      "tool and reasoning rows have no card; they keep the system menu")


if __name__ == "__main__":
    unittest.main()
