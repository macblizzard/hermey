"""Structural guards for iOS bot-list wiring (run without the iOS SDK)."""
from pathlib import Path
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "Apps/HermesMobile/Views/BotListScreen.swift"


class BotListRegressionTests(unittest.TestCase):
    def test_hidden_section_does_not_depend_on_visible_rows(self):
        source = SOURCE.read_text()
        list_body = source.split("        List {", 1)[1].split("        .listStyle", 1)[0]
        self.assertIn("            if showHidden, !hiddenBots.isEmpty {", list_body)
        self.assertIn("} else if filtered.isEmpty && !(showHidden && !hiddenBots.isEmpty) {", list_body)

    def test_filter_uses_explicit_reversible_action(self):
        source = SOURCE.read_text()
        self.assertIn("showHidden.toggle()", source)
        self.assertIn('showHidden ? "checkmark"', source)

    def test_title_and_filter_share_navigation_bar(self):
        source = SOURCE.read_text()
        self.assertIn('.navigationBarTitleDisplayMode(.inline)', source)
        self.assertIn('ToolbarItem(placement: .topBarTrailing)', source)


if __name__ == "__main__":
    unittest.main()
