"""A verb the toolbar already offers does not belong in the menu beside it."""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HEADER = (ROOT / "Apps" / "HermesMac" / "Conversation" / "ConversationHeader.swift").read_text(encoding="utf-8")


class NoDuplicateVerbs(unittest.TestCase):
    def test_the_computer_is_reached_from_its_button_only(self) -> None:
        menu = HEADER.split("private var moreMenu: some View", 1)[1]
        self.assertNotIn('Button("Bot computer…")', menu,
                         "the header already draws a display button for this")
        self.assertIn('OpenBotIconButton("display"', HEADER,
                      "the button has to still be there if the menu item is gone")


if __name__ == "__main__":
    unittest.main()
