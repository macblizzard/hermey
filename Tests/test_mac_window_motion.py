"""One motion language for the Mac window: sheets, panels, sidebar, palette.

Asked for 2026-11-17: "sheet opening and closing and sidebar opening and closing animations on desktop
are a bit janky, would be nice to have some smooth animation for this behaviors". The sidebar had *no*
animation, the panel and the palette used two different curves, and only the palette was animated at the
presentation site. These tests pin the shape of the fix without trying to measure frames.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MOTION = (ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceMotion.swift").read_text(encoding="utf-8")
ROOT_VIEW = (ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceRoot.swift").read_text(encoding="utf-8")
STORE = (ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceStore.swift").read_text(encoding="utf-8")


class OneMotionLanguage(unittest.TestCase):
    def testEveryDoorUsesTheSharedDurations(self) -> None:
        for name in ("panel", "sidebar", "sheet"):
            with self.subTest(name=name):
                self.assertIn(f"static var {name}: Animation", MOTION)
        self.assertIn("reduceMotion", MOTION)
        self.assertIn("accessibilityDisplayShouldReduceMotion", MOTION)

    def testTheSidebarStateChangeIsAnimatedAtItsSource(self) -> None:
        # A view-side transition without `withAnimation` at the state change is a no-op: the pane was
        # removed on the same frame as the click, which is what janked.
        self.assertIn("withAnimation(WorkspaceMotion.sidebar)", STORE)
        self.assertIn("func toggleSidebar()", STORE)
        self.assertIn(".animation(WorkspaceMotion.sidebar, value: store.isSidebarHidden)", ROOT_VIEW)

    def testTheSidebarHasATransition(self) -> None:
        self.assertIn(".transition(.move(edge: .leading).combined(with: .opacity))", ROOT_VIEW)

    def testTheSheetContentFadesInsideAppkitsSheetAnimation(self) -> None:
        self.assertIn(".transition(.opacity.animation(WorkspaceMotion.sheet))", ROOT_VIEW)
        self.assertIn(".animation(WorkspaceMotion.sheet, value: store.isPalettePresented)", ROOT_VIEW)

    def testTheBotPanelUsesTheSameMotionAsTheRest(self) -> None:
        self.assertIn("withAnimation(WorkspaceMotion.panel)", STORE)
        self.assertNotIn("withAnimation(.easeOut(duration: 0.16))", STORE)

    def testTheAnimationsStayCheap(self) -> None:
        # No per-frame layout: opacity and a few points of translation only. A timeline or a
        # geometry-driven spring around the shell would keep the transcript re-laying out.
        self.assertNotIn("TimelineView", MOTION)
        self.assertNotIn("GeometryReader", MOTION)
