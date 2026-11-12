"""The bot's workspace, as a place to read: the list, the viewer, and how the app asks for them.

The host side is `Bridge/tests/test_workspace_api.py`, which runs the route against a real bridge. This
file guards the three things a source scan can catch and a screenshot cannot: that the ⋯ menu offers
the workspace, that the app asks the route the bridge actually serves, and that the viewer does not
pretend to render formats it cannot.
"""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

KIT = ROOT / "Sources" / "HermesKit" / "WorkspaceBrowser.swift"
SHEET = ROOT / "Apps" / "HermesMobile" / "Views" / "WorkspaceSheet.swift"
SCREEN = ROOT / "Apps" / "HermesMobile" / "Views" / "ConversationScreen.swift"
DRAWER = ROOT / "Apps" / "HermesMobile" / "Views" / "ConversationDrawer.swift"
ENV = ROOT / "Apps" / "HermesMobile" / "App" / "AppEnvironment.swift"
BRIDGE = ROOT / "Bridge" / "hermes_bridge" / "workspace.py"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class TheMenuOffersIt(unittest.TestCase):
    def test_the_drawer_has_a_workspace_row(self) -> None:
        # The phone's ⋯ became a page opened from the trailing edge (Mohammad, 2026-11-12); the row
        # moved with it, and it still opens the same sheet.
        self.assertIn('row("Workspace", systemImage: "folder"', read(DRAWER))
        self.assertIn("onWorkspace: { closeDrawer(); showWorkspace = true }", read(SCREEN))

    def test_the_sheet_is_given_the_bot_and_the_client(self) -> None:
        self.assertIn("WorkspaceSheet(bot: bot, client: app.workspace)", read(SCREEN))
        self.assertIn("let workspace: WorkspaceClient", read(ENV))

    def test_the_client_mints_a_ticket_per_request(self) -> None:
        # The bridge spends a ticket on one call; sharing one reads as a revoked device.
        env = read(ENV)
        self.assertIn("self.workspace = WorkspaceClient(endpoint:", env)
        self.assertIn("BotIconService.mintTicket", env.split("self.workspace = WorkspaceClient", 1)[1][:400])


class ItSpeaksTheRouteTheBridgeServes(unittest.TestCase):
    def test_the_paths_match(self) -> None:
        kit = read(KIT)
        self.assertIn('"v1/workspace/\\(profile)"', kit)
        self.assertIn('"v1/workspace/\\(profile)/file"', kit)
        self.assertIn("queryItems = [URLQueryItem(name: \"path\"", kit)

    def test_the_bridge_serves_exactly_those(self) -> None:
        bridge = read(BRIDGE)
        self.assertIn("APIRouter(prefix='/v1/workspace'", bridge)
        self.assertIn("@router.get('/{profile}')", bridge)
        self.assertIn("@router.get('/{profile}/file')", bridge)

    def test_the_payload_fields_are_the_ones_decoded(self) -> None:
        bridge, kit = read(BRIDGE), read(KIT)
        for field in ("name", "path", "source", "kind", "size", "modified", "previewable"):
            self.assertIn(f"'{field}':", bridge, f"the host must send {field}")
            self.assertIn(f"public let {field}", kit, f"the client decodes {field}")


class TheViewerIsHonest(unittest.TestCase):
    def test_text_pdf_and_images_each_get_their_own_renderer(self) -> None:
        sheet = read(SHEET)
        self.assertIn("PDFDocument(data: data)", sheet)
        self.assertIn("UIImage(data: data)", sheet)
        self.assertIn("String(data: data, encoding: .utf8)", sheet)

    def test_an_unpreviewable_file_says_so_instead_of_showing_blank(self) -> None:
        sheet = read(SHEET)
        self.assertIn("No preview for this kind of file", sheet)
        self.assertNotIn("Text(\"\")\n", sheet)

    def test_a_capped_list_is_admitted(self) -> None:
        self.assertIn("listing?.truncated == true", read(SHEET))


class TheWorkspaceCannotBeUsedAsAFileManager(unittest.TestCase):
    def test_nothing_here_writes(self) -> None:
        kit = read(KIT)
        for verb in ("delete(", "rename(", "move(", "write(to:"):
            self.assertNotIn(verb, kit, f"a viewer must not {verb}")

    def test_the_bridge_follows_no_links(self) -> None:
        bridge = read(BRIDGE)
        self.assertIn("if item.is_symlink():", bridge)
        self.assertIn("is_relative_to", bridge)


if __name__ == "__main__":
    unittest.main()
