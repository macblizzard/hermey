"""Rows arriving above the reading position must not move the page under the reader.

Reported 2026-11-22: scrolling *up* into older messages shifted the transcript under the finger on
every page that loaded, while scrolling down over rows already drawn was fine. The log showed
`paging resume kept 173 earlier rows` / `resume kept 305 earlier rows` throughout, i.e. earlier pages
were being merged in while the reader was mid-history.

The insert site is `AppModel.loadEarlierHistory()` — `transcript.insert(contentsOf: fresh, at: 0)`.
A prepend is the one transcript change that moves content the reader is *not* looking at: rows go in
above the viewport, the scroll view's origin does not move, and every row under the finger slides
down by exactly the height of the page that arrived. The Mac transcript drew no reaction at all —
its `onChange(of: model.transcript.count)` only called `follow()`, which is a no-op while
`followsNewMessages` is off.

Two techniques, one per platform, both pinned here:

* **Mac** — `TranscriptAnchorKeeper` (`Apps/HermesMac/Conversation/`). The transcript arms a hold
  from `onChange` (*before* the layout), and the AppKit half adds the document's growth back to the
  clip view's origin. The clip view is used because the alternative — `scrollPosition(id:)` with
  `scrollTargetLayout` — would be a fourth owner of a position this pane already gives to
  `ScrollViewReader`, to `ScrollViewportProbe`'s jump-to-newest, and to the keyboard scroll keys.
  Row-geometry restoration is also inexact in a `LazyVStack`: rows above the viewport are estimated,
  so the anchored row is re-measured as the reader scrolls and the position drifts per page.
* **iOS** — `ConversationScreen` already re-anchors: on `earlierLoads` it scrolls
  `model.earlierAnchor` (the fold) back to `.top` and returns *before* the follow-to-bottom branch.
  Equivalent in kind — row-pinned rather than pixel-exact — so it is left alone; the tests below hold
  it still rather than rewire it.

What is pinned here is the mechanism and its wiring; whether the gesture *feels* anchored can only be
confirmed on a device (see the report). There is no Swift toolchain on this box, so these are
source-shape contracts, the same way `test_streaming_scroll_stability.py` is.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAC = ROOT / "Apps" / "HermesMac"
SCROLL = (MAC / "Conversation" / "TranscriptScroll.swift").read_text(encoding="utf-8")
KEEPER = (MAC / "Conversation" / "TranscriptAnchorKeeper.swift").read_text(encoding="utf-8")
IOS_SCREEN = (ROOT / "Apps" / "HermesMobile" / "Views" / "ConversationScreen.swift").read_text(encoding="utf-8")


def code(source: str) -> str:
    """The file with its `//` lines removed.

    Doc comments here explain the bug being replaced and name the shapes that were rejected, so a
    `not in` assertion has to look at the code, not at the prose around it.
    """
    return "\n".join(line for line in source.splitlines() if not line.strip().startswith("//"))


def block(source: str, start: str, end: str) -> str:
    return source.split(start, 1)[1].split(end, 1)[0]


class TheMacHoldsTheReadingPosition(unittest.TestCase):
    """The desktop used to draw no reaction to a prepend at all."""

    def test_the_keeper_is_installed_in_the_scroll_content(self) -> None:
        # Inside `transcript`, i.e. inside the `ScrollView`: a background on anything outside it
        # would never find the clip view to move.
        body = block(SCROLL, "private var transcript: some View {", "/// The rows as they are drawn")
        self.assertIn("ScrollViewReader", body)
        self.assertIn(".background(TranscriptAnchorKeeper(hold: anchorHold))", body)
        self.assertIn("ScrollViewportProbe", body, "the jump-to-newest probe must survive alongside it")

    def test_the_merge_arms_the_hold_before_the_layout(self) -> None:
        count_body = block(SCROLL, ".onChange(of: model.transcript.count)", ".onChange(of: model.earlierLoads)")
        self.assertIn("olderRowsArrived(grewFrom: oldCount, to: newCount)", count_body)
        self.assertIn("anchorHold.hold(pinnedToBottom: followsBottom)", count_body)
        self.assertIn("follow(proxy)", count_body, "the live tail still follows what lands at the bottom")

        # The model's own counter is the door that does not depend on the row-identity guess.
        loads_body = block(SCROLL, ".onChange(of: model.earlierLoads)", ".onChange(of: model.streamingText)")
        self.assertIn("anchorHold.hold(pinnedToBottom: followsBottom)", loads_body)

    def test_a_prepend_is_told_from_a_new_turn(self) -> None:
        body = block(SCROLL, "private func olderRowsArrived(grewFrom old: Int, to new: Int) -> Bool {",
                     "\n    }")
        self.assertIn("new > old", body, "growth is also how a reply lands")
        self.assertIn("first != previous", body,
                      "a merge of older rows changes which row is first; a new turn does not")
        self.assertIn("old > 0", body, "opening a conversation is not a merge")
        self.assertIn("firstRowID = first", body, "the next change has to be compared to this one")
        self.assertIn("contains { $0.id == previous }", body,
                      "a resume that swapped the transcript has no row in common to hold to")

    def test_a_pinned_reader_is_not_held(self) -> None:
        # The guard is what keeps "at the bottom" following new messages exactly as before.
        body = block(KEEPER, "func hold(pinnedToBottom: Bool) {", "\n    }")
        self.assertIn("guard !pinnedToBottom", body)
        self.assertIn("armed = now", body)

    def test_one_merge_keeps_one_snapshot(self) -> None:
        # Three doors arm for the same merge (the tap, `earlierLoads`, the row count), and the
        # earliest snapshot is the only one taken before the rows moved. The rest may only widen
        # the window.
        body = block(KEEPER, "func hold(pinnedToBottom: Bool) {", "\n    }")
        self.assertIn("if armed != nil, isLive {", body)
        self.assertLess(body.index("if armed != nil, isLive {"), body.index("armed = now"),
                        "a live arm must not be re-snapshotted after the rows have moved")

    def test_the_position_is_read_at_arm_time(self) -> None:
        # The pre-merge origin only exists before the rows are laid out, so the arm has to read the
        # scroll view itself — not infer it from a layout that has already happened.
        body = block(KEEPER, "func hold(pinnedToBottom: Bool) {", "\n    }")
        self.assertIn("keeper.readingPosition", body)
        position = block(KEEPER, "var readingPosition: TranscriptAnchorHold.Position? {", "\n        }")
        self.assertIn("scroll.contentView.bounds.origin.y", position)
        self.assertIn("document.frame.height", position)

    def test_the_growth_is_added_to_the_clip_origin(self) -> None:
        body = block(KEEPER, "private func contentChanged() {", "\n        }")
        self.assertIn("growth = document.frame.height - armed.height", body,
                      "the page's own height is the shift; nothing has to know which row is where")
        self.assertIn("let target = armed.origin + growth", body,
                      "absolute, so a merge laid out in two chunks lands in the same place")
        self.assertIn("self?.restore(to: target)", body)
        restore = block(KEEPER, "private func restore(to target: CGFloat) {", "\n        }")
        self.assertIn("clip.scroll(to: NSPoint(", restore)

    def test_the_restore_defers_to_the_layout_that_moved_the_content(self) -> None:
        body = block(KEEPER, "private func contentChanged() {", "\n        }")
        self.assertIn("DispatchQueue.main.async", body,
                      "restoring inside the layout pass measures an origin SwiftUI is still moving")
        restore = block(KEEPER, "private func restore(to target: CGFloat) {", "\n        }")
        self.assertIn("if abs(clip.bounds.origin.y - target) > 0.5", restore,
                      "a merge SwiftUI already held itself must not be moved twice")
        self.assertLess(restore.index("applied = target"), restore.index("clip.scroll(to:"),
                        "our own bounds change must not read as a drag")

    def test_nothing_is_compensated_unless_a_merge_is_in_flight(self) -> None:
        body = block(KEEPER, "private func contentChanged() {", "\n        }")
        # A streaming reply grows the document below the fold; compensating that would walk the
        # reader away from the row they are on for every token.
        self.assertLess(body.index("hold.isLive"), body.index("let target = armed.origin + growth"),
                        "growth below the fold must not be folded into a held position")
        self.assertIn("hold.release()", body.split("hold.isLive", 1)[1])

    def test_the_merge_is_not_animated(self) -> None:
        for source in (code(KEEPER), code(block(SCROLL, ".onChange(of: model.transcript.count)",
                                                ".onChange(of: model.streamingText)"))):
            self.assertNotIn("withAnimation", source)
            self.assertNotIn(".animation(", source)
            self.assertNotIn("animator()", source, "an eased clip move is the jump it is meant to hide")

    def test_a_finger_beats_the_hold(self) -> None:
        body = block(KEEPER, "private func clipMoved() {", "\n        }")
        self.assertIn("abs(scroll.contentView.bounds.origin.y - applied) > 1.5", body)
        self.assertIn("hold.release()", body, "never fight a drag, a page key or the jump-to-newest control")

    def test_a_new_conversation_does_not_inherit_the_hold(self) -> None:
        body = block(SCROLL, "private func openSession(_ proxy: ScrollViewProxy) {", "\n    }")
        self.assertIn("anchorHold.release()", body)
        self.assertIn("firstRowID = nil", body, "the new conversation's first row is not an 'earlier' row")
        self.assertIn("followsBottom = true", body)


class ThePhoneAlreadyAnchors(unittest.TestCase):
    """The phone got this when paging landed; the Mac never did. Held still, not rewritten."""

    # The screen has more than one `transcript.count` observer (one speaks a new reply aloud), so
    # the block is taken from the paging comment and not from the modifier name.
    PHONE_MERGE = IOS_SCREEN.split("// Older rows arriving", 1)[1].split(".onChange(of: model.streamingText)", 1)[0]

    def test_the_phone_re_anchors_on_the_model_counter(self) -> None:
        body = self.PHONE_MERGE
        self.assertIn("model.earlierLoads != lastSeenEarlierLoads", body)
        self.assertIn("proxy.scrollTo(anchor, anchor: .top)", body)

    def test_the_prepend_returns_before_the_follow(self) -> None:
        body = self.PHONE_MERGE
        self.assertLess(body.index("proxy.scrollTo(anchor, anchor: .top)"), body.index("return"),
                        "the anchor and the follow-to-bottom are alternatives, not both")
        self.assertLess(body.index("return"), body.index("follow(proxy"),
                        "older rows arriving must never drag the phone to the newest message")
        self.assertNotIn("withAnimation", body)

    def test_the_fold_the_phone_anchors_to_is_the_row_the_reader_knew(self) -> None:
        # `earlierAnchor` is set by `loadEarlierHistory` to the transcript's first row *before* the
        # insert, which is what fixes the merge in place. Pinned as a contract on the model side of
        # a file this test does not own: if that changes, the phone's anchor is silently wrong.
        model = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")
        self.assertIn("let fold = transcript.first?.id", model)
        self.assertIn("earlierAnchor = fold", model)


class PagingStillHasItsGuards(unittest.TestCase):
    """Both behaviours this fix must not buy at the expense of."""

    def test_the_load_earlier_row_is_disabled_while_a_page_is_in_flight(self) -> None:
        self.assertIn("EarlierHistoryRow(isLoading: model.loadingEarlier", SCROLL)
        self.assertIn("EarlierHistoryRow(isLoading: model.loadingEarlier", IOS_SCREEN)

    def test_the_mac_tap_arms_the_hold_before_the_request(self) -> None:
        # The page is a round trip away, and the arm has to exist before it can land. The counters
        # re-arm on arrival; this one is strictly earlier than either of them.
        body = block(SCROLL, "EarlierHistoryRow(isLoading: model.loadingEarlier", "}\n            }")
        self.assertIn("anchorHold.hold(pinnedToBottom: followsBottom)", body)
        self.assertLess(body.index("anchorHold.hold"), body.index("model.loadEarlierHistory"))

    def test_the_live_tail_still_follows(self) -> None:
        self.assertIn("static let followsNewMessages", SCROLL)
        follow = block(SCROLL, "private func follow(_ proxy: ScrollViewProxy) {", "\n    }")
        self.assertIn("followsBottom", follow)
        self.assertIn("search.ownsScrollPosition", follow)
        self.assertIn("scrollRequest += 1", follow)


if __name__ == "__main__":
    unittest.main()
