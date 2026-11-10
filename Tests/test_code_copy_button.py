"""A code block that can be copied, on both platforms, and says so when it was.

The phone drew the code card with no button at all — the only way to take a command off the screen
was a long press and two drag handles — and the desktop's button copied in silence, so the person
pressed it twice. One component now, shared, with the answer where the finger is.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUTTON = (ROOT / "Sources" / "OpenBotUI" / "CodeCopyButton.swift").read_text(encoding="utf-8")
MAC_BLOCKS = (ROOT / "Apps" / "HermesMac" / "Conversation" / "MacBlockView.swift").read_text(encoding="utf-8")
IOS_MARKDOWN = (ROOT / "Apps" / "HermesMobile" / "Views" / "MobileMarkdown.swift").read_text(encoding="utf-8")


class CodeCopyButton(unittest.TestCase):
    def test_the_tick_replaces_the_glyph_where_it_stands(self) -> None:
        self.assertIn('copied ? "checkmark" : "doc.on.doc"', BUTTON)
        self.assertIn("Tokens.success", BUTTON, "the tick has to read as success, not as another glyph")

    def test_the_tick_goes_away_by_itself(self) -> None:
        self.assertIn("Task.sleep(nanoseconds:", BUTTON)
        self.assertIn("copied = false", BUTTON)
        self.assertIn("resetTask?.cancel()", BUTTON,
                      "a second press must restart the confirmation, not stack two timers")

    def test_it_copies_the_bytes_the_block_drew(self) -> None:
        self.assertIn("setString(code, forType: .string)", BUTTON)
        self.assertIn("UIPasteboard.general.string = code", BUTTON)

    def test_both_platforms_use_the_shared_button(self) -> None:
        self.assertIn("CodeCopyButton(code: body)", MAC_BLOCKS)
        self.assertIn("CodeCopyButton(code: body)", IOS_MARKDOWN)
        self.assertNotIn('OpenBotIconButton("doc.on.doc"', MAC_BLOCKS,
                         "the silent copy button is what this replaces")

    def test_the_phone_code_block_has_a_header_with_the_verb(self) -> None:
        block = IOS_MARKDOWN.split("private func codeBlock(", 1)[1]
        self.assertIn("CodeCopyButton", block)
        self.assertIn("design: .monospaced", block, "the language label is the header's left side")
        self.assertIn("textSelection(.enabled)", block,
                      "a button is not a replacement for selecting the text")


if __name__ == "__main__":
    unittest.main()
