"""The launch face is the app's own mark, not a bot's derived face."""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
BOOT = (ROOT / "Sources" / "HermeyUI" / "BootScreen.swift").read_text()
PACKAGE = (ROOT / "Package.swift").read_text()
MARK = ROOT / "Sources" / "HermeyUI" / "Resources" / "HermeyMark.png"


class BootMark(unittest.TestCase):
    def test_the_mark_ships_with_the_module(self) -> None:
        self.assertTrue(MARK.is_file(), "the launch mark must be a resource of HermeyUI")
        self.assertIn('resources: [.process("Resources")]', PACKAGE)
        data = MARK.read_bytes()
        self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
        # 790 x 770 in the PNG header, big-endian.
        width = int.from_bytes(data[16:20], "big")
        height = int.from_bytes(data[20:24], "big")
        self.assertEqual((width, height), (790, 770))
        self.assertAlmostEqual(KIND(width, height), 790 / 770, places=6)

    def test_the_boot_screen_draws_the_mark_and_not_a_bot_face(self) -> None:
        self.assertIn('Image("HermeyMark", bundle: .module)', BOOT)
        self.assertNotIn("BotAvatarView(", BOOT,
                         "a bot's identity-derived body is not the brand mark")
        self.assertIn("markAspect", BOOT)

    def test_the_mark_is_drawn_whole_never_stretched(self) -> None:
        self.assertIn("contentMode: .fit", BOOT)


def KIND(width: int, height: int) -> float:
    return width / height


if __name__ == "__main__":
    unittest.main()
