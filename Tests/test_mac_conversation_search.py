"""The Mac's in-chat search: a bar over the transcript, not the sidebar's bot filter.

Reported 2026-11-15 from a screenshot: the reader typed `leak` into the bot panel's field and was
answered `No bots match "leak"`, while the conversation they meant to search was open behind it.
The desktop only ever filtered the roster; the phone already searched inside its conversation.

These are source-shape contracts — *where* the bar lives, which matcher feeds it, and that the two
searches cannot be confused. The behaviour itself is held by `Tests/HermesKitTests/`:

* `ConversationSearchTests` — the matcher both platforms call (counts, folding, clamping);
* `TranscriptSearchStateTests` — the Mac's glue around it (the three doors, Escape, the cursor,
  and the scroll position a search owns).

`Tests/HermesMacUITests/HermesMacConversationUITests` drives the real bar on a Mac.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAC = ROOT / "Apps" / "HermesMac"

SCROLL = (MAC / "Conversation" / "TranscriptScroll.swift").read_text(encoding="utf-8")
APP = (MAC / "HermesMacApp.swift").read_text(encoding="utf-8")
STORE = (MAC / "Workspace" / "WorkspaceStore.swift").read_text(encoding="utf-8")
PANEL = (MAC / "Workspace" / "MacBotPanel.swift").read_text(encoding="utf-8")
SIDEBAR = (MAC / "Sidebar" / "BotSidebarView.swift").read_text(encoding="utf-8")
LIST = (MAC / "Sidebar" / "SidebarBotList.swift").read_text(encoding="utf-8")
PROBE = (MAC / "Support" / "ScrollViewportProbe.swift").read_text(encoding="utf-8")
IOS_SCREEN = (ROOT / "Apps" / "HermesMobile" / "Views" / "ConversationScreen.swift").read_text(encoding="utf-8")
MATCHER = (ROOT / "Sources" / "HermesKit" / "ConversationSearch.swift").read_text(encoding="utf-8")
STATE = (ROOT / "Sources" / "HermesKit" / "TranscriptSearchState.swift").read_text(encoding="utf-8")


def without_comments(source: str) -> str:
    """The file with its line comments removed.

    Doc comments are where this repo explains the bug it is replacing, so a `not in` assertion has
    to look at the code and not at the prose that names the old shape.
    """
    return "\n".join(line for line in source.splitlines() if not line.strip().startswith("//"))


class TheBarIsOverTheTranscript(unittest.TestCase):
    """The field must be able to see the conversation it searches."""

    def test_the_mac_draws_its_own_search_row(self) -> None:
        self.assertIn("private var searchRow", SCROLL)
        # Rendered above the transcript, in the reading column, only while open.
        body = SCROLL.split("var body: some View {", 1)[1].split("private var transcript", 1)[0]
        self.assertIn("searchRow", body)
        self.assertIn("if search.isOpen {", body)

    def test_the_field_says_what_it_searches(self) -> None:
        # The shared constant, so the desktop and the phone cannot drift into two different prompts.
        self.assertIn("public static let prompt = \"Search this conversation\"", MATCHER)
        self.assertIn("TextField(ConversationSearch.prompt, text: $search.query)", SCROLL)
        self.assertIn("TextField(ConversationSearch.prompt, text: $searchText)", IOS_SCREEN)

    def test_the_sidebar_field_is_not_this_one(self) -> None:
        # The regression, stated as a contract: the bot panel's field is its own search — it asks
        # the host about every conversation — and may not borrow the conversation prompt or the
        # conversation matcher, which belong to the bar over the transcript.
        for source in (SIDEBAR, LIST):
            self.assertNotIn("ConversationSearch.prompt", source)
            self.assertNotIn("TranscriptSearchState", source)
        self.assertIn('prompt: "Search bots and messages"', SIDEBAR)

    def test_the_sidebar_empty_state_no_longer_claims_it_searched_bots_only(self) -> None:
        # It used to say "Bots only — ⌘F searches the open conversation". The field now sends the
        # phrase to the host, so the empty state has to describe both halves of the answer.
        self.assertNotIn("Bots only", LIST)
        self.assertIn('Text("No matches for “\\(trimmedQuery)”")', LIST)
        self.assertIn("Searched every bot's conversation and the bot names.", LIST)


class ItUsesTheOneMatcher(unittest.TestCase):
    """Counts, folding and clamping must match the phone exactly, which means the same code."""

    def test_the_mac_searches_through_conversation_search(self) -> None:
        self.assertIn("ConversationSearch.ids(matching: search.query,", SCROLL)
        self.assertIn("id: \\.id,", SCROLL)
        self.assertIn("text: \\.text,", SCROLL)
        # No private copy of the filter may come back — on either platform.
        self.assertNotIn("localizedCaseInsensitiveContains", without_comments(SCROLL))
        self.assertNotIn("localizedCaseInsensitiveContains", without_comments(IOS_SCREEN))

    def test_the_count_is_the_matchers_own_sentence(self) -> None:
        # `1 of 3` / `No matches for “x”`, from one call — not a second format beside it.
        self.assertIn("search.status(matched: found.count)", SCROLL)
        self.assertIn('"No matches for “\\(trimmed(query))”"', MATCHER)

    def test_the_mac_glue_is_the_tested_value_type(self) -> None:
        self.assertIn("public struct TranscriptSearchState", STATE)
        self.assertIn("@State private var search = TranscriptSearchState()", SCROLL)
        # The cursor is private and can only move through the clamping helpers.
        self.assertIn("public private(set) var index = 0", STATE)
        self.assertIn("ConversationSearch.clamped(index, count: count)", STATE)
        self.assertIn("ConversationSearch.stepped(index, count: count, by: direction)", STATE)

    def test_the_transcript_does_not_carry_a_second_cursor(self) -> None:
        for gone in ("@State private var matchIndex", "@State private var searching = false"):
            self.assertNotIn(gone, SCROLL)


class TheThreeDoorsOpenTheSameBar(unittest.TestCase):
    """⌘F, the bot panel's row and the Conversation menu: one request, one bar."""

    def test_the_menu_carries_the_key(self) -> None:
        # A key you cannot see is a key you cannot learn: the menu item is the discoverable copy.
        menu = APP.split('CommandMenu("Conversation")', 1)[1]
        self.assertIn('Button("Find in Conversation…")', menu)
        self.assertIn(".keyboardShortcut(\"f\", modifiers: .command)", menu)
        self.assertIn("store.openFindInChat()", menu)

    def test_the_bot_panels_row_opens_it(self) -> None:
        self.assertIn('row("Search this conversation", icon: "magnifyingglass")', PANEL)
        self.assertIn("store.openFindInChat()", PANEL)

    def test_the_palette_offers_the_same_verb(self) -> None:
        self.assertIn('id: "chat.find"', STORE)
        self.assertIn('title: "Find in Conversation…"', STORE)
        self.assertIn("run: { [weak self] in self?.openFindInChat() }))", STORE)

    def test_the_request_is_a_counter_not_a_bool(self) -> None:
        # The bar's open state lives in the pane, so the store can only answer "somebody asked" —
        # and a counter is what lets the *second* press mean something a Bool could not.
        self.assertIn("@Published private(set) var findToggleRequest = 0", STORE)
        self.assertIn("func openFindInChat() { findToggleRequest += 1 }", STORE)
        # One owner of ⌘F: the menu item, not a hidden button in the transcript.
        self.assertNotIn(".keyboardShortcut(\"f\", modifiers: .command)", SCROLL)


