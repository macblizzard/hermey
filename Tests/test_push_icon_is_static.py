"""A banner face is rendered offscreen: it must not need a timeline to draw."""

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
PUSH = (ROOT / "Sources" / "HermeyUI" / "PushIcon.swift").read_text()
STILL = (ROOT / "Sources" / "HermeyUI" / "BotAvatarStill.swift").read_text()


class PushIconIsStatic(unittest.TestCase):
    def test_the_banner_does_not_use_the_animated_view(self) -> None:
        self.assertNotIn("BotAvatarView(", PUSH,
                         "ImageRenderer cannot sample a TimelineView: the banner came out blank")
        self.assertIn("BotAvatarStill(identity: botID", PUSH)

    def test_the_still_view_draws_the_same_geometry(self) -> None:
        self.assertNotIn("TimelineView(", STILL)
        self.assertIn("BotAvatarIdentity.resolve", STILL)
        self.assertIn("BotAvatarGeometry.shipped", STILL)
        self.assertIn("BotAvatarPalette.eyeTone", STILL)

    def test_a_missing_face_skips_the_upload_rather_than_sending_blank(self) -> None:
        model = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text()
        self.assertIn("guard let data = render(bot.id) else { continue }", model)


if __name__ == "__main__":
    unittest.main()
