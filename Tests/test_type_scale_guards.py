"""Every glyph in both apps goes through `TypeScale.font`, which honours both of its arguments.

The Mac app once looked washed out because the helper accepted a weight and dropped it. The current
contract is simpler: one system face, the real weight face on each platform, and a half-point grid so
a scaled step never draws a soft fractional size. No optional custom face is consulted at runtime.
"""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COMPONENTS = (ROOT / "Sources" / "HermeyUI" / "Components.swift").read_text(encoding="utf-8")
COMPOSER = (ROOT / "Sources" / "HermeyUI" / "ComposerTextView.swift").read_text(encoding="utf-8")


def active_lines(source: str) -> str:
    return "\n".join(line for line in source.splitlines()
                      if not line.lstrip().startswith("//"))


class TypeScaleGuards(unittest.TestCase):
    def setUp(self) -> None:
        self.font_body = COMPONENTS.split("public static func font(", 1)[1].split(
            "public static func pointSize", 1)[0]

    def test_the_weight_is_used(self) -> None:
        self.assertIn("weight: weight", self.font_body)

    def test_the_system_face_is_the_only_face(self) -> None:
        self.assertIn(".system(size: pointSize(size), weight: weight)", self.font_body)
        self.assertNotIn("interIsInstalled", COMPONENTS)
        self.assertNotIn(".custom(", active_lines(COMPONENTS))

    def test_sizes_are_rounded_to_a_half_point(self) -> None:
        point = COMPONENTS.split("public static func pointSize", 1)[1].split("}", 1)[0]
        self.assertIn("* 2).rounded() / 2", point,
                      "a 0.85 step must not draw 11.9 pt glyphs")

    def test_the_mac_composer_uses_the_same_face_and_grid(self) -> None:
        self.assertIn("TypeScale.pointSize(size)", active_lines(COMPOSER))
        self.assertIn("NSFont.systemFont(ofSize: TypeScale.pointSize(size), weight: weight)",
                      active_lines(COMPOSER))
        self.assertNotIn("NSFont(name:", active_lines(COMPOSER))

    def test_nothing_else_builds_an_unchecked_custom_font(self) -> None:
        for path in list((ROOT / "Sources").rglob("*.swift")) + list((ROOT / "Apps").rglob("*.swift")):
            self.assertNotIn('.custom("Inter"', active_lines(path.read_text(encoding="utf-8")),
                             str(path.name))
