"""The size floor is a default, not a veto: the working row animates at 16 pt."""

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
UI = ROOT / "Sources" / "HermeyUI"


class MotionFloor(unittest.TestCase):
    def setUp(self) -> None:
        self.motion = (UI / "BotAvatarMotion.swift").read_text()
        self.view = (UI / "BotAvatarView.swift").read_text()
        self.status = (UI / "WorkingStatus.swift").read_text()

    def test_the_floor_is_a_parameter_with_the_house_default(self) -> None:
        self.assertIn("minimumSize: Double = minimumAnimatingSize", self.motion)
        self.assertIn("return size >= minimumSize", self.motion)
        self.assertNotIn("return size >= minimumAnimatingSize", self.motion,
                         "the floor must come from the caller, or the status row can never move")

    def test_the_view_passes_its_own_floor_through(self) -> None:
        self.assertIn("minimumSize: animatingFrom", self.view)
        self.assertIn("animatingFrom: Double = BotAvatarMotion.minimumAnimatingSize", self.view)

    def test_the_working_row_animates_below_the_house_floor(self) -> None:
        self.assertIn("animatingFrom: 0", self.status,
                      "the 16 pt status face is the indicator; the floor must not freeze it")
        self.assertIn("animates: true", self.status)


if __name__ == "__main__":
    unittest.main()
