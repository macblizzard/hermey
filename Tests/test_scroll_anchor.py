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
  from `onChange` (*before* the layout), and the AppKit half moves the clip view down by the growth
  the prepend added above it. The clip view is used because the alternative — `scrollPosition(id:)`
  with `scrollTargetLayout` — would be a fourth owner of a position this pane already gives to
  `ScrollViewReader`, to `ScrollViewportProbe`'s jump-to-newest, and to the keyboard scroll keys.
  Row-geometry restoration is also inexact in a `LazyVStack`: rows above the viewport are estimated,
  so the anchored row is re-measured as the reader scrolls and the position drifts per page.

  Two further rules, each fixing half of the "sticky and jumps" report on macOS:

  * **Arming is only ever an explicit prepend.** The hold used to arm on
    `.onChange(of: model.transcript.count)` when a three-fact guess said the rows had gone in at the
    top. A resume's merge satisfies that guess without prepending: `TranscriptPaging.merge` falls
    back to the incoming page when the two do not overlap, so the count grows and the first row
    changes while the reader's rows are still in it. The guess and its `firstRowID` state are gone;
    `model.earlierLoads` and the "load earlier" tap are the only doors.
  * **One prepend, one correction.** The keeper used to re-apply `armed.origin + growth` on *every*
    document-size change while its 0.75 s window was live, and a `LazyVStack` hands one prepend
    several heights as it re-measures — each one a fresh scroll, which is the sticky feel. It now
    tracks how much growth it has already applied and moves by `growth - appliedGrowth` from where it
    left the clip, so a height it has answered for is not answered again.

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

