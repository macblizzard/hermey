"""A reply's stamp and its glyphs are one line on the Mac, not two.

The assistant row stacked `messageTime` above `messageActions`, so every reply spent a whole extra
line — a dim time alone on its own row, then the three verbs — while the user row had already put
the same pair in one `HStack`. The owner asked for them side by side; these guards pin that, and
pin that nothing else about the row moved with it: the time keeps its slot ahead of the glyphs, its
type and colour are untouched, the glyph keeps its box, and a long bot name still truncates on the
header line instead of growing the row.

The phone was not part of the ask and does not draw the verbs on the row at all (`actionCard` is a
long-press card), so it is left alone — and pinned as left alone.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAC = (ROOT / "Apps" / "HermesMac" / "Conversation" / "TranscriptRowView.swift").read_text(encoding="utf-8")
IOS = (ROOT / "Apps" / "HermesMobile" / "Views" / "MobileTranscript.swift").read_text(encoding="utf-8")


def balanced(source: str, marker: str) -> str:
    """The body of the first braced block after `marker`, braces matched."""
    start = source.index(marker)
    opened = source.index("{", start)
    depth = 0
    for offset, char in enumerate(source[opened:], start=opened):
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[opened + 1:offset]
    raise AssertionError(f"unbalanced braces after {marker!r}")


def region(source: str, start: str, end: str) -> str:
    return source.split(start, 1)[1].split(end, 1)[0]


class RowTimeInline(unittest.TestCase):
    def setUp(self) -> None:
        self.assistant = region(MAC, "private var assistantRow", "// MARK: Native cards")
        self.user = region(MAC, "private var userRow", "/// When a message was sent")

    # -- the fix ---------------------------------------------------------------------------------

    def test_the_time_and_the_glyphs_are_one_horizontal_row(self) -> None:
        self.assertEqual(self.assistant.count("HStack(spacing: 8) {"), 1,
                         "the reply should carry exactly one time+glyph line")
        line = balanced(self.assistant, "HStack(spacing: 8) {")
        self.assertIn("messageTime", line, "the stamp is no longer on the glyph line")
        self.assertIn("messageActions", line, "the glyphs are no longer on the time line")
        self.assertLess(line.index("messageTime"), line.index("messageActions"),
                        "the stamp still sits ahead of the glyphs")

    def test_the_time_is_not_left_on_a_line_of_its_own(self) -> None:
        line = balanced(self.assistant, "HStack(spacing: 8) {")
        rest = self.assistant.replace(line, "", 1)
        self.assertNotIn("messageTime", rest, "the stamp is stacked above the glyphs again")
        self.assertNotIn("messageActions", rest, "the glyphs are stacked below the stamp again")

    def test_one_stamp_and_one_glyph_row(self) -> None:
        # A copy of either would draw the pair twice, which is what a botched merge looks like.
        self.assertEqual(self.assistant.count("messageTime"), 1)
        self.assertEqual(self.assistant.count("messageActions"), 1)

    def test_both_roles_use_the_same_spacing(self) -> None:
        def gap(view: str) -> str:
            match = re.search(r"HStack\(spacing: (\d+)\) \{\s*\n\s*messageTime", view)
            if match is None:
                self.fail("the row no longer opens with the stamp on a glyph line")
            return match.group(1)

        self.assertEqual(gap(self.assistant), gap(self.user),
                         "the reply and the user bubble must space the pair the same way")

    # -- nothing else moved ----------------------------------------------------------------------

    def test_the_time_keeps_its_place_and_its_type(self) -> None:
        # It stays the first thing on the line, at the row's leading edge — the assistant row is a
        # document you read, so its stamp is not pushed to the far right.
        line = balanced(self.assistant, "HStack(spacing: 8) {")
        first_line = next(row for row in line.splitlines() if row.strip())
        self.assertEqual(first_line.strip(), "messageTime")

        stamp = balanced(MAC, "private var messageTime")
        self.assertIn("Text(MessageTime.label(for: at))", stamp)
        self.assertIn(".font(.system(size: 10, design: .monospaced))", stamp)
        self.assertIn(".monospacedDigit()", stamp)
        self.assertIn(".foregroundStyle(Tokens.textMuted)", stamp)
        self.assertIn('accessibilityLabel("Sent \\(MessageTime.label(for: at))")', stamp)

    def test_a_row_without_words_still_has_no_stamp(self) -> None:
        stamp = balanced(MAC, "private var messageTime")
        self.assertIn("if let at = entry.at, TranscriptVisibility.hasContent(entry) {", stamp,
                      "a tool-call banner must not leave a lone grey time behind")

    def test_the_glyph_keeps_its_size_and_its_colour(self) -> None:
        glyph = balanced(MAC, "private func actionGlyph")
        self.assertIn(".font(.system(size: 11, weight: .semibold))", glyph)
        self.assertIn(".frame(width: 24, height: 20)", glyph)
        self.assertIn("hoveredAction == id ? Tokens.textPrimary : tint", glyph,
                      "a hovered glyph still lifts; the resting tint is the caller's")

    def test_a_long_bot_name_truncates_instead_of_growing_the_row(self) -> None:
        header = region(MAC, "private func botMessageRow", "// MARK: User")
        name = header.index("Text(label.headerTitle)")
        self.assertIn(".lineLimit(1)", header[name:], "a long name must shorten, not wrap")
        self.assertLess(header.index(".lineLimit(1)"), header.index("Spacer(minLength: 0)"),
                        "the spacer after the name is what lets the name yield")
        self.assertNotIn("messageTime", header,
                         "the stamp does not belong inside the name line: nothing to push off it")

    def test_the_transcript_still_spends_one_line_on_the_pair(self) -> None:
        # Three children at most (the stamp, the verbs): a fourth would be another stacked line.
        line = balanced(self.assistant, "HStack(spacing: 8) {")
        body = "\n".join(row for row in line.splitlines() if not row.strip().startswith("//"))
        self.assertNotIn("VStack", body, "the pair was stacked again")

    # -- the phone was not asked for -------------------------------------------------------------

    def test_the_phone_row_is_untouched(self) -> None:
        self.assertNotIn("messageActions", IOS,
                         "the phone draws its verbs on a long-press card, not on the row")
        phone = region(IOS, "private var assistant: some View", "// MARK: Native cards")
        self.assertIn("messageTime", phone)
        self.assertNotIn("HStack(spacing: 8) {\n            messageTime", phone,
                         "the phone's stamp line was changed without being asked")


if __name__ == "__main__":
    unittest.main()
