"""The shared computer takes a physical keyboard.

The viewer's only key source was the hidden `#keys` text area, and on a Mac nothing ever focused it:
no soft keyboard, the ⌨ button is hidden for a coarse-pointer check, and the pane opened with the
caret nowhere — so typing went into the void while the remote desktop sat there looking ready.
"""
from __future__ import annotations

import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PAGES = [ROOT / "Apps" / "HermesMac" / "Resources" / "botcomputer.html",
         ROOT / "Apps" / "HermesMobile" / "Resources" / "botcomputer.html"]


class BotComputerKeyboard(unittest.TestCase):
    def test_both_copies_are_identical(self) -> None:
        texts = [p.read_text(encoding="utf-8") for p in PAGES]
        self.assertEqual(texts[0], texts[1],
                         "the two bundles ship the same page; a one-sided fix is a bug on the other")

    def test_keys_are_read_at_the_document(self) -> None:
        for page in PAGES:
            text = page.read_text(encoding="utf-8")
            self.assertIn("document.addEventListener('keydown', handleKeydown, true)", text)
            self.assertNotIn("keys.addEventListener('keydown'", text,
                            "a listener on the text area alone is dead on a Mac, where it is never focused")
            # One sender, one timestamp: a duplicated listener would send every key twice.
            self.assertEqual(text.count("function sendKeystroke"), 1)
            self.assertEqual(text.count("let lastKeydownAt"), 1)

    def test_a_pointer_focuses_the_text_area_on_a_desktop_only(self) -> None:
        for page in PAGES:
            text = page.read_text(encoding="utf-8")
            self.assertIn("if (!isTouch) {", text)
            focus_block = text.split("if (!isTouch) {", 1)[1].split("// Dictation", 1)[0]
            self.assertIn("keys.focus({ preventScroll: true })", focus_block)
            self.assertIn("pointerdown", focus_block)
            self.assertIn("window.addEventListener('focus', focusKeys)", focus_block)

    def test_the_module_still_parses(self) -> None:
        for page in PAGES:
            text = page.read_text(encoding="utf-8")
            found = re.search(r'<script type="module">(.*?)</script>', text, re.S)
            self.assertIsNotNone(found, f"{page.name} lost its module script")
            body = found.group(1) if found else ""
            with tempfile.NamedTemporaryFile("w", suffix=".mjs", delete=False) as handle:
                handle.write(body)
                path = handle.name
            result = subprocess.run(["node", "--check", path], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_command_chords_stay_with_the_mac(self) -> None:
        for page in PAGES:
            text = page.read_text(encoding="utf-8")
            self.assertIn("if (event.metaKey) { return; }", text,
                         "⌘C/⌘V/⌘W belong to AppKit; paste reaches the desktop via the input event")


if __name__ == "__main__":
    unittest.main()
