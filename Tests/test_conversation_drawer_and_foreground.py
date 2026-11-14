"""The conversation's verbs are a page you swipe in; a foreground must not blank the chat.

Two reports from the phone, 2026-11-12:

1. "every time i minimize the app and open it again, it shows chat as blank for a second then loads
   the chat, and it starts from somewhere within the chat instead of the end of it" — a foreground
   sends `gateway.ready` again, and the answer used to be `select(sid)`, which empties `transcript`
   before it asks the host anything and then replaces the rows after a fresh layout pass, so the
   scroll view kept its offset. Host read measured at ~4 s on a 2,500-row thread.
2. "change the 3dot menu into a full page upon swiping from right … then dont need the 3dot menu on
   chats anymore, just on main screen should be fine".
"""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MOBILE = ROOT / "Apps" / "HermesMobile" / "Views"
SCREEN = (MOBILE / "ConversationScreen.swift").read_text(encoding="utf-8")
DRAWER = (MOBILE / "ConversationDrawer.swift").read_text(encoding="utf-8")
LIST = (MOBILE / "BotListScreen.swift").read_text(encoding="utf-8")
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")


class TheChatHasOneDoor(unittest.TestCase):
    def test_the_bar_no_longer_carries_a_menu(self) -> None:
        self.assertNotIn("toolbarContent", SCREEN)
        self.assertNotIn("ellipsis.circle", SCREEN,
                         "the ⋯ moved into the drawer; a second door is what he asked to remove")

    def test_the_pill_keeps_its_portrait_and_title(self) -> None:
        # The nav bar is gone: the portrait and the name live in the floating pill, over the
        # transcript, the way the desktop draws them.
        self.assertNotIn("ToolbarItem(placement: .principal)", SCREEN)
        self.assertIn('.toolbar(.hidden, for: .navigationBar)', SCREEN)
        pill = SCREEN.split("private var pill: some View", 1)[1]
        self.assertIn("BotIconPortrait(", pill)
        self.assertIn("Text(title)", pill)

    def test_the_bot_list_keeps_its_own_menu(self) -> None:
        self.assertIn('Image(systemName: "ellipsis")', LIST,
                      "he asked for the list to keep it")

    def test_the_drawer_is_a_page_that_rises(self) -> None:
        self.assertIn(".overlay {", SCREEN)
        self.assertIn("ConversationDrawer(", SCREEN)
        # From the bottom, not the side: the bot's own page belongs to this chat.
        self.assertIn("transition(.move(edge: .bottom))", DRAWER)
        self.assertNotIn("NavigationStack", DRAWER, "a page belonging to the chat, not a second app")
        # And drawn above the chrome it covers, or the pill floats over the page.
        self.assertIn(".zIndex(2)", SCREEN)

    def test_it_carries_the_verbs_and_only_those(self) -> None:
        # The row names he settled on (reported 2026-11-14): "Library" for this bot's files,
        # "MCP" for the servers, "Search conversations" for the find, and a new Routines door.
        for label in ("Computer", "Library", "Skills", "MCP", "Routines", "Soul", "Memory",
                      "Search conversations", "Reset chat"):
            self.assertIn(f'"{label}"', DRAWER, f"{label} must still be reachable")
        for gone in ('row("Workspace"', 'row("MCP servers"', 'row("Search"'):
            self.assertNotIn(gone, DRAWER, f"{gone} was renamed")
        # Compaction, the unread sweep and spoken replies left this page: the first two happen on
        # their own, and the third belongs beside the microphone.
        # Settings is gone too: Edit in the header opens the same sheet.
        for gone in ("Mark all as read", "Speak replies", "Compacting…", '"Settings"'):
            self.assertNotIn(gone, DRAWER, f"{gone} should no longer be a row here")

    def test_the_search_field_is_glass_not_bare_text(self) -> None:
        # Tapping "Search conversations" used to open a field drawn straight onto the transcript,
        # so it read as part of the conversation instead of a control over it (reported
        # 2026-11-14). It wears the same glass as the bot pill above it.
        bar = SCREEN.split("private var searchBar: some View", 1)[1].split("private func moveSearch", 1)[0]
        self.assertIn(".hermeyGlass(Capsule(), interactive: true)", bar)
        self.assertNotIn("Tokens.surface", bar, "a flat fill is not the glass the rest of the chrome uses")

    def test_the_page_does_not_explain_how_to_leave_it(self) -> None:
        self.assertNotIn("Swipe down, or tap the back button", DRAWER)
        self.assertIn('accessibilityLabel("Close the bot page")', DRAWER)

    def test_it_closes_the_way_it_opened(self) -> None:
        # The back button is always in the corner; a downward swipe does the same thing.
        self.assertIn('accessibilityLabel("Close the bot page")', DRAWER)
        self.assertIn("value.translation.height > 80", DRAWER, "and a swipe down does")


