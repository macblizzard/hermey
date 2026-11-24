"""Group chats get the heading the phone has always drawn over them.

Reported: on iOS every group row sits under its heading; on the Mac the same rows appeared with no
caption at all, above a bare divider, so the rows at the top of the panel could not be read as
anything in particular. The Mac had a comment defending the omission — "CHATS over a list of chats
told the reader what they were already looking at" — which was true of the bots and never true of a
room: a room row is a bot avatar cluster with a room name, and nothing said so.

The heading is the categories' own control: chevron, name, count, folded and remembered on this
device, in the same map and with the same animation. The words come from one place
(`BotGrouping.roomsName`) so the phone and the Mac cannot drift apart, and the order is the phone's:
group chats above the bots, then Pinned, the categories, Uncategorized.
"""

from __future__ import annotations

import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
GROUPING = REPO_ROOT / "Sources" / "HermesAppKit" / "BotGrouping.swift"
MAC_LIST = REPO_ROOT / "Apps" / "HermesMac" / "Sidebar" / "SidebarBotList.swift"
IOS_LIST = REPO_ROOT / "Apps" / "HermesMobile" / "Views" / "BotListScreen.swift"


def member(text: str, signature: str) -> str:
    start = text.index(signature)
    rest = text[start:]
    return rest[: rest.index("\n    }\n") + len("\n    }\n")]


class TheWordsHaveOneSource(unittest.TestCase):
    def setUp(self) -> None:
        self.grouping = GROUPING.read_text(encoding="utf-8")

    def test_the_heading_is_a_reserved_id_beside_the_two_the_app_already_owns(self) -> None:
        self.assertIn('public static let roomsID = "__rooms"', self.grouping)
        self.assertIn('public static let roomsName = "Group chats"', self.grouping)
        # Namespaced like Pinned and Uncategorized: a host category id can never collide with it.
        self.assertIn('public static let pinnedID = "__pinned"', self.grouping)
        self.assertIn('public static let uncategorizedID = "__uncategorized"', self.grouping)

    def test_neither_surface_spells_it_itself(self) -> None:
        for path in (MAC_LIST, IOS_LIST):
            text = path.read_text(encoding="utf-8")
            self.assertNotIn('"GROUP CHATS"', text, f"{path.name} still spells the heading out")
            self.assertNotIn('"Group chats"', text, f"{path.name} still spells the heading out")
            self.assertIn("BotGrouping.roomsName", text, f"{path.name} does not read the one heading")


class ThePhoneStillHeadsItsRooms(unittest.TestCase):
    def test_the_heading_scrolls_with_the_rows_like_every_other(self) -> None:
        body = member(IOS_LIST.read_text(encoding="utf-8"), "private var roomsSection: some View")
        self.assertIn("scrollingHeading { listHeading(BotGrouping.roomsName.uppercased()) }", body)
        self.assertIn("ForEach(model.rooms)", body)


class TheMacHeadsThemToo(unittest.TestCase):
    def setUp(self) -> None:
        self.text = MAC_LIST.read_text(encoding="utf-8")

    def test_the_caption_is_drawn_above_the_room_rows(self) -> None:
        rows = member(self.text, "private var rows: some View")
        self.assertIn("roomsCaption", rows)
        self.assertLess(rows.index("roomsCaption"), rows.index("ForEach(roomRows)"),
                        "a heading under its rows is a footer")

    def test_the_fold_is_the_categories_fold(self) -> None:
        # Same control: chevron, the name, the count. A plain label would be a second kind of
        # heading on one list — and it could not collapse, which is what was asked for.
        body = member(self.text, "private var roomsCaption: some View")
        self.assertIn('Image(systemName: roomsCollapsed ? "chevron.right" : "chevron.down")', body)
        self.assertIn("BotGrouping.roomsName.uppercased()", body)
        self.assertIn('Text("\\(roomRows.count)")', body)
        self.assertIn("toggleRoomsCollapsed()", body)
        self.assertIn("withAnimation(.easeOut(duration: 0.12))", body)

    def test_collapsing_it_hides_the_rows_and_the_divider_with_them(self) -> None:
        rows = member(self.text, "private var rows: some View")
        self.assertIn("if !roomsCollapsed {", rows)
        # The divider belongs to the rows, so a folded group is one line and nothing else.
        after = rows.split("if !roomsCollapsed {", 1)[1]
        self.assertIn("Divider().padding(.horizontal, 8).padding(.vertical, 4)", after)
        self.assertLess(after.index("ForEach(roomRows)"), after.index("Divider().padding"))

    def test_the_state_lives_in_the_map_the_categories_use(self) -> None:
        self.assertIn("private var roomsCollapsed: Bool { collapsedGroups[BotGrouping.roomsID] == true }",
                      self.text)
        # One writer for both kinds of heading, so a second mechanism cannot appear beside it.
        self.assertIn("private func toggleCollapsed(_ group: BotGroup) { setCollapsed(group.id) }", self.text)
        self.assertIn("private func toggleRoomsCollapsed() { setCollapsed(BotGrouping.roomsID) }", self.text)
        self.assertIn('@AppStorage("hermey.collapsedBotGroups.mac")', self.text)

    def test_the_block_sizes_for_the_heading_and_for_the_fold(self) -> None:
        # The panel's height is computed, not measured: a heading that is drawn but not counted
        # clips the last row, and rows counted while folded leave a gap.
        body = member(self.text, "private var captionCount:")
        self.assertIn("(roomRows.isEmpty ? 0 : 1)", body)
        height = member(self.text, "private var listHeight: CGFloat")
        self.assertIn("roomRows.isEmpty || roomsCollapsed", height)
        self.assertIn("CGFloat(captionCount) * SidebarBotList.captionHeight", height)

    def test_the_rooms_still_come_first(self) -> None:
        # The phone's order, unchanged: group chats above the bots, then Pinned and the categories.
        rows = member(self.text, "private var rows: some View")
        self.assertLess(rows.index("roomsCaption"), rows.index("ForEach(model.botGroups)"))


if __name__ == "__main__":
    unittest.main()