class FindToggles(unittest.TestCase):
    """⌘F opens the bar, and the same press closes it (reported 2026-11-16)."""

    def test_every_door_bumps_the_toggle_request(self) -> None:
        # ⌘F / the menu item, the palette verb and the panel row all come through the one method,
        # so they cannot disagree about what a press does.
        menu = APP.split('CommandMenu("Conversation")', 1)[1]
        self.assertIn("store.openFindInChat()", menu)
        self.assertIn("run: { [weak self] in self?.openFindInChat() }))", STORE)
        self.assertIn("store.openFindInChat()", PANEL)
        self.assertEqual(without_comments(STORE).count("findToggleRequest += 1"), 1,
                         "one method owns the bump")

    def test_the_pane_toggles_on_the_request(self) -> None:
        self.assertIn("var findToggleRequest: Int = 0", SCROLL)
        self.assertIn(".onChange(of: findToggleRequest) { _, _ in toggleSearch() }", SCROLL)
        # The toggle is a real branch on the bar's own state, not a second open.
        toggle = SCROLL.split("private func toggleSearch()", 1)[1].split("\n    }", 1)[0]
        self.assertIn("if search.isOpen {", toggle)
        self.assertIn("closeSearch()", toggle)
        self.assertIn("openSearch()", toggle)

    def test_closing_clears_the_field_and_hands_the_scroll_back(self) -> None:
        # `search.ownsScrollPosition` is what held `follow()` off; leaving it armed after the bar
        # is gone would stop the transcript following the next turn for no visible reason.
        close = SCROLL.split("private func closeSearch()", 1)[1].split("\n    }", 1)[0]
        self.assertIn("search.close()", close)
        self.assertIn("searchFocused = false", close)
        self.assertIn("followsBottom = true", close)
        # And `close()` itself is what empties the query.
        self.assertIn("query = \"\"", STATE.split("public mutating func close()", 1)[1].split("}", 1)[0])

    def test_a_seeded_open_is_never_a_toggle(self) -> None:
        # A bot-list finding opens the bar pre-filled every time it is clicked; a second click must
        # land on the same phrase, not close the thing the user just asked for.
        self.assertIn("@Published private(set) var findSeedRequest = 0", STORE)
        seeded = STORE.split("private func seedFind", 1)[1].split("\n    }", 1)[0]
        self.assertIn("findSeed = query", seeded)
        self.assertIn("findSeedRequest = findRequest + 1", seeded)
        self.assertIn("findRequest += 1", seeded)
        self.assertNotIn("findToggleRequest", seeded)
        # The seeded request still opens, on its own counter.
        self.assertIn(".onChange(of: findRequest) { _, _ in openSearch() }", SCROLL)
        # And a seed is one shot: applied once, then retired, so a later plain ⌘F does not replay it.
        self.assertIn("findSeedRequest == findRequest, findSeedRequest != appliedSeedRequest", SCROLL)
        self.assertIn("appliedSeedRequest = findSeedRequest", SCROLL)
        self.assertIn("@State private var appliedSeedRequest = -1", SCROLL)


