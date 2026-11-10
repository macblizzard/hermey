"""The long-press card opens on the side that has room.

Reported: "when long pressing any message at the bottom of screen, the emojis disappear". The popover
was asked for with a fixed `arrowEdge: .top` — always below the row. At the bottom of the screen there
is no space below, so iOS placed what fitted and clipped the rest: the six reactions are the first thing
in the card, so they were exactly what fell off, leaving slivers of colour along the card's top edge.
"""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VIEW = (ROOT / "Apps" / "HermesMobile" / "Views" / "MobileTranscript.swift").read_text(encoding="utf-8")


class TheCardChoosesItsSide(unittest.TestCase):
    def test_the_arrow_edge_is_not_fixed(self) -> None:
        self.assertIn("arrowEdge: opensAbove ? .bottom : .top", VIEW,
                      "a fixed .top is the bug: below-the-row cannot work at the bottom of the screen")
        self.assertNotIn("attachmentAnchor: .rect(.bounds), arrowEdge: .top)", VIEW)

    def test_the_row_reports_where_it_is(self) -> None:
        self.assertIn("RowFrameKey", VIEW)
        self.assertIn("geo.frame(in: .global)", VIEW)
        self.assertIn("private struct RowFrameKey: PreferenceKey", VIEW)

    def test_the_decision_is_made_before_presenting(self) -> None:
        raise_block = VIEW.split("private func raiseActions()", 1)[1].split("private var actionCard", 1)[0]
        self.assertIn("opensAbove =", raise_block)
        self.assertLess(raise_block.index("opensAbove ="), raise_block.index("showingActions = true"),
                        "the side must be chosen while the popover is still closed")

    def test_the_arrow_points_at_the_press_not_at_the_row(self) -> None:
        # A long message's rectangle is taller than the screen: anchoring to it put the card at the
        # top of the page. The anchor is the press point.
        self.assertIn("attachmentAnchor: .point(anchorPoint)", VIEW)
        self.assertNotIn("attachmentAnchor: .rect(.bounds)", VIEW)
        self.assertIn("DragGesture(minimumDistance: 0, coordinateSpace: .local)", VIEW)
        self.assertIn("value.startLocation", VIEW)
        self.assertEqual(VIEW.count("simultaneousGesture(pressLocator)"), 2,
                         "both kinds of message must report where the press landed")

    def test_the_side_is_judged_from_the_pressed_line(self) -> None:
        raise_block = VIEW.split("private func raiseActions()", 1)[1].split("private var actionCard", 1)[0]
        self.assertIn("let pressedY = rowFrame.minY + pressPoint.y", raise_block,
                      "the row's middle says nothing about a message taller than the screen")
        self.assertIn("spaceAbove > spaceBelow", raise_block,
                      "with room on neither side, the larger half wins")

    def test_both_message_kinds_go_through_one_door(self) -> None:
        self.assertEqual(VIEW.count("onLongPressGesture(minimumDuration: 0.35) { raiseActions() }"), 2,
                         "the owner's bubble and the bot's reply must not disagree")
        self.assertNotIn("onLongPressGesture(minimumDuration: 0.35) { showingActions = true }", VIEW)

    def test_the_reactions_are_still_first(self) -> None:
        card = VIEW.split("private var actionCard", 1)[1]
        first_reaction = card.index("QuickReactionRow")
        first_row = card.index('actionRow("Copy"')
        self.assertLess(first_reaction, first_row,
                        "the emoji are the point of the card; they stay at the top of it")


if __name__ == "__main__":
    unittest.main()