# The arming door's signature. Named once so the block extractions below survive the `reason:` label
# a log line needed.
HOLD_SIGNATURE = 'func hold(pinnedToBottom: Bool, reason: String = "unspecified") {'
RELEASE_SIGNATURE = 'func release(because reason: String = "unspecified") {'


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
        # The model's own counter, bumped by the one path that prepends, is the door that names the
        # event rather than guessing it.
        loads_body = block(SCROLL, ".onChange(of: model.earlierLoads)", ".onChange(of: model.streamingText)")
        self.assertIn("anchorHold.hold(pinnedToBottom: followsBottom", loads_body)
        self.assertIn("earlierLoads", loads_body, "the log line has to say which door armed")

        # The tap is strictly earlier than the counter: the page is a round trip away.
        tap = block(SCROLL, "EarlierHistoryRow(isLoading: model.loadingEarlier", "}\n            }")
        self.assertIn("anchorHold.hold(pinnedToBottom: followsBottom", tap)

    def test_only_the_two_prepend_doors_arm(self) -> None:
        # Exactly two, and neither of them is the row count. A third door is how the guess came back.
        self.assertEqual(code(SCROLL).count("anchorHold.hold("), 2,
                         "arming is the model counter and the tap; nothing else speaks for a prepend")

    def test_a_row_count_change_never_arms_the_hold(self) -> None:
        # The count grows for a turn at the bottom, for a rewind, and for a resume whose merged
        # prefix differs from the one on screen — that last one used to arm the keeper for a change
        # nobody asked for. Following still happens here; holding does not.
        count_body = block(SCROLL, ".onChange(of: model.transcript.count)", ".onChange(of: model.earlierLoads)")
        self.assertNotIn("anchorHold.hold", count_body,
                         "a count change is not a prepend; a resume's merge grows it too")
        self.assertNotIn("olderRowsArrived", count_body)
        self.assertIn("follow(proxy)", count_body, "the live tail still follows what lands at the bottom")

    def test_the_row_identity_guess_is_gone(self) -> None:
        # `olderRowsArrived(grewFrom:to:)` — count grew, first row changed, previous first row still
        # present — is satisfied by a merge that prepends nothing. Its state went with it.
        source = code(SCROLL)
        self.assertNotIn("olderRowsArrived", source)
        self.assertNotIn("grewFrom", source)
        self.assertNotIn("firstRowID", source,
                         "the state only existed to compare one change's first row to the last one's")

    def test_a_pinned_reader_is_not_held(self) -> None:
        # The guard is what keeps "at the bottom" following new messages exactly as before.
        body = block(KEEPER, HOLD_SIGNATURE, "\n    }")
        self.assertIn("guard !pinnedToBottom", body)
        self.assertIn("armed = now", body)

    def test_one_merge_keeps_one_snapshot(self) -> None:
        # Two doors arm for the same prepend (the tap, then the counter when the page lands), and
        # the earliest snapshot is the only one taken before the rows moved. The rest may only widen
        # the window.
        body = block(KEEPER, HOLD_SIGNATURE, "\n    }")
        self.assertIn("if armed != nil, isLive {", body)
        self.assertLess(body.index("if armed != nil, isLive {"), body.index("armed = now"),
                        "a live arm must not be re-snapshotted after the rows have moved")

    def test_the_position_is_read_at_arm_time(self) -> None:
        # The pre-merge origin only exists before the rows are laid out, so the arm has to read the
        # scroll view itself — not infer it from a layout that has already happened.
        body = block(KEEPER, HOLD_SIGNATURE, "\n    }")
        self.assertIn("keeper.readingPosition", body)
        position = block(KEEPER, "var readingPosition: TranscriptAnchorHold.Position? {", "\n        }")
        self.assertIn("scroll.contentView.bounds.origin.y", position)
        self.assertIn("document.frame.height", position)

    def test_a_new_arm_starts_a_new_page(self) -> None:
        # The keeper keeps a running total of the growth it has already corrected. That total belongs
        # to one page: carried into the next, its first correction would be the difference between
        # two unrelated heights.
        hold_body = block(KEEPER, HOLD_SIGNATURE, "\n    }")
        self.assertIn("generation &+= 1", hold_body)
        live = block(KEEPER, "if armed != nil, isLive {", "guard let now = keeper.readingPosition")
        self.assertNotIn("generation", live, "widening the window is not a new page")
        body = block(KEEPER, "private func contentChanged() {", "\n        }")
        self.assertIn("generation != hold.generation", body)
        self.assertIn("reset()", body, "the applied total has to start over with the new baseline")

    def test_one_prepend_produces_one_correction(self) -> None:
        body = block(KEEPER, "private func contentChanged() {", "\n        }")
        self.assertIn("appliedGrowth", body,
                      "what has already been corrected is the number that makes a second call a no-op")
        self.assertIn("let delta = growth - appliedGrowth", body,
                      "only the growth since the last correction, never the whole of it")
        self.assertIn("guard abs(delta) > 0.5 else { return }", body,
                      "a height this hold already answered for must not move the clip again")
        self.assertNotIn("let target = armed.origin", body,
                         "re-deriving the target from the pre-merge snapshot is the repeated scroll")
        self.assertIn("appliedGrowth = growth", body,
                      "each applied correction has to be remembered as applied")
        # A position SwiftUI already held itself is credited, not corrected again: the clip may
        # already be part of the way down when the first size change arrives.
        self.assertIn("let moved = scroll.contentView.bounds.origin.y - armed.origin", body)
        self.assertIn("appliedGrowth = max(0, min(moved, growth))", body,
                      "credit the layout's own move, capped at the page's growth")

    def test_a_second_growth_while_armed_corrects_by_the_delta_only(self) -> None:
        # The structural form of the arithmetic: `growth` is measured from the arm-time height, the
        # delta is what is left after what has been applied, and the move is relative to where the
        # keeper left the clip — so two growth events for one prepend give two *disjoint* moves
        # rather than the same absolute target twice.
        body = block(KEEPER, "private func contentChanged() {", "\n        }")
        growth = body.index("let growth = document.frame.height - armed.height")
        delta = body.index("let delta = growth - appliedGrowth")
        # The credit for a move SwiftUI made itself happens before the delta is taken.
        self.assertLess(body.index("appliedGrowth = max(0, min(moved, growth))"), delta)
        target = body.index("let target = from + delta")
        self.assertLess(growth, delta)
        self.assertLess(delta, target, "the target is the delta added to where the clip already is")
        self.assertIn("let from = committedOrigin ?? scroll.contentView.bounds.origin.y", body,
                      "a correction queued before the last one ran must not measure the same origin twice")
        self.assertIn("committedOrigin = target", body)
        # The applied total advances *before* the async hop, so a size change that lands in between
        # is measured against the correction that is already on its way.
        self.assertLess(body.index("appliedGrowth = growth"), body.index("DispatchQueue.main.async"))

    def test_the_restore_defers_to_the_layout_that_moved_the_content(self) -> None:
        body = block(KEEPER, "private func contentChanged() {", "\n        }")
        self.assertIn("DispatchQueue.main.async", body,
                      "restoring inside the layout pass measures an origin SwiftUI is still moving")
        restore = block(KEEPER, "private func restore(to target: CGFloat) {", "\n        }")
        self.assertIn("if abs(clip.bounds.origin.y - target) > 0.5", restore,
                      "a merge SwiftUI already held itself must not be moved twice")
        self.assertLess(restore.index("applied = target"), restore.index("clip.scroll(to:"),
                        "our own bounds change must not read as a drag")
        self.assertIn("clip.scroll(to: NSPoint(", restore)

    def test_nothing_is_compensated_unless_a_merge_is_in_flight(self) -> None:
        body = block(KEEPER, "private func contentChanged() {", "\n        }")
        # A streaming reply grows the document below the fold; compensating that would walk the
        # reader away from the row they are on for every token.
        self.assertLess(body.index("hold.isLive"), body.index("let growth = document.frame.height"),
                        "growth below the fold must not be folded into a held position")
        self.assertIn("hold.release(", body.split("hold.isLive", 1)[1])

    def test_the_merge_is_not_animated(self) -> None:
        for source in (code(KEEPER), code(block(SCROLL, ".onChange(of: model.transcript.count)",
                                                ".onChange(of: model.streamingText)"))):
            self.assertNotIn("withAnimation", source)
            self.assertNotIn(".animation(", source)
            self.assertNotIn("animator()", source, "an eased clip move is the jump it is meant to hide")

    def test_a_finger_beats_the_hold(self) -> None:
        body = block(KEEPER, "private func clipMoved() {", "\n        }")
        self.assertIn("abs(scroll.contentView.bounds.origin.y - applied) > 1.5", body)
        self.assertIn("hold.release(", body, "never fight a drag, a page key or the jump-to-newest control")

    def test_a_new_conversation_does_not_inherit_the_hold(self) -> None:
        body = block(SCROLL, "private func openSession(_ proxy: ScrollViewProxy) {", "\n    }")
        self.assertIn("anchorHold.release(", body)
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
        self.assertIn("anchorHold.hold(pinnedToBottom: followsBottom, reason:", body)
        self.assertLess(body.index("anchorHold.hold"), body.index("model.loadEarlierHistory"))

    def test_the_live_tail_still_follows(self) -> None:
        self.assertIn("static let followsNewMessages", SCROLL)
        follow = block(SCROLL, "private func follow(_ proxy: ScrollViewProxy) {", "\n    }")
        self.assertIn("followsBottom", follow)
        self.assertIn("search.ownsScrollPosition", follow)
        self.assertIn("scrollRequest += 1", follow)


