"""Escape, the computer's slot, and deleting a bot from its own settings.

Three requests from 2026-11-14, each with one rule worth keeping:

* Escape had no owner outside the palette — the panes are not modal — and the key has to stop at a
  text field, or the composer changes behaviour depending on which panel is open.
* The shared computer was a third pane with the window grown to fit it, which squeezed the
  transcript; it now takes the sidebar's slot on the leading edge.
* Deleting a bot lived only under Manage bots, a list of switches — a place you go to hide a row.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAC = ROOT / "Apps" / "HermesMac"
STORE = (MAC / "Workspace" / "WorkspaceStore.swift").read_text(encoding="utf-8")
ROOT_VIEW = (MAC / "Workspace" / "WorkspaceRoot.swift").read_text(encoding="utf-8")
CATCHER = (MAC / "Support" / "EscapeKeyCatcher.swift").read_text(encoding="utf-8")
MAC_SETTINGS = (MAC / "Views" / "MacBotSettingsSheet.swift").read_text(encoding="utf-8")
IOS_SETTINGS = (ROOT / "Apps/HermesMobile/Views/BotModelSettingsScreen.swift").read_text(encoding="utf-8")
IOS_LIST = (ROOT / "Apps/HermesMobile/Views/BotListScreen.swift").read_text(encoding="utf-8")
IOS_CHAT = (ROOT / "Apps/HermesMobile/Views/ConversationScreen.swift").read_text(encoding="utf-8")
GALLERY = (ROOT / "Sources/OpenBotUI/BotIconGallery.swift").read_text(encoding="utf-8")


class EscapeClosesTheTopmostThing(unittest.TestCase):
    def test_the_order_is_the_reverse_of_opening(self) -> None:
        body = STORE.split("func closeTopmostOnEscape()", 1)[1].split("\n    }", 1)[0]
        order = [body.index(token) for token in
                 ("isPalettePresented", "isComputerFullScreen", "isComputerPanelPresented",
                  "isBotPanelPresented", "isSidebarHidden")]
        self.assertEqual(order, sorted(order),
                         "the full-screen computer outranks a pane, which outranks the sidebar")
        self.assertIn("else { return false }", body, "nothing left to close means the key passes on")

    def test_the_shell_installs_the_catcher(self) -> None:
        self.assertIn("EscapeKeyCatcher { store.closeTopmostOnEscape() }", ROOT_VIEW)

    def test_a_field_keeps_escape_for_itself(self) -> None:
        # The field editor is an NSTextView and is the first responder for every text field in the
        # app: without this guard, Escape would close a panel instead of clearing a search.
        self.assertIn("NSApp.keyWindow?.firstResponder is NSTextView", CATCHER)
        self.assertIn("event.keyCode == 53", CATCHER)

    def test_a_sheet_keeps_its_own_escape(self) -> None:
        self.assertIn("attachedSheet != nil", CATCHER)


class TheComputerTakesTheSidebarsPlace(unittest.TestCase):
    def test_it_sits_on_the_leading_edge(self) -> None:
        leading = ROOT_VIEW.split("if store.isComputerPanelPresented", 1)[1]
        self.assertIn("computerPane(fullScreen: false)", leading)

    def test_the_sidebar_comes_back_exactly_as_it_was(self) -> None:
        # The slot is chosen by the computer's flag; `isSidebarHidden` is left alone, so the width
        # and the collapsed state survive the visit.
        block = ROOT_VIEW.split("if store.isComputerPanelPresented", 1)[1].split("Group {", 1)[0]
        self.assertNotIn("isSidebarHidden =", block)
        self.assertIn("} else if !store.isSidebarHidden {", block)

    def test_full_screen_is_still_an_overlay(self) -> None:
        self.assertIn("if store.isComputerPanelPresented, store.isComputerFullScreen {", ROOT_VIEW)


class ABotCanBeDeletedFromItsSettings(unittest.TestCase):
    def test_the_phone_offers_it_and_confirms(self) -> None:
        self.assertIn("var deleteBot: (() async throws -> Void)? = nil", IOS_SETTINGS)
        self.assertIn("private var dangerSection", IOS_SETTINGS)
        self.assertIn("showingDelete", IOS_SETTINGS)
        self.assertIn('Button("Delete bot", role: .destructive)', IOS_SETTINGS)
        # It has to be reachable from both doors into the sheet.
        self.assertIn("deleteBot: { try await model.deleteBot(bot.id) })", IOS_LIST)
        self.assertIn("deleteBot: { try await model.deleteBot(bot.id) })", IOS_CHAT)

    def test_the_mac_offers_it_and_confirms(self) -> None:
        self.assertIn("private var dangerSection", MAC_SETTINGS)
        self.assertIn('Button("Delete bot", role: .destructive)', MAC_SETTINGS)
        self.assertIn("try await model.deleteBot(bot.id)", MAC_SETTINGS)

    def test_it_is_a_confirmed_one_way_verb(self) -> None:
        for source in (IOS_SETTINGS, MAC_SETTINGS):
            self.assertIn("This cannot be undone from the app.", source)


class TheFaceGalleryDropsTheInitialsRow(unittest.TestCase):
    def test_there_is_no_initials_option(self) -> None:
        # "Use its initials instead" sat under the shape grid and asked the user to opt out of the
        # thing the screen exists for (requested 2026-11-14).
        self.assertNotIn("Use its initials instead", GALLERY)


if __name__ == "__main__":
    unittest.main()
