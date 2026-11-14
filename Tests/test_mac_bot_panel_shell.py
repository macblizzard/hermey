"""The Mac shell, Rakazo's way: no frame, and the name in the header is the control.

Three things are being pinned here, and each one is a shape rather than a pixel count:

* the window runs edge to edge — no surround, no stroked border around the shell;
* the header is one pill at the centre of the pane, and the pill itself opens the bot's panel;
* the panel is a pane, not a sheet: it counts towards the window's minimum, and Escape puts it away.
"""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAC = ROOT / "Apps" / "HermesMac"

HEADER = (MAC / "Conversation" / "ConversationHeader.swift").read_text(encoding="utf-8")
PANEL = (MAC / "Workspace" / "MacBotPanel.swift").read_text(encoding="utf-8")
ROOTVIEW = (MAC / "Workspace" / "WorkspaceRoot.swift").read_text(encoding="utf-8")
STORE = (MAC / "Workspace" / "WorkspaceStore.swift").read_text(encoding="utf-8")
LAYOUT = (ROOT / "Sources" / "HermesAppKit" / "WindowLayout.swift").read_text(encoding="utf-8")


class TheWindowIsEdgeToEdge(unittest.TestCase):
    def test_the_shell_has_no_surround_and_no_drawn_border(self) -> None:
        # Rakazo has no frame inside the window: the sidebar's fill runs out to the window's own
        # rounded corners. A surround plus a stroked border reads as a window inside a window.
        self.assertNotIn(".padding(.horizontal, 8)", ROOTVIEW)
        self.assertNotIn(".padding(.bottom, 8)", ROOTVIEW)
        # One stroked border is left in the file and it is the command palette's own; the shell
        # itself wears none.
        self.assertEqual(ROOTVIEW.count("strokeBorder(Tokens.borderStrong"), 1)
        self.assertIn("CommandPaletteView", ROOTVIEW)

    def test_the_minimum_width_does_not_reserve_a_surround(self) -> None:
        self.assertIn("public static let surround: CGFloat = 0", LAYOUT)


class TheNameIsTheControl(unittest.TestCase):
    def test_the_panel_is_about_one_bot_and_not_the_app(self) -> None:
        # The palette is ⌘K everywhere and Settings is the app's own scene: neither belongs inside
        # a panel about this bot, and the two rows read as doors to somewhere else.
        self.assertNotIn('row("Command palette"', PANEL)
        self.assertNotIn('row("Settings"', PANEL)
        self.assertNotIn('detail: "⌘', PANEL)

    def test_the_pill_opens_the_panel(self) -> None:
        self.assertIn("botPanelButton", HEADER)
        self.assertIn("store.toggleBotPanel()", HEADER)
        # The dots are inside the capsule, beside the name — not a toolbar button at the far right.
        pill = HEADER.split("private func pill(width: CGFloat)", 1)[1]
        # The capsule is the door; the ⋯ was a second, smaller door drawn on the first one.
        self.assertNotIn('systemName: "ellipsis"', pill)
        self.assertIn("contentShape(Capsule())", pill)

    def test_the_header_keeps_no_dropdown_of_its_own(self) -> None:
        # One door. The verbs are rows in the panel; a second menu beside the pill would be the
        # toolbar this shape replaces.
        self.assertNotIn("moreMenu", HEADER)
        self.assertNotIn("Menu {", HEADER)

    def test_the_state_is_on_the_face_not_in_a_chip(self) -> None:
        self.assertIn("ZStack {", HEADER)
        self.assertNotIn("contextChipLabel", HEADER)
        # A chip is a word you read; the face is a thing you notice. All three states live there.
        self.assertIn("portraitStatus", HEADER)
        for state in (".needsYou", ".working", ".compacting"):
            self.assertIn(f"return {state}", HEADER)
        for chip in ('StatusChip("running"', 'StatusChip("needs you"', 'StatusChip("compacting'):
            self.assertNotIn(chip, HEADER)
        # The result of a compaction is still a sentence: it has no shape to take.
        self.assertIn("model.compactionNotice", HEADER)


class ThePanelIsAPane(unittest.TestCase):
    def test_it_sits_in_the_trailing_slot(self) -> None:
        self.assertIn("if store.isBotPanelPresented {", ROOTVIEW)
        self.assertIn("MacBotPanel(model: model, store: store)", ROOTVIEW)
        self.assertIn(".transition(.move(edge: .trailing))", ROOTVIEW)

    def test_it_carries_the_same_verbs_as_the_phone(self) -> None:
        for verb in ("Computer", "Library", "Skills", "MCP", "Routines",
                     "Search conversations", "Bot settings",
                     "Mark all as read", "Reset conversation"):
            self.assertIn(f'row("{verb}"', PANEL, f"the panel is missing {verb}")
        # The compaction row relabels itself while it runs, so it is matched by its words.
        self.assertIn('"Compact conversation"', PANEL)
        self.assertIn("model.compressNow()", PANEL)
        # The phone's drawer closes on reset; here the reset dialog is the store's one confirmation.
        self.assertIn("store.isResetConfirmationPresented = true", PANEL)

    def test_the_window_grows_for_it_instead_of_clipping(self) -> None:
        self.assertIn("botPanelOpen: isBotPanelPresented", STORE)
        self.assertIn("if botPanelOpen {", LAYOUT)
        self.assertIn("hairline + botPanelWidth", LAYOUT)

    def test_escape_and_the_close_button_put_it_away(self) -> None:
        self.assertIn(".onExitCommand { close() }", PANEL)
        self.assertIn("keyboardShortcut(.escape, modifiers: [])", PANEL)
        self.assertIn('OpenBotIconButton("xmark"', PANEL)

    def test_it_is_not_modal(self) -> None:
        # A sheet would stop the transcript behind it; the whole point is watching a compaction
        # report into the panel while the chat keeps moving.
        self.assertNotIn(".sheet(", PANEL)
        self.assertIn(".background(Tokens.sheet)", PANEL)


if __name__ == "__main__":
    unittest.main()
