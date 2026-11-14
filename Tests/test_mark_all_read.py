"""Mark all as read: one act for the whole list, and a mark the host cannot outrun.

Opening a chat reads it. Nine badged bots and two badged rooms used to mean nine and two openings to
clear dots the person had no intention of reading.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")
MAC_SIDEBAR = (ROOT / "Apps" / "HermesMac" / "Sidebar" / "BotSidebarView.swift").read_text(encoding="utf-8")
MAC_PANEL = (ROOT / "Apps" / "HermesMac" / "Workspace" / "MacBotPanel.swift").read_text(encoding="utf-8")
MAC_HEADER = (ROOT / "Apps" / "HermesMac" / "Conversation" / "ConversationHeader.swift").read_text(encoding="utf-8")
IOS_LIST = (ROOT / "Apps" / "HermesMobile" / "Views" / "BotListScreen.swift").read_text(encoding="utf-8")
IOS_CHAT = (ROOT / "Apps" / "HermesMobile" / "Views" / "ConversationScreen.swift").read_text(encoding="utf-8")
# The chat's verbs moved from a bar menu into the page swiped in from the trailing edge.
IOS_CHAT_VERBS = (ROOT / "Apps" / "HermesMobile" / "Views" / "ConversationDrawer.swift").read_text(encoding="utf-8")


class MarkAllRead(unittest.TestCase):
    def setUp(self) -> None:
        self.body = MODEL.split("public func markAllRead(at date: Date = Date())", 1)[1].split("\n    }", 1)[0]

    def test_every_badge_is_cleared(self) -> None:
        self.assertIn("unreadBots.removeAll()", self.body)
        self.assertIn("unreadCounts.removeAll()", self.body)
        self.assertIn("roomUnreadCounts.removeAll()", self.body)

    def test_the_mark_is_written_so_the_dot_cannot_come_back(self) -> None:
        # The mark is the host's newest message for that bot when the sweep knows one: every
        # comparison is against host timestamps, so a device clock running fast would otherwise
        # place the mark in the host's future and silence that bot for good.
        self.assertIn("markRead(id, at: hostActivityStamp(id) ?? date)", self.body,
                      "clearing the badge without moving the mark re-badges on the next refresh")

    def test_rooms_are_marked_to_their_own_latest_seq(self) -> None:
        self.assertIn("markRoomRead(room.id, seq: room.latestSeq ?? 0)", self.body)
        self.assertNotIn("Int.max", self.body,
                         "a mark past the host's counter would hide the room's next message for good")

    def test_the_item_knows_when_it_would_do_nothing(self) -> None:
        self.assertIn("public var hasAnyUnread: Bool", MODEL)
        self.assertIn("!unreadCounts.isEmpty || !roomUnreadCounts.isEmpty",
                      MODEL.split("public var hasAnyUnread", 1)[1].split("\n", 1)[0])

    def test_the_verb_is_in_both_apps_menus(self) -> None:
        # Not the phone's chat page: it was a row there and it is gone, because the unread sweep
        # runs on the host and a chat is not the place to manage other chats.
        for name, text in (("Mac sidebar", MAC_SIDEBAR), ("Mac bot panel", MAC_PANEL),
                           ("phone list", IOS_LIST)):
            self.assertIn("Mark all as read", text, f"{name} menu is missing the verb")
        self.assertNotIn("Mark all as read", IOS_CHAT_VERBS)
        for name, text in (("Mac sidebar", MAC_SIDEBAR), ("Mac bot panel", MAC_PANEL),
                           ("phone list", IOS_LIST)):
            self.assertIn("markAllRead()", text, f"{name} menu does not call the model")
        # The phone's chat page no longer carries the row, but the screen still passes the closure
        # the page takes — the parameter stayed so the page's signature did not churn for a row that
        # is not drawn.
        self.assertIn("onMarkAllRead: { closeDrawer(); model.markAllRead() }", IOS_CHAT)
        # A disabled state, so the item never promises a no-op.
        for text in (MAC_SIDEBAR, IOS_LIST):
            self.assertIn("disabled(!", text)
        # The Mac's panel row is a `row(...)` with the flag, so the disabled state is a parameter.
        self.assertIn("isDisabled: !model.hasAnyUnread", MAC_PANEL)



if __name__ == "__main__":
    unittest.main()
