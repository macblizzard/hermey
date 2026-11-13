"""A verb has one door. The computer's is the bot panel's first row, and only that."""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HEADER = (ROOT / "Apps" / "HermesMac" / "Conversation" / "ConversationHeader.swift").read_text(encoding="utf-8")
PANEL = (ROOT / "Apps" / "HermesMac" / "Workspace" / "MacBotPanel.swift").read_text(encoding="utf-8")


class NoDuplicateVerbs(unittest.TestCase):
    def test_the_computer_is_reached_from_the_panels_row_only(self) -> None:
        # One door. The header's own display button went with the header bar, so the panel's first
        # row is the only thing that toggles the shared computer.
        self.assertIn('row("Computer", icon: "display"', PANEL)
        self.assertIn("store.toggleComputerPanel()", PANEL)
        self.assertEqual(PANEL.count("toggleComputerPanel()"), 1)
        self.assertNotIn('OpenBotIconButton("display"', HEADER)
        self.assertNotIn("Bot computer…", PANEL)


if __name__ == "__main__":
    unittest.main()
