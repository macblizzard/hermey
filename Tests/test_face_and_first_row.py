"""The face is a blob now, and the first row is on the traffic lights' line.

Both are appearance rules that a compiler cannot see and a screenshot review keeps having to
re-check, so they are pinned here: the silhouette is filled and carries exactly two eyes, the
sixteen shapes exist on both sides of the wire, and the chrome's top line is arithmetic that adds up.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def source(*parts: str) -> str:
    return (ROOT.joinpath(*parts)).read_text()


GALLERY = source("Sources", "OpenBotUI", "BotIconGallery.swift")
SILHOUETTE = source("Sources", "OpenBotUI", "BotSilhouette.swift")
HEADER = source("Apps", "HermesMac", "Conversation", "ConversationHeader.swift")
SIDEBAR = source("Apps", "HermesMac", "Sidebar", "BotSidebarView.swift")
ROOTVIEW = source("Apps", "HermesMac", "Workspace", "WorkspaceRoot.swift")
PANEL = source("Apps", "HermesMac", "Workspace", "MacBotPanel.swift")
BRIDGE = source("Bridge", "hermes_bridge", "bot_icons.py")


class TheFaceIsASilhouette(unittest.TestCase):
    def test_the_portrait_draws_a_filled_shape_and_two_eyes(self) -> None:
        portrait = GALLERY.split("public struct BotIconPortrait", 1)[1]
        body = portrait.split("public var body: some View", 1)[1]
        self.assertIn("BotSilhouette(icon)", body)
        self.assertIn(".fill(tint)", body)
        self.assertIn("BotEyes(size: size, tilt: icon.eyeTilt)", body)

    def test_the_ring_and_the_line_art_are_gone(self) -> None:
        # A ring around a ring around a body was the old drawing; the mass is the whole mark now.
        portrait = GALLERY.split("public struct BotIconPortrait", 1)[1]
        body = portrait.split("public var body: some View", 1)[1].split("/// Shared working", 1)[0]
        self.assertNotIn("Circle().strokeBorder", body)
        self.assertNotIn("newPortrait", GALLERY)

    def test_the_state_badge_still_sits_on_the_face(self) -> None:
        portrait = GALLERY.split("public struct BotIconPortrait", 1)[1]
        body = portrait.split("public var body: some View", 1)[1]
        for badge in ("NeedsYouFlash", "BotWorkingSparks", "CompactingZip"):
            self.assertIn(badge, body, f"{badge} no longer drawn on the portrait")

    def test_sixteen_shapes_and_four_new_silhouettes_draw_paths(self) -> None:
        cases = re.search(r"public enum BotIcon:.*?\n\}", GALLERY, re.S).group(0)
        self.assertIn("lump, mushroom, blob, capsule, droplet, scallop", cases)
        for kind in ("case .mushroom", "case .capsule", "case .scallop", "case .droplet"):
            self.assertIn(kind, SILHOUETTE, f"{kind} has no path")

    def test_the_host_accepts_every_shape_the_apps_draw(self) -> None:
        for kind in ("lump", "mushroom", "blob", "capsule", "droplet", "scallop"):
            self.assertIn(f"'{kind}'", BRIDGE, f"the host would reject {kind}")
        # And the ten that were there before are still accepted, because stored faces use them.
        for kind in ("ember", "nova", "cobalt", "orbit", "moss", "dusk", "beacon", "pixel",
                     "rover", "prism"):
            self.assertIn(f"'{kind}'", BRIDGE, f"the host dropped {kind}")

    def test_the_picker_holds_eight_per_row(self) -> None:
        picker = GALLERY.split("public struct BotFacePicker", 1)[1]
        self.assertIn("count: 8", picker)


class TheFirstRowIsOnTheLightsLine(unittest.TestCase):
    def test_the_strip_and_the_row_add_up_to_the_pill_centre(self) -> None:
        # 4 pt strip + a 34 pt row = a 21 pt centre; the pill is 40 pt in a 42 pt box = 21 pt.
        strip = re.search(r"static let titlebarStrip: CGFloat = (\d+)", ROOTVIEW)
        self.assertIsNotNone(strip)
        self.assertEqual(int(strip.group(1)), 4)
        self.assertIn(".frame(height: WorkspaceShell.titlebarStrip + 34)", SIDEBAR)
        self.assertIn(".frame(width: width, height: Geometry.chatHeaderPill + 2)", HEADER)

    def test_the_drag_band_is_its_own_and_the_window_moves_by_its_background(self) -> None:
        self.assertIn("static let dragStrip: CGFloat = 6", ROOTVIEW)
        self.assertIn(".frame(height: WorkspaceShell.dragStrip)", ROOTVIEW)
        self.assertIn("isMovableByWindowBackground = true",
                      source("Apps", "HermesMac", "Support", "TitlebarDragArea.swift"))


class ThePanelStaysAboutTheBot(unittest.TestCase):
    def test_no_palette_no_settings_no_shortcut_hints(self) -> None:
        self.assertNotIn('row("Command palette"', PANEL)
        self.assertNotIn('row("Settings"', PANEL)
        self.assertNotIn('detail: "⌘', PANEL)

    def test_the_pill_carries_no_dots(self) -> None:
        pill = HEADER.split("private func pill(width: CGFloat)", 1)[1]
        self.assertNotIn('systemName: "ellipsis"', pill)


if __name__ == "__main__":
    unittest.main()
