"""The launch face is the app's own mark — and it is on screen long enough to be seen."""

import json
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
BOOT = (ROOT / "Sources" / "HermeyUI" / "BootScreen.swift").read_text()
READINESS = (ROOT / "Sources" / "HermesKit" / "LaunchReadiness.swift").read_text()
PACKAGE = (ROOT / "Package.swift").read_text()
MARK = ROOT / "Sources" / "HermeyUI" / "Resources" / "HermeyMark.png"
APPS = ["HermesMobile", "HermesMac"]


def imageset(app: str) -> pathlib.Path:
    return ROOT / "Apps" / app / "Assets.xcassets" / "HermeyMark.imageset"


class BootMark(unittest.TestCase):
    def test_the_source_mark_is_the_brand_face(self) -> None:
        self.assertTrue(MARK.is_file())
        data = MARK.read_bytes()
        self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
        # 790 x 770 in the PNG header, big-endian: the face cropped tight to its own body.
        width = int.from_bytes(data[16:20], "big")
        height = int.from_bytes(data[20:24], "big")
        self.assertEqual((width, height), (790, 770))
        self.assertIn('resources: [.process("Resources")]', PACKAGE)

    def test_every_app_ships_the_mark_in_its_own_catalogue(self) -> None:
        """`Image(_:)` resolves through the app's catalogue, not a SwiftPM bundle name.

        `0.1.482` drew `Image("HermeyMark", bundle: .module)`: the PNG was in the IPA, inside
        `HermesApps_HermeyUI.bundle`, and the splash still drew no mark — and a splash with no mark,
        on a canvas the same colour as the app, is exactly "the boot screen does not show up".
        """
        for app in APPS:
            directory = imageset(app)
            self.assertTrue(directory.is_dir(), f"{app} needs HermeyMark in its asset catalogue")
            png = directory / "HermeyMark.png"
            self.assertTrue(png.is_file())
            self.assertEqual(png.read_bytes()[:8], b"\x89PNG\r\n\x1a\n")
            contents = json.loads((directory / "Contents.json").read_text())
            names = [image.get("filename") for image in contents["images"]]
            self.assertIn("HermeyMark.png", names)

    def test_the_boot_screen_draws_the_mark_and_not_a_bot_face(self) -> None:
        self.assertIn('Image("HermeyMark")', BOOT)
        self.assertNotIn("bundle: .module", BOOT,
                         "the image loader cannot see a package resource bundle by name")
        self.assertNotIn("BotAvatarView(", BOOT,
                         "a bot's identity-derived body is not the brand mark")
        self.assertIn("markAspect", BOOT)

    def test_the_mark_is_drawn_whole_never_stretched(self) -> None:
        self.assertIn("contentMode: .fit", BOOT)


class BootFloor(unittest.TestCase):
    """A splash that appears for one frame is a flash, and reads as no splash at all."""

    def test_the_floor_exists_and_is_half_a_second(self) -> None:
        self.assertIn("public let minimumVisible: TimeInterval", READINESS)
        self.assertIn("defaultMinimumVisible: TimeInterval = 0.5", READINESS)
        self.assertIn("elapsed >= minimumVisible", READINESS)

    def test_the_floor_only_extends_the_wait(self) -> None:
        # It is checked *with* the signals, never instead of them, and the deadline is still first.
        body = READINESS.split("public mutating func advance(")[1]
        order = [body.index(marker) for marker in
                 ("!signals.isPaired", "signals.connectionFailed", "elapsed >= deadline",
                  "elapsed >= minimumVisible")]
        self.assertEqual(order, sorted(order),
                         "the deadline must outrank both readiness and the floor")


if __name__ == "__main__":
    unittest.main()
