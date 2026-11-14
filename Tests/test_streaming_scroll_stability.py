"""A bot that is still writing must not fight the reader.

Reported: the chat screen flickers while a reply streams, and scrolling up to read earlier messages
is pulled back to the bottom for as long as the bot keeps working.

Two causes, both in the transcript's scroll handling:

* every streaming change (`streamingText`, `reasoningText`, a tool appearing) called `scrollTo`
  directly, so a reply arriving at tens of tokens a second asked the scroll view to re-lay itself out
  tens of times a second. That is the flicker.
* "is the end on screen" came from a sentinel's `onAppear`/`onDisappear`. A lazy row appearing says
  nothing reliable about the reader's position during streaming, so the flag flipped back to true and
  the next token dragged the transcript down.

The fix is a measured distance plus a separate intent flag (`followsStream`), with one coalesced
scroll in flight at a time.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCREEN = ROOT / "Apps" / "HermesMobile" / "Views" / "ConversationScreen.swift"


def source() -> str:
    return SCREEN.read_text(encoding="utf-8")


class StreamingDoesNotScrollPerToken(unittest.TestCase):
    def test_the_streaming_handlers_do_not_call_scroll_to(self) -> None:
        text = source()
        for name in ("model.streamingText", "model.liveTools.count", "model.reasoningText"):
            body = text.split(f".onChange(of: {name})", 1)[1].split(".onChange(", 1)[0]
            self.assertIn("followStreaming(proxy)", body, f"{name} must coalesce")
            self.assertNotIn("follow(proxy", body, f"{name} still scrolls on every change")

    def test_one_scroll_is_in_flight_at_a_time(self) -> None:
        text = source()
        body = text.split("private func followStreaming(", 1)[1].split("\n    /// ", 1)[0]
        self.assertIn("followTask == nil", body, "without the guard every token queues its own scroll")
        self.assertIn("defer { followTask = nil }", body)
        self.assertIn("Task.sleep", body, "coalescing needs a window; a zero delay coalesces nothing")

    def test_a_scroll_that_would_not_move_is_skipped(self) -> None:
        body = source().split("private func followStreaming(", 1)[1].split("\n    /// ", 1)[0]
        self.assertIn("bottomDistance > 2", body,
                      "scrollTo at the position the view already has still costs a layout")


class TheBottomIsMeasured(unittest.TestCase):
    def test_the_sentinel_reports_a_distance(self) -> None:
        text = source()
        self.assertIn("BottomDistanceKey", text)
        self.assertIn(".coordinateSpace(name: Self.scrollSpace)", text,
                      "a frame in an unnamed space cannot be compared with the viewport")

    def test_the_sentinel_no_longer_guesses_from_appearing(self) -> None:
        text = source()
        sentinel = text.split(".id(ConversationScreen.bottomID)", 1)[1].split("}", 1)[0]
        self.assertNotIn("onAppear { isAtBottom = true }", text,
                         "a lazy row appearing is not a scroll fact during streaming")
        self.assertIn("PreferenceKey", text)
        self.assertIn("geo.frame(in: .named(ConversationScreen.scrollSpace))", sentinel)

    def test_an_unmeasured_sentinel_is_not_evidence(self) -> None:
        body = source().split(".onPreferenceChange(BottomDistanceKey.self)", 1)[1].split("\n            .onChange", 1)[0]
        self.assertIn("distance.isFinite", body,
                      "the default value means 'not measured yet', not 'scrolled away'")


class TheReaderWins(unittest.TestCase):
    def test_a_drag_stops_the_follow(self) -> None:
        body = source().split(".simultaneousGesture(DragGesture(minimumDistance: 5)", 1)[1].split(".onEnded", 1)[0]
        self.assertIn("followsStream = false", body,
                      "otherwise the next token overrides the reader's finger")
        self.assertIn("followTask?.cancel()", body, "a queued scroll must be dropped as well")

    def test_following_checks_both_the_measurement_and_the_intent(self) -> None:
        body = source().split("private func follow(_ proxy: ScrollViewProxy", 1)[1].split("\n    }", 1)[0]
        self.assertIn("followsStream", body)
        self.assertIn("isDraggingTranscript", body)

    def test_the_scroll_view_is_not_animated(self) -> None:
        text = source()
        self.assertNotIn(".animation(.easeOut(duration: 0.18), value: isAtBottom)\n            .simultaneousGesture",
                         text)
        # The fade belongs to the button. Checked in place rather than by slicing an overlay block:
        # the composer's overlay is also `.bottom` now, so the first one found is not this one.
        call = text.split("scrollToBottomControl(proxy)", 1)[1][:220]
        self.assertIn(".animation(", call, "the button's fade has to live on the button")


if __name__ == "__main__":
    unittest.main()
