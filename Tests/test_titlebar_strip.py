"""The stand-in title bar covers the whole strip.

The window runs with `.hiddenTitleBar`, so a transparent view is what makes "drag me" and
"double-click me" exist at all. That view used to start 96 pt in — which left the band above the
sidebar's search field, the place a hand actually aims, dead: the same double-click that zoomed the
window over the conversation did nothing there.
"""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DRAG = (ROOT / "Apps" / "HermesMac" / "Support" / "TitlebarDragArea.swift").read_text(encoding="utf-8")
ROOT_VIEW = (ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceRoot.swift").read_text(encoding="utf-8")


class TitlebarStrip(unittest.TestCase):
    def test_the_strip_is_full_width(self) -> None:
        self.assertNotIn(".padding(.leading, 96)", ROOT_VIEW,
                         "the inset is what made the left band dead; the traffic lights are hit first anyway")
        self.assertIn(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)", ROOT_VIEW)

    def test_a_double_click_does_what_the_system_says(self) -> None:
        self.assertIn('UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")', DRAG)
        for case in ('case "Minimize"?', 'case "None"?', "window.zoom(nil)", "window.miniaturize(nil)"):
            self.assertIn(case, DRAG)

    def test_one_press_still_drags_the_window(self) -> None:
        self.assertIn("window.performDrag(with: event)", DRAG)
        self.assertIn("event.clickCount == 2", DRAG)


if __name__ == "__main__":
    unittest.main()
