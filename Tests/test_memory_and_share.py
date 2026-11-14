"""What a bot *is* — its portrait, its soul, its memory — and getting a library file out of the app.

Two rules this file exists to keep:

- A long press on a bot's row is a gesture nobody discovers, so nothing a person changes deliberately
  lives only there. The icon and the soul moved into Bot Settings; the soul and the memory are also
  rows on the bot's own page.
- Sharing a workspace document shares the *file*: the bridge's ticket is single use, so a URL would be
  dead before another app could open it. The phone hands a staged copy to the system sheet, the Mac
  writes a copy where you pick.
"""
from __future__ import annotations

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
MOBILE = ROOT / "Apps" / "HermesMobile"
MAC = ROOT / "Apps" / "HermesMac"
KIT = ROOT / "Sources" / "HermesKit"
BRIDGE = ROOT / "Bridge" / "hermes_bridge"

DRAWER = MOBILE / "Views" / "ConversationDrawer.swift"
SCREEN = MOBILE / "Views" / "ConversationScreen.swift"
LIST = MOBILE / "Views" / "BotListScreen.swift"
SETTINGS = MOBILE / "Views" / "BotModelSettingsScreen.swift"
LIBRARY = MOBILE / "Views" / "WorkspaceSheet.swift"
MAC_FILES = MAC / "Workspace" / "MacWorkspaceSheet.swift"
MAC_SETTINGS = MAC / "Views" / "MacBotSettingsSheet.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class TheBotKnowsItself(unittest.TestCase):
    def test_the_page_has_a_soul_row_and_a_memory_row(self) -> None:
        drawer = read(DRAWER)
        self.assertIn('row("Soul", systemImage: "doc.text", run: onSoul)', drawer)
        self.assertIn('row("Memory", systemImage: "brain", run: onMemory)', drawer)
        # Both doors are wired, not drawn: a row that opens nothing is worse than no row.
        screen = read(SCREEN)
        self.assertIn("onSoul: { closeDrawer(); showSoul = true }", screen)
        self.assertIn("onMemory: { closeDrawer(); showMemory = true }", screen)
        self.assertIn("SoulEditorSheet(", screen)
        self.assertIn("BotMemorySheet(botName: bot.displayName", screen)

    def test_a_long_press_no_longer_hides_the_identity_verbs(self) -> None:
        # Reported 2026-11-14: the icon and the soul were only reachable by long-pressing a row.
        row = read(LIST).split(".contextMenu {", 1)[1].split("}", 1)[0]
        self.assertNotIn('"Bot icon"', row)
        self.assertNotIn('"Edit SOUL.md"', row)
        # What stays is what is about the row itself.
        for verb in ("Bot Settings", "Pin to top", "Hide bot"):
            self.assertIn(verb, read(LIST))

    def test_bot_settings_owns_the_icon_the_soul_and_the_memory(self) -> None:
        settings = read(SETTINGS)
        self.assertIn('Label("Bot icon", systemImage: "person.crop.circle")', settings)
        self.assertIn('Label("Soul", systemImage: "doc.text")', settings)
        self.assertIn('Label("Memory", systemImage: "brain")', settings)
        self.assertIn("BotIconPicker(botName: bot.displayName, selected: icon)", settings)
        self.assertIn("BotMemorySheet(botName: bot.displayName, load: loadMemory)", settings)
        # Each is optional: a client that cannot write the icon must not be shown the row.
        self.assertIn("var saveIcon: ((BotFace) async throws -> Void)? = nil", settings)
        self.assertIn("var loadMemory: (() async throws -> BotMemory)? = nil", settings)

    def test_the_list_hands_both_writers_to_the_settings_sheet(self) -> None:
        listing = read(LIST)
        self.assertIn("saveIcon: { face in try await app.saveBotFace(botID: bot.id, face: face) }",
                      listing)
        self.assertIn("loadMemory: { try await model.memory(for: bot.id) }", listing)


class TheHostServesMemory(unittest.TestCase):
    def test_the_route_reads_the_two_documents_by_name(self) -> None:
        source = read(BRIDGE / "bot_memory.py")
        self.assertIn('"MEMORY.md"', source)
        self.assertIn('"USER.md"', source)
        # Read-only: no writer, no configure call, nothing that could rewrite the agent's own notes.
        self.assertNotIn("write_text", source)
        self.assertIn("is_symlink()", source, "a link named MEMORY.md must not hand over a host file")

    def test_the_kit_model_is_the_wire_shape(self) -> None:
        kit = read(KIT / "BotMemory.swift")
        self.assertIn('object["text"]', kit)
        self.assertIn('object["chars"]', kit)
        self.assertIn("public struct BotMemory", kit)
        self.assertIn("public struct BotMemoryDocument", kit)

    def test_the_sheet_is_shared_by_both_shells(self) -> None:
        self.assertTrue((ROOT / "Sources" / "OpenBotUI" / "BotMemorySheet.swift").is_file())
        self.assertIn("BotMemorySheet(", read(MAC_SETTINGS))


class TheLibraryCanShare(unittest.TestCase):
    def test_the_phone_stages_the_file_before_sharing_it(self) -> None:
        library = read(LIBRARY)
        self.assertIn("WorkspaceSharing.stage(bytes, named: file.name)", library)
        self.assertIn("ActivityShareSheet(url: item.url)", library)
        self.assertIn("WorkspaceSharing.discard(item.url)", library, "the staged copy is litter")
        # Both doors: the row (without opening it) and the document itself.
        self.assertIn('Label("Share", systemImage: "square.and.arrow.up")', library)
        self.assertIn('accessibilityLabel("Share \\(file.name)")', library)

    def test_the_staged_name_cannot_climb_out_of_the_folder(self) -> None:
        kit = read(KIT / "BotMemory.swift")
        self.assertIn("split(separator: \"/\").last", kit)
        self.assertIn('return "document"', kit)

    def test_the_mac_writes_a_copy_instead(self) -> None:
        mac = read(MAC_FILES)
        self.assertIn('Button("Save…") { saveToDisk() }', mac)
        self.assertIn("NSSavePanel()", mac)
        self.assertIn("panel.nameFieldStringValue = file.name", mac)
        # It fetches for itself, so a file with no preview can still leave the app.
        self.assertIn("data = try await client.data(profile: profile, file: file).bytes", mac)


if __name__ == "__main__":
    unittest.main()
