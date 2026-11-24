"""A bot's stored avatar is drawn everywhere its face is, and a face is chosen in one place.

Reported by Mohammad, 2026-11-24, in two sentences:

> we still have the choose bot icon inside about tab even though now that we have the avatar tab
> there. also after applying the new avatar, its not being applied to the bot settings panel, on the
> right bot menu sidebar, and also on the state during activity, in those places we still see the
> old avatar

Both halves are one mistake seen twice: the *face* was a per-call-site argument. Four surfaces
passed `definition:` and twelve did not, so a bot that chose an avatar went on wearing its old
shape in the settings sheet, in the bot panel and in every still row; and because the About tab
also had a chooser, a bot had two editors for one thing.

The contract this file pins:

* **one resolution.** `BotAvatarView` draws the definition it was handed, else — through
  `EnvironmentValues.botAvatars` — the one the host stores for that bot. No call site in `Apps/`
  passes a definition, so no call site can forget one either;
* **one injection per app**, read straight off the `@Published` map (`WorkspaceStore.botAvatars`
  on the Mac, `AppEnvironment.botAvatars` on the phone) so a save needs no relaunch and no second
  cache can go stale;
* **one chooser.** The Mac settings sheet's About tab no longer builds `MacBotIconPicker`, the
  phone's Identity section no longer builds `BotIconPicker`, and nothing in either app picks a face
  anywhere but the Avatar tab;
* **both branches survive.** A bot with a definition draws `OpenBotAvatarView`; a bot without one
  still draws the shape-and-palette face.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APPS = ROOT / "Apps"
UI = ROOT / "Sources" / "HermeyUI"

LIBRARY = UI / "BotAvatarLibrary.swift"
AVATAR = UI / "BotAvatarView.swift"
MAC_ROOT = APPS / "HermesMac" / "Workspace" / "WorkspaceRoot.swift"
MAC_SETTINGS = APPS / "HermesMac" / "Views" / "MacSettingsView.swift"
MAC_SHEET = APPS / "HermesMac" / "Views" / "MacBotSettingsSheet.swift"
IOS_APP = APPS / "HermesMobile" / "HermesMobileApp.swift"
IOS_SETTINGS = APPS / "HermesMobile" / "Views" / "BotModelSettingsScreen.swift"
IOS_DOOR = APPS / "HermesMobile" / "Views" / "BotSettingsDoor.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def swift_files(root: Path) -> list[Path]:
    return sorted(p for p in root.rglob("*.swift") if "/.build/" not in str(p))


def call_arguments(text: str, marker: str) -> list[str]:
    """The argument text of every `marker(` call, parentheses balanced.

    A line-wise grep is what let a `definition:` hide ten lines below an `identity:`; the whole
    argument list is the unit that has to be right. `OpenBotAvatarView(` is a different call and is
    not counted — hence the lookbehind rather than a plain substring search.
    """
    found: list[str] = []
    pattern = r"(?<![A-Za-z])" + re.escape(marker)
    for match in re.finditer(pattern, text):
        start = match.end() - 1  # the "("
        depth = 0
        for index in range(start, len(text)):
            if text[index] == "(":
                depth += 1
            elif text[index] == ")":
                depth -= 1
                if depth == 0:
                    found.append(text[start + 1:index])
                    break
    return found


class TheFaceIsResolvedOnce(unittest.TestCase):
    def test_the_library_is_in_the_design_system_with_a_neutral_default(self) -> None:
        library = read(LIBRARY)
        self.assertIn("public struct BotAvatarLibrary", library)
        self.assertIn("public var avatars: [String: BotAvatarDocument]", library)
        self.assertIn("private struct BotAvatarsKey: EnvironmentKey", library)
        # A view whose root never injected anything must still draw — the neutral default is the
        # whole reason no call site has to pass an environment value itself.
        self.assertIn("static let defaultValue = BotAvatarLibrary.empty", library)
        self.assertIn("var botAvatars: BotAvatarLibrary", library)

    def test_the_view_falls_back_to_the_environment(self) -> None:
        view = read(AVATAR)
        self.assertIn("@Environment(\\.botAvatars) private var avatarLibrary", view)
        # The resolution itself: the parameter wins where one was passed, the stored avatar
        # otherwise. Both halves, because either alone is the bug.
        self.assertIn("if let definition {", view)
        self.assertIn("return avatarLibrary[identity]", view)

    def test_no_app_call_site_passes_a_definition(self) -> None:
        # Nothing under `Apps/` knows a definition exists: every face there comes from the
        # environment, which is what makes a surface added tomorrow correct by default.
        offenders: list[str] = []
        sites = 0
        for path in swift_files(APPS):
            for arguments in call_arguments(read(path), "BotAvatarView("):
                sites += 1
                if "definition:" in arguments:
                    offenders.append(f"{path.relative_to(ROOT)}: {arguments.splitlines()[0]}")
        self.assertGreaterEqual(sites, 14, "the face is drawn in more places than this found")
        self.assertEqual([], offenders, "an app call site pins its own definition")

    def test_every_face_surface_reads_the_environment(self) -> None:
        # The places the report names, plus the still rows that pass `animates: false`: all of them
        # draw the shared view and none of them may carry a face of its own.
        surfaces = [
            APPS / "HermesMac" / "Views" / "MacBotSettingsSheet.swift",
            APPS / "HermesMac" / "Workspace" / "MacBotPanel.swift",
            APPS / "HermesMac" / "Views" / "MacSettingsView.swift",
            APPS / "HermesMac" / "Conversation" / "TranscriptRowView.swift",
            APPS / "HermesMac" / "Conversation" / "ConversationHeader.swift",
            APPS / "HermesMac" / "Sidebar" / "SidebarBotList.swift",
            APPS / "HermesMobile" / "Views" / "ConversationDrawer.swift",
            APPS / "HermesMobile" / "Views" / "ConversationScreen.swift",
            APPS / "HermesMobile" / "Views" / "BotListScreen.swift",
            APPS / "HermesMobile" / "Views" / "MobileTranscript.swift",
            APPS / "HermesMobile" / "Views" / "BotModelSettingsScreen.swift",
            UI / "WaitingBotsInbox.swift",
            UI / "WorkingStatus.swift",
        ]
        for path in surfaces:
            with self.subTest(surface=str(path.relative_to(ROOT))):
                calls = call_arguments(read(path), "BotAvatarView(")
                self.assertGreaterEqual(len(calls), 1, "this surface stopped drawing a face at all")
                for arguments in calls:
                    self.assertNotIn("definition:", arguments)

    def test_a_bot_with_a_definition_draws_it_and_one_without_keeps_its_shape(self) -> None:
        view = read(AVATAR)
        self.assertIn("if let face = self.face {", view)
        self.assertIn("OpenBotAvatarView(definition: face.definition,", view)
        self.assertIn("} else {\n            shapeBody\n        }", view)
        # The stored colour travels with the stored body: a call site's stale `bots.color` must not
        # repaint a face that was saved after it.
        self.assertIn("return BotAvatarDocument(definition: definition, color: avatarColor)", view)
        self.assertIn("color: face.color,", view)

    def test_previews_may_still_pin_a_definition(self) -> None:
        # The one legitimate `definition:` left: a preview in the package drawing a face no host
        # has. The editor draws through `OpenBotAvatarView` directly; it never goes through this.
        preview = read(UI / "OpenBotAvatar" / "OpenBotAvatarEditor.swift")
        self.assertIn("OpenBotAvatarView(definition: draft,", preview)


class BothAppsInjectIt(unittest.TestCase):
    def test_the_mac_injects_the_store_map_at_both_roots(self) -> None:
        root = read(MAC_ROOT)
        self.assertIn(".environment(\\.botAvatars, BotAvatarLibrary(avatars: store.botAvatars))", root,
                      "the workspace window resolves no stored avatar")
        # Settings is a separate window: without its own injection the Bots tab and the sheet it
        # opens draw the old face for a bot that has an avatar.
        settings = read(MAC_SETTINGS)
        self.assertIn(".environment(\\.botAvatars, BotAvatarLibrary(avatars: store.botAvatars))",
                      settings,
                      "the settings window resolves no stored avatar")

    def test_the_phone_injects_the_environment_map_at_its_root(self) -> None:
        app = read(IOS_APP)
        self.assertIn(".environment(\\.botAvatars, BotAvatarLibrary(avatars: app.botAvatars))", app)

    def test_the_map_injected_is_the_published_one(self) -> None:
        # Read off the store that publishes it, not a copy: that is what makes a save visible
        # without a relaunch (and a second cache is what would go stale).
        for path, needle in ((ROOT / "Apps/HermesMac/Workspace/WorkspaceStore.swift",
                              "@Published private(set) var botAvatars: [String: BotAvatarDocument] = [:]"),
                             (ROOT / "Apps/HermesMobile/App/AppEnvironment.swift",
                              "@Published private(set) var botAvatars: [String: BotAvatarDocument] = [:]")):
            with self.subTest(store=path.name):
                self.assertIn(needle, read(path))

    def test_a_save_reloads_that_map(self) -> None:
        # Both `saveBotAvatar`s refresh through the same loader the launch path uses; neither keeps
        # its own store of what it just wrote.
        for path in (ROOT / "Apps/HermesMac/Workspace/WorkspaceStore.swift",
                     ROOT / "Apps/HermesMobile/App/AppEnvironment.swift"):
            with self.subTest(store=path.name):
                text = read(path)
                save = text.split("func saveBotAvatar(", 1)[1].split("func ", 1)[0]
                self.assertIn("await loadBotFaces()", save)


class OnePlaceChoosesAFace(unittest.TestCase):
    def test_the_mac_about_tab_builds_no_picker(self) -> None:
        sheet = read(MAC_SHEET)
        for gone in ("MacBotIconPicker", "Choose bot icon", "showingIconPicker"):
            with self.subTest(gone=gone):
                self.assertFalse(gone in sheet, f"the About tab still offers {gone}")
        # The Avatar tab still does the job the About tab was duplicating.
        self.assertIn("OpenBotAvatarEditor(", sheet)
        self.assertIn("case avatar = \"Avatar\"", sheet)

    def test_the_phone_identity_section_builds_no_picker(self) -> None:
        settings = read(IOS_SETTINGS)
        for gone in ("BotIconPicker", 'Label("Bot icon"', "var saveIcon"):
            with self.subTest(gone=gone):
                self.assertFalse(gone in settings, f"the Identity section still offers {gone}")
        self.assertFalse("saveIcon:" in read(IOS_DOOR))
        self.assertIn("avatarSection(save:", settings)
        self.assertIn("case avatar = \"Avatar\"", settings)

    def test_no_settings_surface_writes_a_shape_face_any_more(self) -> None:
        # `saveBotFace` is not a second door: the only callers left are the add-a-bot sheet's
        # creation flow, where there is no bot yet to have an avatar tab. (The two stores define the
        # verb; they are not callers.)
        callers = set()
        for path in swift_files(APPS):
            text = read(path)
            if "func saveBotFace(" in text:
                continue
            if re.search(r"saveBotFace\(botID:", text):
                callers.add(str(path.relative_to(ROOT)))
        self.assertEqual({"Apps/HermesMac/Sidebar/BotSidebarView.swift",
                          "Apps/HermesMobile/Views/BotListScreen.swift"}, callers)
        for path in (MAC_SHEET, IOS_SETTINGS):
            with self.subTest(surface=path.name):
                self.assertNotIn("BotFacePicker(", read(path))

    def test_the_picker_views_are_gone_but_their_services_stay(self) -> None:
        # The files stay because each also holds the HTTP service both shells write through; the
        # view that chose a face no longer exists in either.
        ios_service = read(APPS / "HermesMobile" / "Views" / "BotIconPicker.swift")
        mac_service = read(APPS / "HermesMac" / "Views" / "MacBotIconPicker.swift")
        for text in (ios_service, mac_service):
            self.assertIn("func saveAvatar(botID: String", text)
        self.assertNotIn("struct BotIconPicker: View", ios_service)
        self.assertNotIn("struct MacBotIconPicker: View", mac_service)
        # And nothing in either app can reach the shared shape picker behind their backs.
        for path in swift_files(APPS):
            with self.subTest(file=str(path.relative_to(ROOT))):
                self.assertNotIn("BotFacePicker(", read(path))


if __name__ == "__main__":
    unittest.main()
