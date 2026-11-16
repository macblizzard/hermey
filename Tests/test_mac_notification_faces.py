"""macOS banners carry the bot's own face, and the bundle icon is the current mark."""

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
NOTIFIER = (ROOT / "Apps" / "HermesMac" / "Support" / "ReplyNotifier.swift").read_text()
CACHE = (ROOT / "Apps" / "HermesMac" / "Support" / "MacFaceCache.swift").read_text()
ROOT_VIEW = (ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceRoot.swift").read_text()
ICONS = ROOT / "Apps" / "HermesMac" / "Assets.xcassets" / "AppIcon.appiconset"


def png_side(path: pathlib.Path) -> tuple[int, int]:
    data = path.read_bytes()
    return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")


class TheBannerWearsTheBot(unittest.TestCase):
    def test_the_post_attaches_a_face(self) -> None:
        # A notification cannot choose its corner image, so the face is an attachment — the same
        # trick the phone uses. Without this the banner wears the app logo for every bot.
        self.assertIn("MacFaceCache.attachment(for: note.botID", NOTIFIER)
        self.assertIn("content.attachments = [face]", NOTIFIER)

    def test_the_face_comes_from_the_stored_setting(self) -> None:
        self.assertIn("var faceFor: ((String) -> String?)?", NOTIFIER)
        self.assertIn("ReplyNotifier.shared.faceFor = { botID in store.botFaces[botID]?.raw }", ROOT_VIEW)

    def test_the_cache_renders_a_still_and_keys_by_face(self) -> None:
        # `PushIcon` renders `BotAvatarStill`, not `BotAvatarView`: `ImageRenderer` cannot sample a
        # `TimelineView`, and the blank render is what once cost every banner its face.
        self.assertIn("PushIcon.png(for: botID, color: color)", CACHE)
        self.assertIn("BotAvatarStill", (ROOT / "Sources" / "HermeyUI" / "PushIcon.swift").read_text())
        self.assertIn("slug(botID, color)", CACHE)


class TheBundleIconIsCurrent(unittest.TestCase):
    def test_every_size_the_bundle_needs_is_present_and_square(self) -> None:
        expected = {
            "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
            "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
            "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
            "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
            "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
        }
        for name, side in expected.items():
            path = ICONS / name
            self.assertTrue(path.is_file(), name)
            self.assertEqual(png_side(path), (side, side), name)

    def test_the_regenerator_exists_so_the_icon_cannot_drift_again(self) -> None:
        source = (ROOT / "Tools" / "release" / "make-app-icons.py")
        self.assertTrue(source.is_file())


if __name__ == "__main__":
    unittest.main()
