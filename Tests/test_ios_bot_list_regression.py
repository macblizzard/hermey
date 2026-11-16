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
        # The dissolve lives in the bar's own strip and ends where the first row begins. Two shapes
        # were tried and both were wrong in ways the screenshots proved: a mask inside the scroll
        # view inherited that view's safe-area inset and reached two rows down (it HID a bot), and a
        # ramp drawn downward from y = 0 veiled the section labels at rest. So: an overlay, offset
        # upward by the measured bar height, drawn only above the content's first row.
        source = SOURCE.read_text()
        self.assertIn(".overlay(alignment: .top) {", source)
        self.assertIn("if hasRowsToFade { topDissolve }", source)
        fade = source.split("private var topDissolve: some View", 1)[1].split("private var listHeading", 1)[0]
        self.assertIn("LinearGradient(", fade)
        self.assertIn("opacity(0)", fade, "it has to reach clear, or it is a band")
        self.assertIn("proxy.safeAreaInsets.top", fade,
                      "the strip's height must be measured from the bar, not guessed")
        self.assertIn(".offset(y: -bar)", fade,
                      "the dissolve has to sit ABOVE the content's origin, behind the buttons")
        self.assertIn("allowsHitTesting(false)", fade,
                      "the strip must not swallow a tap on the first row")
        self.assertNotIn("topFadeMask", source,
                         "the mask hid the first bot: its inset put the band over the rows")
        # Over an empty list there is nothing to dissolve; a gradient there would only dim the
        # empty state's hero block.
        self.assertIn("hasRowsToFade", source)

    def test_the_category_headings_scroll_with_the_rows(self):
        # `Section(header:)` pins on iOS: the category labels stuck to the bar and the bots slid
        # under them (reported on build 462). The headings are rows now, so nothing pins.
        source = SOURCE.read_text()
        self.assertNotRegex(source, r"\} header: \{",
                            "a pinned section header is back; headings must scroll with the list")
        self.assertIn('scrollingHeading { listHeading("GROUP CHATS") }', source)
        self.assertIn("scrollingHeading { groupHeader(group) }", source)
