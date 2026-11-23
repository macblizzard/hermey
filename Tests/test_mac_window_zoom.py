"""Double-clicking the sidebar's top band zooms/restores the Mac window.

Asked for 2026-11-17: "I cant maximize or restore the app window by double clicking anywhere … I want to
be able to double click anywhere on the bot list sidebar top to maximize(Zoom) and restore".

The window already had a stand-in title bar, but it was only the 6 pt strip at the very top — while the
sidebar's own header is a 38 pt row, so almost the whole band a person aims at did nothing. This pins the
fix: that row is now a title-bar target, and the system preference still decides what a double-click means.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SIDEBAR = (ROOT / "Apps" / "HermesMac" / "Sidebar" / "BotSidebarView.swift").read_text(encoding="utf-8")
DRAG = (ROOT / "Apps" / "HermesMac" / "Support" / "TitlebarDragArea.swift").read_text(encoding="utf-8")


class TheSidebarTopZooms(unittest.TestCase):
    def testTheEmptyPartOfTheHeaderIsADragArea(self) -> None:
        self.assertIn("TitlebarDragArea()", SIDEBAR)
        # It replaces the old empty Spacer in the *header*, so the target is the whole left half of
        # that row. (The floor bar keeps a spacer between its two groups; that row is not a title
        # bar — the window is dragged by the top one, and its background band covers the gaps.)
        header = SIDEBAR.split("private var header: some View {", 1)[1].split(
            "private var notificationsButton", 1)[0]
        self.assertNotIn("Spacer(minLength: 0)", header)

    def testTheWholeHeaderRowIsCoveredIncludingGapsBetweenButtons(self) -> None:
        self.assertIn(".background(alignment: .top)", SIDEBAR)
        self.assertIn("WorkspaceShell.titlebarStrip + 34", SIDEBAR)

    def testButtonsStayAboveTheDragTarget(self) -> None:
        # The drag area is the row's background and the leading filler; the controls are its siblings
        # drawn after it, so their clicks are not swallowed.
        header = SIDEBAR[SIDEBAR.index("private var header"):]
        self.assertLess(header.index("TitlebarDragArea()"), header.index("notificationsButton"))
        self.assertLess(header.index("notificationsButton"), header.index("addMenu"))

    def testTheDoubleClickHonoursTheSystemPreference(self) -> None:
        # The stand-in title bar already did this: zoom(nil) is the green button's call, so the window
        # returns to the frame it came from, and "None"/"Minimize" are not overridden.
        self.assertIn("event.clickCount == 2", DRAG)
        self.assertIn("AppleActionOnDoubleClick", DRAG)
        self.assertIn("window.zoom(nil)", DRAG)
