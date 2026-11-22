"""Swipe down on the phone puts the gallery away.

The owner's one note on the gallery was a gesture: a photo viewer should close when the picture is
pulled down, the way every viewer on iOS does. The catch is that the same screen already owns three
gestures and a control — a pinch to zoom, a horizontal page turn, and Close — so the new drag has to
be able to say no to a swipe that is not its own.

These are source assertions: there is no Swift toolchain in this environment. What they can prove is
that the drag exists *inside the iOS guard*, that it is claimed only for a predominantly vertical
drag, and that the pinch, the pager and Close are still wired exactly as they were. What they cannot
prove is how the gesture feels next to the pager — that needs a build and a device.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VIEWER = (ROOT / "Sources" / "HermeyUI" / "ImageViewer.swift").read_text(encoding="utf-8")
MAC_ROW = (ROOT / "Apps" / "HermesMac" / "Conversation" / "TranscriptRowView.swift").read_text(encoding="utf-8")
IOS_ROW = (ROOT / "Apps" / "HermesMobile" / "Views" / "MobileTranscript.swift").read_text(encoding="utf-8")


def section(text: str, opener: str, closer: str) -> str:
    """The slice from `opener` to the next `closer` — one property or function body."""
    start = text.index(opener)
    return text[start:text.index(closer, start)]


def ios_only_spans(text: str) -> list[tuple[int, int]]:
    """Character ranges that only exist when building for iOS.

    The `#if os(iOS)` branch of a conditional-compilation block is iOS-only; an `#else` branch is
    not, and `#if os(macOS)` is excluded outright. Nesting is tracked, so a Mac-only block inside an
    iOS block stays visible to the Mac.
    """
    spans: list[tuple[int, int]] = []
    stack: list[dict] = []
    pos = 0
    for line in text.splitlines(keepends=True):
        marker = line.strip()
        if marker.startswith("#if "):
            stack.append({"start": pos, "ios": marker[4:].strip() == "os(iOS)"})
        elif marker == "#else" and stack:
            if stack[-1]["ios"]:
                spans.append((stack[-1]["start"], pos))
            stack[-1]["ios"] = False
            stack[-1]["start"] = pos
        elif marker == "#endif" and stack:
            frame = stack.pop()
            if frame["ios"]:
                spans.append((frame["start"], pos))
        pos += len(line)
    return spans


def is_ios_only(text: str, needle: str) -> bool:
    """True when every occurrence of `needle` sits inside an `#if os(iOS)` branch."""
    spans = ios_only_spans(text)
    at = text.find(needle)
    if at < 0:
        raise AssertionError(f"{needle!r} is not in the viewer at all")
    while at >= 0:
        if not any(start <= at < end for start, end in spans):
            return False
        at = text.find(needle, at + 1)
    return True


class TheGestureIsThePhones(unittest.TestCase):
    def test_a_downward_drag_closes_the_viewer(self) -> None:
        self.assertIn("private var dismissSwipe: some Gesture", VIEWER)
        self.assertIn("DragGesture(minimumDistance: Self.dismissDragArm)", VIEWER)
        self.assertIn(".simultaneousGesture(dismissSwipe)", VIEWER)
        self.assertIn("onClose()", section(VIEWER, "private var dismissSwipe: some Gesture",
                                           "/// A drag that is predominantly vertical"))

    def test_it_exists_only_on_the_phone(self) -> None:
        # The Mac's sheet is a window with its own close control and the arrow keys for pages.
        for needle in ("private var dismissSwipe: some Gesture",
                       "DragGesture(minimumDistance: Self.dismissDragArm)",
                       ".simultaneousGesture(dismissSwipe)",
                       ".offset(y: pull)",
                       ".opacity(pullOpacity)",
                       "private static func isDownward",
                       "private var pullOpacity"):
            self.assertTrue(is_ios_only(VIEWER, needle), f"{needle} must sit inside `#if os(iOS)`")

    def test_the_following_view_is_the_viewer_itself(self) -> None:
        body = section(VIEWER, "public var body: some View", ".onChange(of: index)")
        self.assertIn(".offset(y: pull)", body, "the picture must follow the finger")
        self.assertIn(".opacity(pullOpacity)", body, "and the page behind it must thin as it goes")


class OnlyVerticalDragsAreClaimed(unittest.TestCase):
    def test_the_claim_needs_a_vertical_drag(self) -> None:
        gesture = section(VIEWER, "private var dismissSwipe: some Gesture",
                          "/// A drag that is predominantly vertical")
        claimed = gesture.index("guard Self.isDownward(value) else { return }")
        moved = gesture.index("pull = max(0, value.translation.height)")
        self.assertLess(claimed, moved, "nothing may move before the drag is known to be vertical")
        self.assertIn("pulling = true", gesture)

    def test_the_test_is_height_against_width(self) -> None:
        check = section(VIEWER, "private static func isDownward", "/// How much of the viewer")
        self.assertIn("value.translation.height", check)
        self.assertIn("abs(value.translation.width)", check)
        self.assertIn("dy > 0", check, "an upward drag is the pager's business, not this one's")
        self.assertIn("dy > abs(value.translation.width) * 1.4", check,
                      "a slightly diagonal page turn must not be read as a dismissal")

    def test_a_drag_that_never_claims_dismisses_nothing(self) -> None:
        gesture = section(VIEWER, "private var dismissSwipe: some Gesture",
                          "/// A drag that is predominantly vertical")
        self.assertIn("guard wasPulling else { return }", gesture,
                      "a horizontal swipe must end without closing the viewer")


class LettingGo(unittest.TestCase):
    def test_far_enough_or_fast_enough(self) -> None:
        self.assertIn("private static let dismissThreshold: CGFloat = 90", VIEWER)
        self.assertIn("private static let dismissFlick: CGFloat = 160", VIEWER)
        gesture = section(VIEWER, "private var dismissSwipe: some Gesture",
                          "/// A drag that is predominantly vertical")
        self.assertIn("value.translation.height > Self.dismissThreshold", gesture)
        self.assertIn("value.predictedEndTranslation.height > Self.dismissFlick", gesture,
                      "a quick flick must count even when it never travelled far")

    def test_a_short_pull_springs_back(self) -> None:
        gesture = section(VIEWER, "private var dismissSwipe: some Gesture",
                          "/// A drag that is predominantly vertical")
        self.assertIn("withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { pull = 0 }", gesture)
        self.assertIn("if tossed {", gesture)

    def test_the_viewer_closes_through_the_callers_door(self) -> None:
        # The cover is driven by the transcript's own state: `dismiss` would leave it believing the
        # gallery is still open.
        self.assertNotIn("@Environment(\\.dismiss)", VIEWER)
        self.assertIn("public let onClose: () -> Void", VIEWER)


class NothingElseMoved(unittest.TestCase):
    def test_the_pinch_is_untouched(self) -> None:
        self.assertIn("MagnificationGesture()", VIEWER)
        self.assertIn(".gesture(pinch)", VIEWER)
        pinch = section(VIEWER, "private var pinch: some Gesture", "#if os(iOS)")
        self.assertIn("zoom = min(4, max(1, base * value))", pinch)

    def test_the_pager_is_untouched(self) -> None:
        self.assertIn("TabView(selection: $index)", VIEWER)
        self.assertIn(".tabViewStyle(.page(indexDisplayMode: .never))", VIEWER)
        pages = section(VIEWER, "private func pages(size: CGSize)", "private func page(_ item: Item")
        self.assertNotIn("dismissSwipe", pages, "the pager must keep its own horizontal gesture")
        self.assertNotIn("DragGesture", pages)

    def test_the_bare_drag_does_not_outrank_the_pager(self) -> None:
        # `highPriorityGesture` would take the drag before the `TabView` ever saw it.
        self.assertNotIn("highPriorityGesture", VIEWER)
        self.assertNotIn(".gesture(dismissSwipe)", VIEWER)

    def test_the_close_button_is_still_there(self) -> None:
        self.assertIn("Button { onClose() } label: {", VIEWER)
        self.assertIn('Image(systemName: "xmark")', VIEWER)
        self.assertIn(".accessibilityLabel(\"Close the image\")", VIEWER)

    def test_the_mac_keeps_its_keys_and_its_sheet(self) -> None:
        self.assertIn(".onKeyPress(.leftArrow, phases: .down)", VIEWER)
        self.assertIn(".onKeyPress(.rightArrow, phases: .down)", VIEWER)
        self.assertIn(".focusable()", VIEWER)
        self.assertIn(".sheet(item: $viewingImage)", MAC_ROW)
        self.assertNotIn("dismissSwipe", MAC_ROW)

    def test_no_sheet_refuses_the_system_drag(self) -> None:
        # The house rule (`test_approvals_and_sheets`): nothing in HermeyUI refuses the drag. The
        # phone presents this viewer in a `fullScreenCover`, which has no drag to fight, so the
        # gesture needs no such opt-out — and because it is simultaneous rather than high-priority,
        # a presentation that does have one keeps it.
        self.assertNotIn("interactiveDismissDisabled", VIEWER,
                         "the viewer must not opt out of a presentation's own drag")
        self.assertIn(".fullScreenCover(item: $viewingImage)", IOS_ROW)


class OnlyAPhoneConcern(unittest.TestCase):
    def test_no_new_code_leaks_onto_the_mac(self) -> None:
        for needle in ("pull = ", "pullOpacity", "pulling", "dismissSwipe", "isDownward"):
            self.assertTrue(is_ios_only(VIEWER, needle),
                            f"{needle} appears outside the iOS guard")


if __name__ == "__main__":
    unittest.main()
