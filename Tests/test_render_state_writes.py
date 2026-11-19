"""Drawing a row must not write state.

`@State` written from a computed property that `body` reads is the "Modifying state during view
update" defect: SwiftUI calls it undefined behaviour and answers it with another invalidation, so
every visible row re-invalidates itself while it is being laid out. Measured on the shipped 0.1.580
build: 486 warnings a minute at ~15% CPU with the app sitting still, and a transcript that felt
sticky to scroll.

The fix is always the same shape — seed the cache in `init`, refresh it from `onChange`/`onAppear`,
and let the getter read without writing. These tests pin that shape in both clients.
"""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MAC = (ROOT / "Apps" / "HermesMac" / "Conversation" / "MarkdownTextView.swift").read_text()
IOS = (ROOT / "Apps" / "HermesMobile" / "Views" / "MobileMarkdown.swift").read_text()


def _block(source: str, header: str) -> str:
    """The text of the computed property or function that starts with `header`."""
    start = source.index(header)
    depth = 0
    for index in range(start, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError(f"unbalanced braces after {header!r}")


class TheMacRow(unittest.TestCase):
    def test_the_getter_that_draws_does_not_write_its_cache(self):
        getter = _block(MAC, "private var cleanText: String {")
        self.assertNotRegex(
            getter, r"\bcached(Source|Clean|Links)\s*=(?!=)",
            "cleanText writes @State and body reads it — that is the state-during-update defect")

    def test_the_links_getter_does_not_write_either(self):
        getter = _block(MAC, "private var fileLinks: [HermesFileLink] {")
        self.assertNotRegex(getter, r"\bcached(Source|Clean|Links)\s*=(?!=)")

    def test_the_cache_is_seeded_when_the_value_is_created(self):
        self.assertIn("init(text: String", MAC)
        init = _block(MAC, "init(text: String")
        self.assertIn("_cachedClean = State(initialValue:", init)

    def test_the_parse_is_refreshed_where_writing_is_legal(self):
        sync = _block(MAC, "private func synchronise(_ newValue: String) {")
        self.assertIn("cachedSource = text", sync,
                      "the cache must still be updated — from onChange, not from body")


class ThePhoneRow(unittest.TestCase):
    def test_the_links_getter_does_not_write_its_cache(self):
        getter = _block(IOS, "private var fileLinks: [HermesFileLink] {")
        self.assertNotRegex(getter, r"\bcached(LinkSource|Links)\s*=(?!=)")

    def test_the_cache_is_seeded_when_the_value_is_created(self):
        self.assertIn("init(blocks: [Block], rawText: String? = nil)", IOS)


class TheIdleTranscriptDoesNotSearch(unittest.TestCase):
    def test_the_highlight_pass_is_skipped_while_the_bar_is_closed(self):
        """`matches` folds every row's text, and body runs on every streaming token.

        With the bar closed nothing is highlighted, so the walk must not happen at all — it is
        O(conversation) per pass otherwise.
        """
        source = (ROOT / "Apps" / "HermesMac" / "Conversation" / "TranscriptScroll.swift").read_text()
        rows = _block(source, "private var rows: some View {")
        self.assertIn("let searching = search.isOpen", rows)
        self.assertIn("searching ? matches : []", rows)


if __name__ == "__main__":
    unittest.main()
