"""The Mac's three per-bot panels: workspace, skills, MCP — wired to the same routes as the phone.

A source guard, because the interesting failures here are silent ones: a sheet that never presents
because the window owns exactly one modal, a menu verb that opens nothing, and a panel that reads a
different skill index than the phone does.
"""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

HEADER = ROOT / "Apps" / "HermesMac" / "Conversation" / "ConversationHeader.swift"
PANEL = ROOT / "Apps" / "HermesMac" / "Workspace" / "MacBotPanel.swift"
ROOTVIEW = ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceRoot.swift"
STORE = ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceStore.swift"
WORKSPACE = ROOT / "Apps" / "HermesMac" / "Workspace" / "MacWorkspaceSheet.swift"
TOOLS = ROOT / "Apps" / "HermesMac" / "Workspace" / "MacBotToolsSheet.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class TheMenuOpensAllThree(unittest.TestCase):
    def test_the_bots_panel_carries_them(self) -> None:
        # The verbs moved from the header's dropdown into the panel the name opens: a panel stays
        # open beside the chat it acts on, a dropdown has to be re-opened for every verb.
        panel = read(PANEL)
        for verb in ("Workspace", "Skills", "MCP servers"):
            self.assertIn(f'row("{verb}"', panel)
        for call in ("store.openWorkspace(bot)", "store.openSkills(bot)", "store.openMCP(bot)"):
            self.assertIn(call, panel)
        # And the header no longer keeps a menu of its own.
        self.assertNotIn("moreMenu", read(HEADER))

    def test_the_panel_keeps_one_grouping(self) -> None:
        panel = read(PANEL)
        block = panel
        # The documents, then what the bot may reach for: the phone's order, in the panel.
        self.assertLess(block.index('row("Workspace"'), block.index('row("Skills"'))
        self.assertLess(block.index('row("Skills"'), block.index('row("MCP servers"'))


class OneModalAtATime(unittest.TestCase):
    def test_the_window_has_a_route_for_each(self) -> None:
        root = read(ROOTVIEW)
        for case in ("case workspace(Bot)", "case skills(Bot)", "case mcp(Bot)"):
            self.assertIn(case, root)
        self.assertIn("MacWorkspaceSheet(bot: bot, client: store.workspace)", root)
        self.assertIn("MacBotToolsSheet(bot: bot, kind: .skills, model: store.model)", root)
        self.assertIn("MacBotToolsSheet(bot: bot, kind: .mcp, model: store.model)", root)

    def test_opening_one_closes_the_others(self) -> None:
        store = read(STORE)
        self.assertIn("private func closePanels()", store)
        for opener in ("func openWorkspace", "func openSkills", "func openMCP"):
            body = store.split(opener, 1)[1].split("}", 1)[0]
            self.assertIn("closePanels()", body, f"{opener} must not stack a second sheet")

    def test_dismissing_clears_every_flag(self) -> None:
        root = read(ROOTVIEW)
        setter = root.split("set: { route in", 1)[1].split(")\n", 1)[0]
        for flag in ("store.workspaceBot = nil", "store.skillsBot = nil", "store.mcpBot = nil"):
            self.assertIn(flag, setter)

    def test_the_workspace_client_mints_a_ticket_per_request(self) -> None:
        store = read(STORE)
        block = store.split("var workspace: WorkspaceClient", 1)[1].split("func toggleComputerPanel", 1)[0]
        self.assertIn("mintedTicket()", block)
        self.assertIn("isTicketOnly", block)


class TheViewersStayHonest(unittest.TestCase):
    def test_the_document_viewer_renders_what_it_can_and_says_what_it_cannot(self) -> None:
        sheet = read(WORKSPACE)
        self.assertIn("PDFDocument(data: data)", sheet)
        self.assertIn("NSImage(data: data)", sheet)
        self.assertIn("No preview for this kind of file", sheet)

    def test_it_is_read_only(self) -> None:
        sheet = read(WORKSPACE)
        for verb in ("removeItem(", "moveItem(", "trashItem("):
            self.assertNotIn(verb, sheet)

    def test_the_skill_list_is_the_hub_index_too(self) -> None:
        tools = read(TOOLS)
        self.assertIn("model.availableSkills(bot.id)", tools,
                      "the Mac must read the same index as the phone, not the profile folder")

    def test_a_failed_toggle_moves_back(self) -> None:
        tools = read(TOOLS)
        self.assertIn("described = current", tools)


if __name__ == "__main__":
    unittest.main()
