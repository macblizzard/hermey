"""Every glyph in both apps goes through `TypeScale.font`, and it must honour both of its arguments.

The Mac app looked washed out because the helper accepted a weight and dropped it — `.custom("Inter",
size:)` has no weight parameter — and because Inter is not bundled, so the request fell back to the
*regular* system face. Sixty-four call sites asked for `.semibold` or `.medium` and got neither.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COMPONENTS = (ROOT / "Sources" / "OpenBotUI" / "Components.swift").read_text(encoding="utf-8")
COMPOSER = (ROOT / "Sources" / "OpenBotUI" / "ComposerTextView.swift").read_text(encoding="utf-8")


class TypeScaleGuards(unittest.TestCase):
    def setUp(self) -> None:
        body = COMPONENTS.split("public static func font(", 1)[1].split("public static func pointSize", 1)[0]
        self.font_body = body

    def test_the_weight_is_used(self) -> None:
        self.assertIn("weight: weight", self.font_body,
                      "both branches must pass the weight they were given")
        self.assertNotIn(".custom(\"Inter\", size: points)\n", self.font_body,
                         "an unweighted custom font is how 64 call sites lost their weight")

    def test_the_fallback_is_the_system_face_not_a_missing_family(self) -> None:
        self.assertIn("return .system(size: points, weight: weight)", self.font_body)
        self.assertIn("interIsInstalled", self.font_body)

    def test_sizes_are_rounded_to_a_half_point(self) -> None:
        point = COMPONENTS.split("public static func pointSize", 1)[1].split("}", 1)[0]
        self.assertIn("* 2).rounded() / 2", point,
                      "a 0.85 step must not draw 11.9 pt glyphs")

    def test_the_installed_check_covers_both_platforms(self) -> None:
        check = COMPONENTS.split("private static let interIsInstalled", 1)[1].split("}()", 1)[0]
        self.assertIn("availableFontFamilies", check, "macOS: family names, not PostScript names")
        self.assertIn("UIFont.familyNames", check)

    def test_the_mac_composer_draws_the_same_face(self) -> None:
        self.assertIn("TypeScale.pointSize(size)", COMPOSER)
        self.assertIn("availableFontFamilies.contains(\"Inter\")", COMPOSER,
                      "NSFont(name:) takes a PostScript name and answers nil for the family")

    def test_nothing_else_builds_a_custom_font_unchecked(self) -> None:
        offenders = []
        for path in list((ROOT / "Sources").rglob("*.swift")) + list((ROOT / "Apps").rglob("*.swift")):
            text = path.read_text(encoding="utf-8")
            for line_number, line in enumerate(text.splitlines(), start=1):
                if ".custom(\"Inter\"" not in line:
                    continue
                if line.lstrip().startswith("//"):
                    continue  # prose, not a call
                window = text[max(0, sum(len(l) + 1 for l in text.splitlines()[:line_number - 1]) - 400):]
                if "interIsInstalled" not in window.split(".custom(\"Inter\"")[0][-400:]:
                    offenders.append(f"{path.name}:{line_number}")
        self.assertEqual(offenders, [], "only TypeScale.font may ask for Inter, and only behind the check")


if __name__ == "__main__":
    unittest.main()
