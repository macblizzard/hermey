"""What a bot may reach for: its skills, and its MCP servers — the panels, and the replace rule.

The host already had both features; what was missing was a client surface and a place to tap. The trap
this file exists to catch is the *replace* semantics: `profiles.configure` overwrites `skills.disabled`
and `enabled_mcp_servers` wholesale, so a call that sends one item silently switches off every other
skill, or every other server, the bot had.
"""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

KIT = ROOT / "Sources" / "HermesKit" / "GatewayClient.swift"
ACTOR = ROOT / "Sources" / "HermesKit" / "GatewayClientActor.swift"
MODEL = ROOT / "Sources" / "HermesAppKit" / "AppModel.swift"
SHEET = ROOT / "Apps" / "HermesMobile" / "Views" / "BotToolsSheet.swift"
SCREEN = ROOT / "Apps" / "HermesMobile" / "Views" / "ConversationScreen.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class TheMenuHasBothPanels(unittest.TestCase):
    def test_skills_and_mcp_rows_exist(self) -> None:
        screen = read(SCREEN)
        self.assertIn('Label("Skills", systemImage: "book.closed")', screen)
        self.assertIn('Label("MCP servers", systemImage: "puzzlepiece.extension")', screen)
        self.assertIn("BotToolsSheet(bot: bot, kind: .skills, model: model)", screen)
        self.assertIn("BotToolsSheet(bot: bot, kind: .mcp, model: model)", screen)


class TheHostContractIsTheOneWeRead(unittest.TestCase):
    def test_describe_is_where_the_lists_come_from(self) -> None:
        # One call gives both lists with their current state; a second source would be able to disagree.
        actor = read(ACTOR)
        self.assertIn('result["skills"]?.arrayValue', actor)
        self.assertIn('result["mcp_servers"]?.arrayValue', actor)
        self.assertIn('"enabled"', actor)

    def test_the_fields_match_the_gateway_payload(self) -> None:
        kit = read(KIT)
        self.assertIn("public struct ProfileSkill", kit)
        self.assertIn("public struct ProfileMCPServer", kit)
        self.assertIn("let transport: String", kit)


class ItReplacesInsteadOfPatching(unittest.TestCase):
    def test_a_skill_toggle_sends_the_whole_disabled_set(self) -> None:
        model = read(MODEL)
        body = model.split("public func setSkill(", 1)[1].split("/// Turn one MCP server", 1)[0]
        self.assertIn("description.skills.filter { !$0.enabled }", body,
                      "start from the host's own list, not from an empty one")
        self.assertIn("disabledSkills: Array(disabled).sorted()", body)
        self.assertIn("enabledMCPServers: nil", body, "a skill tap must not rewrite the servers")

    def test_a_server_toggle_sends_the_whole_enabled_set(self) -> None:
        model = read(MODEL)
        body = model.split("public func setMCPServer(", 1)[1].split("/// Replace a bot's SOUL.md", 1)[0]
        self.assertIn("description.mcpServers.filter(\\.enabled)", body)
        self.assertIn("enabledMCPServers: Array(servers).sorted()", body)
        self.assertIn("disabledSkills: nil", body)

    def test_an_unauthorised_client_refuses_rather_than_pretending(self) -> None:
        kit = read(KIT)
        default = kit.split("func configureFeatures(profile: String, disabledSkills: [String]?,", 1)[1].split("}", 1)[0]
        self.assertIn("throw", default)


class TheSheetIsHonest(unittest.TestCase):
    def test_a_failed_save_moves_the_switch_back(self) -> None:
        sheet = read(SHEET)
        self.assertIn("description = current", sheet, "an optimistic switch that fails must unwind")
        self.assertIn("failure = error.localizedDescription", sheet)

    def test_it_says_what_off_means(self) -> None:
        sheet = read(SHEET)
        self.assertIn("cannot be reached by name either", sheet)
        self.assertIn("disappear on the next turn", sheet)

    def test_the_scope_is_named(self) -> None:
        sheet = read(SHEET)
        self.assertIn("Other bots keep theirs", sheet)

    def test_counts_are_shown_not_guessed(self) -> None:
        sheet = read(SHEET)
        self.assertIn("skills.filter(\\.enabled).count", sheet)
        self.assertIn("servers.filter(\\.enabled).count", sheet)


if __name__ == "__main__":
    unittest.main()
