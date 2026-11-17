"""The Mac's ⌘K palette carries the settings, not just the chat verbs.

Asked for 2026-11-17: "could you add more settings to the omnibar? like check for upgrades, view logs,
enable/disable reason, tool calls, notes, skills, mcp, routines, etc." — then, when asked where:
"yeah i meant the command pallete" and "only for desktop".

So this pins the catalogue, not the palette's drawing: the six bot doors, the two reading switches, the
log door and the update check, each wired to the thing that already does the work elsewhere in the window.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STORE = (ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceStore.swift").read_text(encoding="utf-8")
ROOT_VIEW = (ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceRoot.swift").read_text(encoding="utf-8")
COMMAND = (ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceCommand.swift").read_text(encoding="utf-8")
APP = (ROOT / "Apps" / "HermesMac" / "HermesMacApp.swift").read_text(encoding="utf-8")


class ThePaletteCarriesTheSettings(unittest.TestCase):
    def testTheCatalogueHasTheGroupsTheNewVerbsLandIn(self) -> None:
        self.assertIn('case view = "View"', COMMAND)
        self.assertIn('case bot = "Bot"', COMMAND)

    def testEveryBotDoorIsAVerb(self) -> None:
        # The six rows of the bot panel, each reaching the same opener the panel's row does.
        for door in ("openNotes", "openSkills", "openMCP", "openRoutines", "openWorkspace", "openModel"):
            with self.subTest(door=door):
                self.assertIn(f"self?.{door}(bot)", STORE,
                              f"the palette has no verb for {door}")
        self.assertIn("private var botDoors", STORE)
        # Disabled with no bot on screen rather than hidden: the palette doubles as a map of the window.
        self.assertIn("isEnabled: selectedBot != nil", STORE)

    def testTheTwoReadingSwitchesFlipTheModel(self) -> None:
        self.assertIn('id: "view.reasoning"', STORE)
        self.assertIn("self?.model.showReasoning.toggle()", STORE)
        self.assertIn('id: "view.toolCalls"', STORE)
        self.assertIn("self?.model.showToolCalls.toggle()", STORE)
        # The title states where it will take you, not where you are.
        self.assertIn('model.showReasoning ? "Hide reasoning" : "Show reasoning"', STORE)
        self.assertIn('model.showToolCalls ? "Hide tool calls" : "Show tool calls"', STORE)

    def testTheLogDoorOpensTheSameViewSettingsEmbeds(self) -> None:
        self.assertIn('id: "view.logs"', STORE)
        self.assertIn("self?.openLogs()", STORE)
        self.assertIn("func openLogs() { isLogsPresented = true }", STORE)
        # It rides the window's one `.sheet(item:)` route, with the header Settings → About uses.
        self.assertIn("case logs", ROOT_VIEW)
        self.assertIn("ClientLogView(title: \"Log\", header: logHeader)", ROOT_VIEW)
        self.assertIn("if store.isLogsPresented { return .logs }", ROOT_VIEW)
        self.assertIn("store.isLogsPresented = false", ROOT_VIEW)

    def testTheUpdateCheckIsSparklesOwnAndHonestAboutItsAbsence(self) -> None:
        self.assertIn('id: "app.updates"', STORE)
        self.assertIn("self?.checkForUpdates?()", STORE)
        # Off when there is no updater in the build, with a subtitle that says why.
        self.assertIn("isEnabled: checkForUpdates != nil", STORE)
        self.assertIn("This build has no updater", STORE)
        # The app hands the store the same closure the menu bar and Settings use.
        self.assertIn("store.checkForUpdates = checkForUpdates", APP)
