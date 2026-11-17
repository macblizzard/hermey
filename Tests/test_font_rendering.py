"""The easy typography route: one system face, real weights, hinted sizes, readable contrast."""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class OneFaceEverywhere(unittest.TestCase):
    def test_no_optional_bundled_face_remains(self) -> None:
        for name in ("Sources/HermeyUI/Components.swift",
                     "Sources/HermeyUI/ComposerTextView.swift",
                     "Apps/HermesMobile/Views/MobileSelectableText.swift"):
            code = "\n".join(
                line for line in (ROOT / name).read_text(encoding="utf-8").splitlines()
                if not line.lstrip().startswith("//"))
            self.assertNotIn('UIFont(name: "Inter"', code, name)
            self.assertNotIn('NSFont(name: "Inter"', code, name)
            self.assertNotIn("withWeight(", code, name)

    def test_swiftui_uses_the_system_face_at_the_weight_asked_for(self) -> None:
        scale = (ROOT / "Sources/HermeyUI/Components.swift").read_text(encoding="utf-8")
        self.assertIn(".system(size: pointSize(size), weight: weight)", scale)

    def test_uikit_uses_real_weight_faces_and_the_same_size_grid(self) -> None:
        prose = (ROOT / "Apps/HermesMobile/Views/MobileSelectableText.swift").read_text(encoding="utf-8")
        self.assertIn("UIFont.systemFont(ofSize: points, weight: weight)", prose)
        self.assertIn("let points = TypeScale.pointSize(size)", prose)
        self.assertIn("UIFont.monospacedSystemFont(ofSize: TypeScale.pointSize(size)", prose)

    def test_mac_markdown_rounds_sizes_too(self) -> None:
        mac = (ROOT / "Apps/HermesMac/Conversation/MacMarkdownText.swift").read_text(encoding="utf-8")
        self.assertIn("Font.system(size: TypeScale.pointSize(isMonospaced ? codeSize : size)", mac)
        self.assertIn("var color: Color = Tokens.textPrimary", mac)

    def test_message_body_is_not_dimmed_toward_the_background(self) -> None:
        prose = (ROOT / "Apps/HermesMobile/Views/MobileSelectableText.swift").read_text(encoding="utf-8")
        self.assertIn("appendInline(text, size: TypeScale.chatBody, color: Tokens.textPrimary, to: output)",
                      prose)