class TheLogSaysWhichPathRan(unittest.TestCase):
    """Category `paging`, so the next build's log can be read instead of guessed at.

    Every line carries the `anchor ` prefix, which is what makes the answer to "was the keeper
    involved in this jump?" a grep rather than a re-run: the four facts are arming (with the origin,
    the height and the door), release, each correction with its delta and both origins, and — the one
    that rules the keeper out — a size change that arrived with no hold at all.
    """

    def test_the_hold_logs_its_arm_with_the_numbers_it_snapshotted(self) -> None:
        body = block(KEEPER, HOLD_SIGNATURE, "\n    }")
        self.assertIn('category: "paging"', body)
        self.assertIn("anchor armed", body, "the arm has to be in the log")
        # The note wraps across source lines; the facts have to be inside the one statement.
        joined = body[body.index("anchor armed"):][:400]
        self.assertIn("anchorPoints(now.origin)", joined)
        self.assertIn("anchorPoints(now.height)", joined)
        self.assertIn("reason", joined, "which door armed — the tap, or the counter")
        # The two ways an arm does not happen are as important as the one where it does.
        self.assertIn("anchor skipped — pinned to bottom", body)
        self.assertIn("anchor skipped — no clip view yet", body)
        self.assertIn("anchor kept —", body, "a second door for the same page must not look like a re-arm")

    def test_the_release_is_logged_with_where_the_clip_ended(self) -> None:
        body = block(KEEPER, RELEASE_SIGNATURE, "\n    }")
        self.assertIn('category: "paging"', body)
        self.assertIn("anchor released", body)
        self.assertIn("armed.origin", body, "the origin that was held, so a drift is visible in the log")
        self.assertIn("keeper?.readingPosition?.origin", body, "and where the clip actually ended up")
        self.assertIn("reason", body, "settled, reader moved, or the window closed")

    def test_each_correction_logs_its_delta_and_both_origins(self) -> None:
        body = block(KEEPER, "private func contentChanged() {", "\n        }")
        line = [l for l in body.splitlines() if "anchor corrected" in l]
        self.assertTrue(line, "one line per correction, with the arithmetic on it")
        joined = body[body.index("anchor corrected"):body.index("DispatchQueue.main.async")]
        for fact in ("anchorPoints(delta)", "anchorPoints(from)", "anchorPoints(target)",
                     "anchorPoints(growth)"):
            self.assertIn(fact, joined, f"{fact} belongs on the correction line")
        self.assertIn('category: "paging"', body)

    def test_a_size_change_with_no_hold_is_recorded_so_the_keeper_can_be_ruled_out(self) -> None:
        body = block(KEEPER, "private func noteChangeWithNoHold", "\n        }")
        self.assertIn("anchor not involved", body)
        self.assertIn('category: "paging"', body)
        self.assertIn("timeIntervalSince(lastIdleNote)", body,
                      "throttled: a streaming reply grows the document once per token, and the ring "
                      "holds 400 lines")
        called = block(KEEPER, "private func contentChanged() {", "\n        }")
        idle = called.split("hold.isLive", 1)[1]
        self.assertIn("noteChangeWithNoHold(", idle.split("let growth", 1)[0],
                      "the no-hold path is where it is written, before any arithmetic")


if __name__ == "__main__":
    unittest.main()
