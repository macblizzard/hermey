"""The genui cards' wiring, pinned.

The cards are the plugin's own renderer inside a webview, and every piece of that chain can be
severed by a tidy-up that looks harmless: the bridge route stops being registered, the transcript
stops stripping the directive, the app stops handing over a resolver, the page stops sending its
height. Each of those degrades to "no card, no error", which is why they are asserted here rather
than left to a screenshot.
"""
from __future__ import annotations

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
BRIDGE_APP = (ROOT / "Bridge/hermes_bridge/app.py").read_text()
GENUI = (ROOT / "Bridge/hermes_bridge/genui.py").read_text()
HOST = (ROOT / "Bridge/hermes_bridge/genui_assets/host.html").read_text()
KIT = (ROOT / "Sources/HermesKit/GenUIBlocks.swift").read_text()
CARD = (ROOT / "Sources/OpenBotUI/GenUICard.swift").read_text()
MAC_ROW = (ROOT / "Apps/HermesMac/Conversation/TranscriptRowView.swift").read_text()
MAC_ROOT = (ROOT / "Apps/HermesMac/Workspace/WorkspaceRoot.swift").read_text()
IOS_ROW = (ROOT / "Apps/HermesMobile/Views/MobileTranscript.swift").read_text()
IOS_CHAT = (ROOT / "Apps/HermesMobile/Views/ConversationScreen.swift").read_text()
IOS_ENV = (ROOT / "Apps/HermesMobile/App/AppEnvironment.swift").read_text()


class BridgeTests(unittest.TestCase):
    def test_the_router_is_registered(self) -> None:
        self.assertIn("from .genui import create_genui_router", BRIDGE_APP)
        self.assertIn("app.include_router(create_genui_router(runtime))", BRIDGE_APP)

    def test_every_route_exists(self) -> None:
        for route in ('@router.post("/session")', '@router.get("/host")',
                      '@router.get("/assets/{name}")', '@router.get("/plugin.js")',
                      '@router.get("/blocks/{block_id}")',
                      '@router.get("/blocks/{block_id}/state")',
                      '@router.put("/blocks/{block_id}/state")'):
            self.assertIn(route, GENUI, route)

    def test_a_board_id_is_validated_before_the_disk(self) -> None:
        self.assertIn('ID_PATTERN = re.compile(r"^[0-9a-f]{8}$")', GENUI)
        # A profile name is a directory name, so a path is refused as a name.
        self.assertIn('"/" in profile', GENUI)

    def test_only_allowlisted_assets_are_served(self) -> None:
        self.assertIn("ASSETS = {", GENUI)
        for name in ('"app.mjs"', '"jsx.mjs"', '"sdk.mjs"', '"host.html"'):
            self.assertIn(name, GENUI, name)
        self.assertIn('media_type = ASSETS.get(name)', GENUI)

    def test_the_plugin_bundle_is_read_from_the_installed_plugin(self) -> None:
        # Serving a copy would freeze the cards at whatever shipped with the app.
        self.assertIn('PLUGIN_BUNDLE = ("plugins", "hermes-genui", "desktop", "plugin.js")', GENUI)

    def test_a_webview_gets_a_session_not_a_device_credential(self) -> None:
        self.assertIn("SESSION_TTL = 120.0", GENUI)
        self.assertIn("def _new_session(", GENUI)
        self.assertIn("def _session_device(", GENUI)


class PageTests(unittest.TestCase):
    def test_the_page_builds_its_import_map_with_the_session(self) -> None:
        self.assertIn('q.get("session")', HOST)
        self.assertIn('"react": "/v1/genui/assets/app.mjs" + suffix', HOST)
        self.assertIn('"react/jsx-runtime": "/v1/genui/assets/jsx.mjs" + suffix', HOST)
        self.assertIn('"@hermes/plugin-sdk": "/v1/genui/assets/sdk.mjs" + suffix', HOST)

    def test_the_page_reports_its_height_and_the_palette(self) -> None:
        self.assertIn('type: "height"', HOST)
        self.assertIn("new ResizeObserver(report)", HOST)
        for name in ('"--foreground"', '"--background"', '"--theme-primary"', '"--ui-success"'):
            self.assertIn(name, HOST, name)

    def test_a_failure_is_a_note_rather_than_a_blank_card(self) -> None:
        self.assertIn("Couldn't draw this board", HOST)


class AppTests(unittest.TestCase):
    def test_both_transcripts_draw_the_card_and_hide_the_directive(self) -> None:
        for source, name in ((MAC_ROW, "mac"), (IOS_ROW, "ios")):
            self.assertIn("GenUITag.boardID(in: entry.text)", source, name)
            self.assertIn("GenUITag.textWithoutTags(entry.text)", source, name)
            self.assertIn("GenUICard(blockID: boardID)", source, name)

    def test_both_apps_supply_a_resolver(self) -> None:
        self.assertIn(".environment(\\.genUICards, genUICards)", MAC_ROOT)
        self.assertIn(".environment(\\.genUICards, app.genUICards(for: bot.id))", IOS_CHAT)

    def test_a_card_button_goes_through_the_composer(self) -> None:
        # The same path a typed message takes: the draft, then send.
        for source, name in ((MAC_ROOT, "mac"), (IOS_CHAT, "ios")):
            self.assertIn(".genUICardSend", source, name)
            self.assertIn("model.draft = text", source, name)

    def test_the_session_is_cached_so_a_transcript_mints_one(self) -> None:
        self.assertIn("actor GenUISessionCache", KIT)
        self.assertIn("GenUISessionCache.shared.live(bot: bot)", KIT)

    def test_the_card_is_transparent_and_sized_by_the_page(self) -> None:
        self.assertIn("underPageBackgroundColor = .clear", CARD)
        self.assertIn("view.backgroundColor = .clear", CARD)
        self.assertIn("scrollView.isScrollEnabled = false", CARD)


if __name__ == "__main__":
    unittest.main()