class AnEdgeSwipeOpensIt(unittest.TestCase):
    def test_the_gesture_is_measured_from_the_trailing_edge(self) -> None:
        self.assertIn("private static let drawerEdge: CGFloat = 28", SCREEN)
        body = SCREEN.split("private func isDrawerSwipe", 1)[1].split("\n    }", 1)[0]
        self.assertIn("value.startLocation.x > transcriptWidth - Self.drawerEdge", body)
        self.assertIn("value.translation.width < -24", body)
        self.assertIn("abs(value.translation.width) > abs(value.translation.height)", body,
                      "a diagonal scroll must not open a panel")

    def test_the_transcript_width_is_measured_not_guessed(self) -> None:
        self.assertIn("@State private var transcriptWidth: CGFloat = 0", SCREEN)
        self.assertIn("transcriptWidth = geo.size.width", SCREEN,
                      "the edge is a geometry fact, never `UIScreen`")

    def test_an_edge_swipe_does_not_read_as_the_reader_parking_the_scroll(self) -> None:
        self.assertIn("guard !isDrawerSwipe(value) else { return }", SCREEN,
                      "the transcript's own drag handler must skip the drawer's gesture")

    def test_the_swipe_opens_the_drawer(self) -> None:
        body = SCREEN.split(".simultaneousGesture(DragGesture(minimumDistance: 14)", 1)[1].split("})", 1)[0]
        self.assertIn("isDrawerSwipe(value)", body)
        self.assertIn("showDrawer = true", body)


class AForegroundDoesNotBlankTheChat(unittest.TestCase):
    def test_a_ready_re_reads_in_place_rather_than_reselecting(self) -> None:
        body = MODEL.split("private func reconcile(afterReconnect", 1)[1].split("\n    }", 1)[0]
        self.assertIn("await refreshTranscript(sid)", body)
        self.assertNotIn("await select(sid)", body,
                         "select() empties the transcript first — that is the blank pane")

    def test_the_refresh_never_empties_what_is_on_screen(self) -> None:
        body = MODEL.split("private func refreshTranscript", 1)[1].split("\n    }\n", 1)[0]
        self.assertNotIn("transcript = []", body)
        self.assertIn("adopt(resumed, session: sid)", body)
        self.assertIn("transcriptReloads += 1", body,
                      "the shell needs the signal to land at the newest message")

    def test_a_failed_refresh_keeps_the_rows(self) -> None:
        body = MODEL.split("private func refreshTranscript", 1)[1].split("\n    }\n", 1)[0]
        failure = body.split("catch {", 1)[1]
        self.assertNotIn("transcript = []", failure,
                         "a failed re-read must not invent a data loss")
        self.assertIn("ClientLog.note", failure)

    def test_the_shell_lands_at_the_end_when_the_rows_are_replaced(self) -> None:
        self.assertIn(".onChange(of: model.transcriptReloads)", SCREEN)
        block = SCREEN.split(".onChange(of: model.transcriptReloads)", 1)[1].split("})", 1)[0]
        self.assertIn("settleAtBottom(proxy)", block)
        self.assertIn("followsStream = true", block,
                      "coming back to the app is not the reader parking mid-history")


if __name__ == "__main__":
    unittest.main()
