"""A genui card must not swallow the conversation's scroll wheel on macOS.

Reported from the Mac build: scrolling the transcript stopped dead whenever the pointer sat above a
genui card, and only resumed once the cursor left the card. iOS never had the problem because it turns
its inner scroller off; on macOS `WKWebView` handles `scrollWheel` itself, so the card's page took the
event and the transcript never saw it.

These are source-level assertions — the behaviour itself needs a trackpad and a person, but the shape
that makes it possible (a subclass that forwards, and the card actually using it) can be pinned here.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CARD = REPO_ROOT / "Sources" / "HermeyUI" / "GenUICard.swift"


def source() -> str:
    return CARD.read_text()


def macos_half(text: str) -> str:
    """The macOS card's own section — the file also has a `#if os(macOS)` import block at the top."""
    marker = text.find("// MARK: - The web view")
    if marker < 0:
        return ""
    # Ends where the iOS half begins, or the iOS `WKWebView` would satisfy the macOS assertions.
    ended = text.find("private struct GenUIWebView: UIViewRepresentable", marker)
    return text[marker : ended if ended > 0 else len(text)]


class TheCardHandsTheWheelBack(unittest.TestCase):
    def test_a_webkit_subclass_forwards_the_scroll_wheel(self) -> None:
        region = macos_half(source())
        self.assertIn("class PassthroughScrollWebView: WKWebView", region)
        forward = re.search(
            r"override func scrollWheel\(with event: NSEvent\)\s*\{\s*nextResponder\?\.scrollWheel\(with: event\)",
            region,
        )
        self.assertIsNotNone(
            forward,
            "the macOS card must forward scrollWheel to the responder chain, or the transcript "
            "stops scrolling whenever the pointer is over a card",
        )

    def test_the_macos_card_uses_that_subclass(self) -> None:
        region = macos_half(source())
        self.assertIn("PassthroughScrollWebView(frame:", region)
        self.assertNotIn(
            "let view = WKWebView(frame:",
            region,
            "a plain WKWebView on macOS takes the wheel event and never gives it back",
        )

    def test_ios_still_disables_its_inner_scroller(self) -> None:
        # The two platforms solve the same problem differently; losing the iOS half would make the
        # card scroll inside itself on the phone instead.
        text = source()
        self.assertIn("isScrollEnabled = false", text)
        self.assertIn("bounces = false", text)

    def test_the_forwarding_is_explained(self) -> None:
        # A bare override invites "simplification" later; the comment says why it exists.
        text = source()
        self.assertIn("scroll", text.lower())
        self.assertIn("iOS", text, "the comment should name the iOS half it mirrors")


if __name__ == "__main__":
    unittest.main()
