"""Structural guards for iOS bot-list wiring (run without the iOS SDK)."""
from pathlib import Path
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "Apps/HermesMobile/Views/BotListScreen.swift"


class BotListRegressionTests(unittest.TestCase):
    def test_hidden_section_does_not_depend_on_visible_rows(self):
        source = SOURCE.read_text()
        list_body = source.split("        List {", 1)[1].split("        .listStyle", 1)[0]
        self.assertIn("            if showHidden, !hiddenBots.isEmpty {", list_body)
        # The empty state must not swallow a query's message findings: a search whose text
        # matches no bot NAME still has results to show (that was the "third character shows
        # nothing" bug).
        self.assertIn("} else if filtered.isEmpty && trimmedQuery.isEmpty", list_body)

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
        # Content scrolling under the bar dissolves into the canvas. This has to be a *mask*, not a
        # gradient painted over the list: an overlay is anchored to the scroll view's own top edge,
        # which on a NavigationStack root is the window top — so the ramp sat behind the status and
        # navigation bars and nothing faded (build 453's "the top fade got lost"). A mask also
        # cannot swallow a tap, which is what the old `allowsHitTesting(false)` was there for.
        source = SOURCE.read_text()
        self.assertIn(".mask { topFadeMask }", source)
        fade = source.split("private var topFadeMask: some View", 1)[1].split("private var listHeading", 1)[0]
        self.assertIn("LinearGradient(", fade)
        self.assertIn("color: .clear", fade, "it has to reach clear, or it is a band")
        self.assertIn("proxy.safeAreaInsets.top", fade,
                      "the ramp must be measured from the bottom of the bar, not the window edge")
        self.assertNotIn("ignoresSafeArea(edges: .top)", fade,
                         "a ramp that extends into the bar is the fade that got lost")
        # Over an empty list there is nothing to dissolve; a gradient there would only dim the
        # empty state's hero block.
        self.assertIn("hasRowsToFade", fade)
        self.assertIn("Color.black", fade)

    def test_the_fade_is_a_mask_not_an_overlay(self):
        # The overlay form is the defect, not just its height: keep it out.
        source = SOURCE.read_text()
        self.assertNotIn(".overlay(alignment: .top) { topFade }", source)
        self.assertNotIn("private var topFade: some View", source)


if __name__ == "__main__":
    unittest.main()
