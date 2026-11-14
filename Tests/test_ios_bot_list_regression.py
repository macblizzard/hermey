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

    def test_bar_holds_search_and_menu_and_no_title(self):
        # The bar carries two round controls and nothing between them — search on the leading
        # corner, the menu on the trailing one — because the icon the user tapped already named
        # the app. The old guard asserted an inline title that the design deliberately dropped.
        source = SOURCE.read_text()
        self.assertIn('ToolbarItem(placement: .topBarLeading)', source)
        self.assertIn('ToolbarItem(placement: .topBarTrailing)', source)
        self.assertIn('.accessibilityLabel("Bot list menu")', source)
        self.assertNotIn('.navigationBarTitleDisplayMode', source)

    def test_the_chats_label_is_gone_and_the_list_sits_closer(self):
        # "CHATS" over a list of chats said what the rows already were, and cost a line between the
        # bar's buttons and the first bot (reported 2026-11-14). The Mac roster dropped the same
        # caption for the same reason.
        source = SOURCE.read_text()
        self.assertNotIn('listHeading("CHATS")', source)
        self.assertIn('.contentMargins(.top, 2, for: .scrollContent)', source)

    def test_the_top_edge_fades_instead_of_banding(self):
        # Content scrolling under the bar dissolves into the canvas. The fade must not swallow a
        # tap: it sits over the rows.
        source = SOURCE.read_text()
        self.assertIn('.overlay(alignment: .top) { topFade }', source)
        fade = source.split("private var topFade: some View", 1)[1].split("private func listHeading", 1)[0]
        self.assertIn("LinearGradient(", fade)
        self.assertIn("Tokens.canvas.opacity(0)", fade, "it has to reach clear, or it is a band")
        self.assertIn(".allowsHitTesting(false)", fade)


if __name__ == "__main__":
    unittest.main()
