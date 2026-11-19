"""Arrow keys must scroll the transcript and the roster.

Reported 2026-11-19: neither list scrolled from the keyboard. SwiftUI's `ScrollView` on macOS
answers the trackpad and the wheel and nothing else, so the AppKit scroll view underneath has to be
asked directly — `ScrollViewProxy` can only scroll to an id, never by an amount.
"""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SUPPORT = (ROOT / "Apps" / "HermesMac" / "Support" / "KeyboardScroll.swift").read_text()
TRANSCRIPT = (ROOT / "Apps" / "HermesMac" / "Conversation" / "TranscriptScroll.swift").read_text()
SIDEBAR = (ROOT / "Apps" / "HermesMac" / "Sidebar" / "SidebarBotList.swift").read_text()


class TheHandle(unittest.TestCase):
    def test_it_scrolls_the_enclosing_appkit_scroll_view(self) -> None:
        self.assertIn("enclosingScrollView", SUPPORT)
        self.assertIn("reflectScrolledClipView", SUPPORT,
                      "scrolling the clip view without reflecting leaves the scroller stale")

    def test_movement_is_clamped_to_the_content(self) -> None:
        """A page-down at the bottom must not scroll past the end and then have to come back."""
        self.assertIn("let limit = max(0, document.bounds.height", SUPPORT)
        self.assertIn("min(max(0, y), limit)", SUPPORT)

    def test_a_line_is_more_than_a_few_points(self) -> None:
        """A notch smaller than a row reads as 'nothing happened'."""
        match = re.search(r"lineHeight: CGFloat = (\d+)", SUPPORT)
        if match is None:
            self.fail("the handle has no line height")
        self.assertGreaterEqual(int(match.group(1)), 30)


class TheKeys(unittest.TestCase):
    def test_one_handler_per_key_decides_on_the_modifier_inside(self) -> None:
        """A separate ⌘↑ handler beside a plain ↑ one never fires: the first consumes the press."""
        self.assertIn("press.modifiers.contains(.command) ? handle.toTop() : handle.line(-1)", SUPPORT)
        self.assertEqual(SUPPORT.count(".onKeyPress(.upArrow)"), 1)
        self.assertEqual(SUPPORT.count(".onKeyPress(.downArrow)"), 1)

    def test_page_and_home_keys_are_mapped(self) -> None:
        for key in (".pageUp", ".pageDown", ".home", ".end"):
            self.assertIn(f".onKeyPress({key})", SUPPORT)


class BothListsAreWired(unittest.TestCase):
    def test_the_transcript_wires_both_halves(self) -> None:
        self.assertIn(".keyboardScrollProbe(keyboardScroll)", TRANSCRIPT)
        self.assertIn(".keyboardScrolling(keyboardScroll)", TRANSCRIPT)

    def test_the_roster_wires_both_halves(self) -> None:
        self.assertIn(".keyboardScrollProbe(keyboardScroll)", SIDEBAR)
        self.assertIn(".keyboardScrolling(keyboardScroll)", SIDEBAR)

    def test_the_probe_sits_inside_the_scroll_view(self) -> None:
        """`enclosingScrollView` is nil for a background on the ScrollView itself.

        The probe therefore has to be part of the content, which is why there are two modifiers
        instead of one convenient one.
        """
        support = SUPPORT
        self.assertIn("func keyboardScrollProbe", support)
        self.assertIn("func keyboardScrolling", support)
        self.assertIn("background(KeyboardScrollProbe(handle: handle))", support)


if __name__ == "__main__":
    unittest.main()
