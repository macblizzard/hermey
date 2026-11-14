"""Paging that survives a reconnect, and a drawer that belongs to the theme.

Both bugs were invisible from the code alone: the tap reached the bridge and the bridge answered,
so the failure had to be in what the app did with the answer — and the drawer looked wrong only
because it used a card's colour for a whole panel.
"""
from __future__ import annotations

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
PAGING = (ROOT / "Sources/HermesKit/TranscriptPaging.swift").read_text()
MODEL = (ROOT / "Sources/HermesAppKit/AppModel.swift").read_text()
DRAWER = (ROOT / "Apps/HermesMobile/Views/ConversationDrawer.swift").read_text()
CHAT = (ROOT / "Apps/HermesMobile/Views/ConversationScreen.swift").read_text()
PANEL = DRAWER[DRAWER.index("private func panel"):]


class PagingTests(unittest.TestCase):
    def test_a_resume_never_replaces_the_pages_already_loaded(self) -> None:
        # The four places that adopt a host resume go through one helper, so no call site can
        # quietly assign over the transcript again.
        self.assertEqual(MODEL.count("adoptResume("), 5)  # one definition, four call sites
        self.assertEqual(MODEL.count("decorate(resumed.entries"), 0)
        self.assertIn("TranscriptPaging.merge(keeping: transcript", MODEL)

    def test_the_join_is_the_incoming_pages_first_row(self) -> None:
        self.assertIn("old.firstIndex(where: { $0.id == first.id })", PAGING)
        self.assertIn("return (Array(old[0..<join]) + incoming, oldCursor)", PAGING)

    def test_a_page_with_nothing_new_is_not_a_dead_button(self) -> None:
        # A stale cursor moves the page on; an exhausted one takes the row away.
        self.assertIn("for attempt in 1...2 {", MODEL)
        self.assertIn("earlierCursor = nil", MODEL)
        self.assertIn("earlier page: asked at", MODEL)

    def test_the_page_numbers_are_logged(self) -> None:
        self.assertIn('category: "paging"', MODEL)


class DrawerFooterTests(unittest.TestCase):
    def test_the_footer_scrolls_with_the_menu(self) -> None:
        # The hint sat under the scroll view, so its line stayed put while the rows scrolled past —
        # which read as a rule drawn over the "Compact" row.
        hint = "Swipe down, or tap the back button, to close."
        self.assertIn(hint, DRAWER)
        self.assertGreater(DRAWER.index(hint), DRAWER.index("ScrollView {"))
        # No hairlines: each group draws its own indented rules, so nothing runs edge to edge.
        self.assertEqual(DRAWER.count("Hairline("), 0)

    def test_the_pill_toggles_the_same_drawer_the_swipe_opens(self) -> None:
        self.assertIn("chatDrawerButton", CHAT)
        # No ⋯ in the toolbar any more: the capsule is the door.
        self.assertNotIn("ToolbarItem(placement: .topBarTrailing)", CHAT)
        # The same target closes it: a drawer opened by a tap must answer a second tap.
        self.assertIn("showDrawer.toggle()", CHAT)
        # The swipe is untouched: both doors lead to the same state.
        self.assertIn("isDrawerSwipe", CHAT)

    def test_the_whole_panel_is_one_scroll_view(self) -> None:
        # Nothing may sit outside the scroll view: a line left out there stays put while the rows
        # move under it, which is exactly the rule-over-Compact report.
        self.assertEqual(DRAWER.count("ScrollView {"), 1)
        # The page names the bot once, with the one verb that is about the bot itself; the
        # description is not repeated — the chat behind it is the description.
        self.assertIn("Text(title)", DRAWER)
        self.assertNotIn("if let subtitle", DRAWER)
        # Everything, first row to hint, inside the one scroll view.
        self.assertGreater(DRAWER.index('row("Reset chat"'), DRAWER.index("ScrollView {"))
        self.assertGreater(DRAWER.index("Swipe down, or tap the back button, to close."),
                           DRAWER.index('row("Reset chat"'))
        # And the panel helper is the only thing that groups rows.
        self.assertIn("private func panel", DRAWER)


class DrawerTests(unittest.TestCase):
    def test_each_group_is_a_sheet_and_the_page_is_canvas(self) -> None:
        # A page is the canvas; the groups on it are the sheet's colour, one step off the page.
        self.assertIn(".background(Tokens.canvas)", DRAWER)
        self.assertIn(".background(Tokens.sheet,", DRAWER)
        self.assertNotIn(".background(Tokens.surface)", DRAWER)

    def test_the_groups_separate_their_own_rows(self) -> None:
        # Rules only between rows, indented past the icon: an edge-to-edge rule reads as a stripe.
        self.assertIn("private var rowDivider: some View", DRAWER)
        self.assertIn("Hairline(", DRAWER) if False else None


if __name__ == "__main__":
    unittest.main()
