"""The conversation's verbs are a page you swipe in; a foreground must not blank the chat.

Two reports from Mohammad, 2026-11-12:

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

    def test_the_bar_keeps_its_portrait_and_title(self) -> None:
        self.assertIn("ToolbarItem(placement: .principal)", SCREEN)

    def test_the_bot_list_keeps_its_own_menu(self) -> None:
        self.assertIn('Image(systemName: "ellipsis")', LIST,
                      "he asked for the list to keep it")

    def test_the_drawer_is_a_page_not_a_sheet(self) -> None:
        self.assertIn(".overlay {", SCREEN)
        self.assertIn("ConversationDrawer(", SCREEN)
        self.assertIn("transition(.move(edge: .trailing))", DRAWER)
        self.assertNotIn("NavigationStack", DRAWER, "a panel belonging to the chat, not a second app")

    def test_it_carries_every_verb_the_menu_had(self) -> None:
        for label in ("Computer", "Workspace", "Skills", "MCP servers", "Search", "Settings",
                      "Compact", "Mark all as read", "Speak replies", "Reset chat"):
            self.assertIn(f'"{label}"' if label != "Compact" else 'isCompressing ? "Compacting…"',
                          DRAWER, f"{label} must survive the move")

    def test_the_compacting_state_survives_the_move(self) -> None:
        self.assertIn('isCompressing ? "Compacting…"', DRAWER)
        self.assertIn("ProgressView().controlSize(.mini)", DRAWER,
                      "a compaction runs for minutes; the page has to say so too")

    def test_it_closes_the_way_it_opened(self) -> None:
        self.assertIn("onTapGesture { onClose() }", DRAWER, "the dimmed conversation closes it")
        self.assertIn("value.translation.width > 60", DRAWER, "and a swipe back out does")


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
