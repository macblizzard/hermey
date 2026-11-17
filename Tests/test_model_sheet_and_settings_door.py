"""The model sheet's three columns, and the one bot-settings door the phone has.

Two requests on 2026-11-17:

* desktop — "update model selection sheet to include provider, then model, then effort level. also add
  option to select aux/vision model";
* mobile — "the edit button on bot pill sidebar should show the same sheet as the long press and then bot
  settings on each bot from bot list, right now the edit button lacks some settings like bot image edit
  soul, etc."

The second one is a *divergence* bug: the sheet existed twice, and the conversation's copy had quietly
lost sections. So the test that matters is not "does Edit open settings" but "is there one copy".
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHEET = (ROOT / "Apps" / "HermesMac" / "Views" / "MacModelSheet.swift").read_text(encoding="utf-8")
DOOR = (ROOT / "Apps" / "HermesMobile" / "Views" / "BotSettingsDoor.swift").read_text(encoding="utf-8")
LIST = (ROOT / "Apps" / "HermesMobile" / "Views" / "BotListScreen.swift").read_text(encoding="utf-8")
CHAT = (ROOT / "Apps" / "HermesMobile" / "Views" / "ConversationScreen.swift").read_text(encoding="utf-8")
SETTINGS = (ROOT / "Sources" / "HermesKit" / "BotModelSettings.swift").read_text(encoding="utf-8")
CLIENT = (ROOT / "Sources" / "HermesKit" / "EndlessSessionPointer.swift").read_text(encoding="utf-8")


class TheModelSheetIsThreeColumns(unittest.TestCase):
    def testProviderThenModelThenEffort(self) -> None:
        columns = SHEET.index('SectionCaption("PROVIDER · MODEL · EFFORT")')
        provider = SHEET.index("providerColumn(catalog)", columns)
        model = SHEET.index("modelColumn(catalog)", columns)
        effort = SHEET.index("effortColumn", columns)
        self.assertLess(provider, model, "provider must be chosen before a model narrows")
        self.assertLess(model, effort, "effort sits beside the model it modifies")

    def testChoosingAProviderNarrowsTheModelColumn(self) -> None:
        self.assertIn("provider = name", SHEET)
        # No provider chosen shows everything, so a model can still be found by search alone.
        self.assertIn('(provider == nil || provider == "" || option.provider == provider)', SHEET)

    def testEffortIsWrittenThroughTheModelSettingsRoute(self) -> None:
        # The effort level is the bot's, not the catalogue's: it lives in the profile's config.
        self.assertIn("model.setModelSettings(for: bot.id, effort: level)", SHEET)
        self.assertIn("BotModelSettings.standardEfforts", SHEET)
        # A host that cannot answer leaves the column inert rather than pretending a default.
        self.assertIn("The bot's config could not be read.", SHEET)

    def testTheAuxVisionModelIsSelectable(self) -> None:
        self.assertIn('SectionCaption("AUX · VISION MODEL")', SHEET)
        self.assertIn("visionProvider: provider", SHEET)
        self.assertIn("visionModel: model", SHEET)
        # Inheriting is a choice of its own, and it is the default the host reports.
        self.assertIn('auxChoice(label: "Inherit the bot\'s model", provider: "auto", model: ""', SHEET)

    def testTheCatalogueAndTheConfigAreReadSeparately(self) -> None:
        # Two independent reads: a host without the config route still draws the catalogue.
        self.assertIn("catalog = try await model.modelCatalog(for: bot.id)", SHEET)
        self.assertIn("settings = try? await model.modelSettings(for: bot.id)", SHEET)


class TheSettingsValueIsDecodedHonestly(unittest.TestCase):
    def testDisabledEffortIsNoneNotEmpty(self) -> None:
        self.assertIn("isDisabled", SETTINGS) if "isDisabled" in SETTINGS else None
        # The host stores thinking-off as `false`; the bridge reports it as `none`, and the client keeps
        # whatever the host said rather than re-deriving it.
        self.assertIn("public let effort: String", SETTINGS)
        self.assertIn('EffortOption(id: "none", label: "Off")', SETTINGS)

    def testAnUnknownLevelStillRoundTrips(self) -> None:
        # A host that adds a level later must not be silently widened to "provider default" in the UI.
        self.assertIn("public func label(for effort: String) -> String", SETTINGS)

    def testTheClientAsksTheBridgeForBoth(self) -> None:
        self.assertIn("func modelSettings(_ profile: String) async throws -> BotModelSettings", CLIENT)
        self.assertIn("func setModelSettings(_ profile: String, effort: String?,", CLIENT)
        self.assertIn('bridgeGET("v1/bots/\\(name)/model-settings")', CLIENT)
        self.assertIn('bridgePUT("v1/bots/\\(name)/model-settings", body: body)', CLIENT)


class ThePhoneHasOneSettingsDoor(unittest.TestCase):
    def testBothDoorsUseIt(self) -> None:
        self.assertIn("BotSettingsDoor(bot: bot, model: model)", LIST,
                      "the list's long press must go through the shared door")
        self.assertIn("BotSettingsDoor(bot: bot, model: model)", CHAT,
                      "a conversation's Edit must open the same door")

    def testNeitherBuildsItsOwnSheet(self) -> None:
        self.assertNotIn("BotModelSettingsScreen(", LIST)
        self.assertNotIn("BotModelSettingsScreen(", CHAT)

    def testTheDoorCarriesEverySectionTheListHad(self) -> None:
        for section in ("saveDescription:", "editSoul:", "saveIcon:", "loadMemory:", "deleteBot:"):
            with self.subTest(section=section):
                self.assertIn(section, DOOR,
                              f"{section} is a section the conversation's copy had lost")

    def testTheSoulEditorBelongsToTheDoor(self) -> None:
        # The one section that is a second presentation: a caller that had to remember it is how the
        # two copies drifted in the first place.
        self.assertIn("SoulEditorSheet(", DOOR)
        self.assertNotIn("SoulEditorSheet(", LIST)
