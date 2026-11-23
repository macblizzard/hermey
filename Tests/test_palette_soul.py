"""⌘K must be able to open a bot's SOUL editor.

The editor existed, reachable only by opening bot settings and finding the tab. The owner asked for it
from the palette, which is one verb and one sheet — the same shape as Notes, Model and Routines.

These pins keep the three links honest: the store carries the route, the palette sets it, and the sheet
saves *to the host* rather than pretending locally.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STORE = (ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceStore.swift").read_text(encoding="utf-8")
ROOT_VIEW = (ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceRoot.swift").read_text(encoding="utf-8")


class TheRouteExists(unittest.TestCase):
    def test_the_store_holds_a_soul_route(self) -> None:
        self.assertIn("@Published var soulBot: Bot?", STORE)

    def test_the_root_presents_it(self) -> None:
        self.assertIn("case soul(Bot)", ROOT_VIEW)
        self.assertIn('return "soul:\\(bot.id)"', ROOT_VIEW)
        self.assertIn("if let bot = store.soulBot { return .soul(bot) }", ROOT_VIEW)
        # One sheet modifier only: dismissing must clear every flag, this one included.
        self.assertIn("store.soulBot = nil", ROOT_VIEW)


class TheSheetIsTheRealEditor(unittest.TestCase):
    def test_it_loads_and_saves_through_the_host(self) -> None:
        # A palette door that opened a local-only editor would look identical until the bot restarted.
        self.assertIn("SoulEditorSheet(", ROOT_VIEW)
        self.assertIn("describeBot(bot.id).soul", ROOT_VIEW)
        self.assertIn("saveSoul($0, for: bot.id)", ROOT_VIEW)


class ThePaletteVerb(unittest.TestCase):
    def test_the_verb_is_registered_and_gated(self) -> None:
        self.assertIn('id: "bot.soul"', STORE)
        self.assertIn('title: "Edit this bot\'s soul"', STORE)
        body = STORE[STORE.index('id: "bot.soul"'):]
        body = body[: body.index("items.append")]
        self.assertIn("isEnabled: model.selectedBot != nil", body)
        self.assertIn("self.soulBot = bot", body)
        # The palette closes behind the sheet, like every other verb that presents one.
        self.assertIn("self.closePalette()", body)

    def test_it_does_not_duplicate_the_settings_sheet(self) -> None:
        body = STORE[STORE.index('id: "bot.soul"'):]
        body = body[: body.index("items.append")]
        self.assertNotIn("botSettingsBot", body, "the palette opens the editor, not the settings sheet")


if __name__ == "__main__":
    unittest.main()
