"""The workspace window must hold every pane that is open.

Opening the shared computer added a third pane to a window whose minimum was computed for two, so the
`HStack` overflowed and the shell clipped on **both** sides — the bot panel's labels on the left and
the computer pane's buttons on the right. These guards keep the window minimum, the pane floors and
the fitting helper pointing at one set of numbers (`WindowLayout`).
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAC = ROOT / "Apps" / "HermesMac"
LAYOUT = (ROOT / "Sources" / "HermesAppKit" / "WindowLayout.swift").read_text(encoding="utf-8")
TOKENS = (ROOT / "Sources" / "OpenBotUI" / "Tokens.swift").read_text(encoding="utf-8")


class WindowLayoutGuards(unittest.TestCase):
    def setUp(self) -> None:
        self.root = (MAC / "Workspace" / "WorkspaceRoot.swift").read_text(encoding="utf-8")
        self.app = (MAC / "HermesMacApp.swift").read_text(encoding="utf-8")
        self.store = (MAC / "Workspace" / "WorkspaceStore.swift").read_text(encoding="utf-8")
        self.fitter = (MAC / "Workspace" / "WindowWidthFitter.swift").read_text(encoding="utf-8")

    def test_the_apps_minimum_is_the_arrangements(self) -> None:
        self.assertIn("minWidth: store.minimumWindowWidth", self.app,
                      "a hardcoded two-pane sum is what clipped the third pane")
        self.assertIn("var minimumWindowWidth", self.store)
        # One trailing slot: the computer takes the bot panel's place, so the two are never both
        # counted — only the computer's wider floor is added (2026-11-14).
        self.assertIn("panelOpen: false", self.store)
        self.assertIn("botPanelOpen: isBotPanelPresented || isComputerPanelPresented", self.store)
        self.assertIn("WindowLayout.computerMin - WindowLayout.botPanelWidth", self.store)

    def test_the_computer_pane_holds_the_panel_slot(self) -> None:
        # It used to be a third pane with its own floors and ceiling, then briefly the sidebar's.
        # It now takes the bot panel's slot, so its width is the panel's with a computer's floor.
        self.assertNotIn(".frame(width: 520)", self.root,
                         "a fixed pane width cannot give way in a narrow window")
        self.assertIn(".frame(width: max(WindowLayout.botPanelWidth, WindowLayout.computerMin))",
                      self.root)
        self.assertEqual(self.root.count("computerPane(fullScreen: false)"), 1,
                         "one slot: drawing it twice is what put it on the wrong edge")

    def test_the_conversation_hands_width_back_while_the_panel_is_open(self) -> None:
        self.assertIn("WindowLayout.conversationMinWithComputer", self.root)

    def test_the_window_grows_instead_of_clipping(self) -> None:
        self.assertIn("WindowWidthFitter(minimum: store.minimumWindowWidth)", self.root)
        self.assertIn("setFrame", self.fitter)
        self.assertIn("visibleFrame", self.fitter, "never grow past the screen's visible frame")

    def test_the_shared_tokens_do_not_drift(self) -> None:
        conversation = re.search(r"conversationMin: CGFloat = ([0-9.]+)", TOKENS)
        layout_value = re.search(r"conversationMin: CGFloat = ([0-9.]+)", LAYOUT)
        self.assertTrue(conversation and layout_value, "both files still name the conversation's floor")
        assert conversation is not None and layout_value is not None
        self.assertEqual(conversation.group(1), layout_value.group(1),
                         "OpenBotUI and WindowLayout must agree on the conversation's floor")

        # The Mac shell aliases the floor rather than restating it, so a dragged panel cannot drift.
        self.assertIn("static let sidebarFloor: CGFloat = WindowLayout.sidebarFloor", self.store)

    def test_the_three_pane_minimum_fits_the_smallest_supported_display(self) -> None:
        values = {name: float(value) for name, value in
                  re.findall(r"static let (\w+): CGFloat = ([0-9.]+)", LAYOUT)}
        three = (values["surround"] * 2 + values["sidebarFloor"] + values["divider"]
                 + values["hairline"] + values["conversationMinWithComputer"]
                 + values["hairline"] + values["computerMin"])
        self.assertLessEqual(three, 1024, "three panes must fit a 1024 pt display")
        self.assertLess(values["conversationMinWithComputer"], values["conversationMin"])


if __name__ == "__main__":
    unittest.main()
