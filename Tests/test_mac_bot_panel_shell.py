"""The Mac shell, the house style: no frame, and the name in the header is the control.

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
APP = (MAC / "HermesMacApp.swift").read_text(encoding="utf-8")
ROW_MENU = (MAC / "Sidebar" / "BotRowMenu.swift").read_text(encoding="utf-8")
BOT_LIST = (MAC / "Sidebar" / "SidebarBotList.swift").read_text(encoding="utf-8")
CATCHER = (MAC / "Support" / "OutsideClickCatcher.swift").read_text(encoding="utf-8")
LAYOUT = (ROOT / "Sources" / "HermesAppKit" / "WindowLayout.swift").read_text(encoding="utf-8")


class TheWindowIsEdgeToEdge(unittest.TestCase):
    def test_the_shell_has_no_surround_and_no_drawn_border(self) -> None:
        # Midnight has no frame inside the window: the sidebar's fill runs out to the window's own
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
        pill = HEADER.split("private func pill(width: CGFloat)", 1)[1].split("// MARK: - Previews", 1)[0]
        # The capsule is the door; the ⋯ was a second, smaller door drawn on the first one.
        self.assertNotIn('systemName: "ellipsis"', pill)
        # The hit shape is the capsule's *rectangle*: the rounded ends used to be dead to the
        # pointer, so aiming at the corner of the shape everyone sees did nothing
        # (reported 2026-11-15 as "the pill is hit and miss").
        self.assertIn("contentShape(Rectangle())", pill)
        self.assertNotIn("contentShape(Capsule())", pill)
        # And nothing rescales the control on hover: a spring changed the hit geometry while the
        # pointer was still arriving, which is the other half of a click that does nothing.
        self.assertNotIn("scaleEffect(", pill)

    def test_the_pill_has_a_keyboard_door(self) -> None:
        # ⌘E is the pill's key: it opens the bot's panel on the right edge — the same panel the
        # pill opens with the pointer, which is where this shell keeps a bot's verbs.
        #
        # Build 445 pointed the key at a per-row overflow popover instead: a second menu drawn over
        # the transcript for a job the panel already does, so "⌘E" read as settings rather than as
        # the panel (reported 2026-11-15). The key, the popover and the router state behind them are
        # gone; the panel and ⌘E share one owner.
        self.assertIn('.keyboardShortcut("e", modifiers: .command)', APP)
        self.assertIn("store.toggleBotPanel()", APP)
        # The pill and the key must land on the same method, or the two doors can disagree.
        self.assertIn("store.toggleBotPanel()", HEADER)
        self.assertNotIn("BotMenuRouter.shared.toggle", APP)
        self.assertNotIn("BotMenuRouter.shared.toggle", BOT_LIST)
        # The row's menu is a native `Menu` again: the popover it replaced went with the key.
        self.assertNotIn("BotOverflowPanel", BOT_LIST)
        self.assertNotIn("BotOverflowPanel", ROW_MENU)
        self.assertNotIn(".popover(", BOT_LIST)

    def test_one_piece_of_state_owns_the_panel(self) -> None:
        # One property, one toggle, and two scoped closers that write the same property — not a
        # second "is it open" flag for the pill, the key and the mouse to disagree about.
        self.assertIn("func toggleBotPanel()", STORE)
        self.assertIn("func dismissBotPanelFromOutsideClick()", STORE)
        self.assertIn("func closeBotPanel()", STORE)
        # Nothing outside the store assigns it: no view keeps its own copy of "is it open".
        for source in (APP, PANEL, HEADER, ROOTVIEW, BOT_LIST):
            self.assertNotIn("isBotPanelPresented =", source, "the panel has one owner")
            self.assertNotIn("isBotPanelPresented.toggle()", source, "the panel has one toggle")

    def test_a_click_outside_puts_it_away_without_eating_the_click(self) -> None:
        # The panel is a pane, not a popover: SwiftUI dismisses a popover for you, and a pane it
        # does not. A tap-catching backdrop would have closed it and swallowed the click, which
        # breaks the transcript the panel is meant to sit beside — so the catcher watches the
        # mouse-down and hands the event back either way.
        self.assertIn("OutsideClickCatcher", PANEL)
        self.assertIn("store.dismissBotPanelFromOutsideClick()", PANEL)
        self.assertIn("NSEvent.addLocalMonitorForEvents", CATCHER)
        self.assertIn("return event", CATCHER)
        # A click in a sheet or another window belongs to that window, not to "outside the panel".
        self.assertIn("event.window === window", CATCHER)

    def test_the_header_keeps_no_dropdown_of_its_own(self) -> None:
        # One door. The verbs are rows in the panel; a second menu beside the pill would be the
        # toolbar this shape replaces.
        self.assertNotIn("moreMenu", HEADER)
        self.assertNotIn("Menu {", HEADER)

    def test_the_state_is_on_the_face_not_in_a_chip(self) -> None:
        self.assertIn("ZStack {", HEADER)
        self.assertNotIn("contextChipLabel", HEADER)
        # A chip is a word you read; the face is a thing you notice. The pill wears the activity the
        # tracker reduced, so the header and the roster cannot say different things about one bot.
        self.assertIn("store.activity(for: bot.id)", HEADER)
        self.assertIn("BotAvatarView(identity: bot.id", HEADER)
        # No per-view precedence left: the old `portraitStatus` ladder was a second copy of the rules.
        self.assertNotIn("portraitStatus", HEADER)
        for chip in ('StatusChip("running"', 'StatusChip("needs you"', 'StatusChip("compacting'):
            self.assertNotIn(chip, HEADER)
        # The result of a compaction is still a sentence: it has no shape to take.
        self.assertIn("model.compactionNotice", HEADER)


class ThePanelIsAPane(unittest.TestCase):
    def test_the_panel_starts_below_the_window_edge(self) -> None:
        # The bot's face opened flush against the frame; the column now starts on its own inset
        # (asked for 2026-11-15). The value lives with the other header geometry, not inline.
        self.assertIn("Geometry.botPanelTopInset", PANEL)
        tokens = (ROOT / "Sources" / "HermeyUI" / "Tokens.swift").read_text(encoding="utf-8")
        self.assertIn("public static let botPanelTopInset: CGFloat = 30", tokens)

    def test_it_sits_in_the_trailing_slot(self) -> None:
        self.assertIn("if store.isBotPanelPresented {", ROOTVIEW)
        self.assertIn("MacBotPanel(model: model, store: store)", ROOTVIEW)
        self.assertIn(".transition(.move(edge: .trailing))", ROOTVIEW)

    def test_it_carries_the_same_verbs_as_the_phone(self) -> None:
        # "Bot settings" is the header's Edit button now, and "Reset conversation" is the phone's
        # "Reset chat": one vocabulary across the two shells.
        for verb in ("Computer", "Model", "Library", "Skills", "MCP", "Routines",
                     "Search this conversation", "Mark all as read", "Reset chat"):
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
        self.assertIn('HermeyIconButton("xmark"', PANEL)

    def test_it_is_not_modal(self) -> None:
        # A sheet would stop the transcript behind it; the whole point is watching a compaction
        # report into the panel while the chat keeps moving.
        self.assertNotIn(".sheet(", PANEL)
        self.assertIn(".background(Tokens.sheet)", PANEL)


if __name__ == "__main__":
    unittest.main()