class EscapeClosesAndClearsIt(unittest.TestCase):
    def test_escape_is_owned_while_the_bar_is_up(self) -> None:
        # The hidden button is what receives the key while the field has focus; `onExitCommand`
        # covers the focus being on a chevron or on Done.
        self.assertIn(".keyboardShortcut(.escape, modifiers: [])", SCROLL)
        self.assertIn(".onExitCommand { closeSearch() }", SCROLL)

    def test_closing_takes_the_query_with_it(self) -> None:
        self.assertIn("private func closeSearch() {", SCROLL)
        self.assertIn("search.close()", SCROLL)
        self.assertIn("public mutating func close() {", STATE)
        # ...and the field is left empty, not parked on the last answer.
        self.assertIn("query = \"\"", STATE.split("public mutating func close()", 1)[1])


class StreamingIsSearchable(unittest.TestCase):
    """The live turn is on screen, so it is in the answer — last, where it is being read."""

    def test_the_live_turn_is_passed_as_the_extra_row(self) -> None:
        self.assertIn("extra: model.isStreaming && !model.visibleStreamingText.isEmpty", SCROLL)
        self.assertIn("(id: streamingID, text: model.visibleStreamingText)", SCROLL)
        # The row it can scroll to and tint is the one the bubble is drawn under.
        self.assertIn('.id(streamingID)', SCROLL)
        self.assertIn("fill([streamingID], among: matched, selected: selected)", SCROLL)


class AMatchInsideAFoldedRunIsStillReachable(unittest.TestCase):
    """A run of tool calls is one line; its cards do not exist until it is opened."""

    def test_the_jump_is_anchored_to_the_run(self) -> None:
        self.assertIn("private func scrollTarget(for id: String) -> String", SCROLL)
        self.assertIn("if case .toolRun(let run) = row, run.entries.contains(where: { $0.id == id }) {",
                      SCROLL)
        self.assertIn("return run.id", SCROLL)

    def test_the_run_wears_a_ring_rather_than_a_fill(self) -> None:
        # Its header is drawn on a card of its own, so a fill behind the group would be invisible.
        self.assertIn("private func ring(_ ids: [String], among matched: Set<String>, selected: String?) -> Color",
                      SCROLL)
        self.assertIn("strokeBorder(ring(run.entries.map(\\.id), among: matched, selected: selected),",
                      SCROLL)


class TheSearchOwnsTheScroll(unittest.TestCase):
    """Auto-scroll to the newest message must not fight an open search."""

    def test_growth_following_is_switched_off_while_the_bar_is_up(self) -> None:
        self.assertIn("var followsGrowth: Bool = true", PROBE)
        self.assertIn("if followsGrowth, lastVerdict != false {", PROBE)
        self.assertIn("followsGrowth: !search.ownsScrollPosition", SCROLL)

    def test_the_follow_and_the_button_stand_down(self) -> None:
        follow = SCROLL.split("private func follow(", 1)[1]
        self.assertIn("guard !search.ownsScrollPosition, followsBottom else { return }", follow)
        self.assertIn("if !search.ownsScrollPosition, !followsBottom {", SCROLL)

    def test_a_new_conversation_closes_the_bar(self) -> None:
        # The query described rows that are no longer on screen.
        session = SCROLL.split("private func openSession(", 1)[1]
        self.assertIn("search.resetForConversationChange()", session)


if __name__ == "__main__":
    unittest.main()
