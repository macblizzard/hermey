"""One window language: every sheet in both apps is drawn the same way.

Asked for 2026-11-15: "fix the windows for all menu items for macOS and iOS so that they all seem
harmonious to the apps design elements and themes". The rule is one modifier applied where a sheet is
presented — canvas, the app's own dark appearance, the card corner radius — so a new sheet cannot
forget it, and `docs/UI-WINDOWS.md` lists every site so the table cannot drift from the code.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LANGUAGE = (ROOT / "Sources" / "HermeyUI" / "SheetLanguage.swift").read_text(encoding="utf-8")
DOC = (ROOT / "docs" / "UI-WINDOWS.md").read_text(encoding="utf-8")

APPS = sorted((ROOT / "Apps").rglob("*.swift"))


def _sites(path: Path) -> list[int]:
    """Line numbers of every sheet/full-screen presentation in one file."""
    lines = path.read_text(encoding="utf-8").splitlines()
    # A line of prose that *mentions* `.sheet(` is not a presentation site.
    return [i for i, line in enumerate(lines)
            if not line.lstrip().startswith("//")
            and (".sheet(" in line or ".fullScreenCover(" in line)]


def _has_chrome(path: Path, line_index: int) -> bool:
    """Whether that presentation's builder applies the house chrome.

    The range runs from the site to the *next* presentation: a builder's modifier sits before the
    following `.sheet(` line, so this cannot borrow a neighbour's chrome — and it does not care how
    long the builder is (one of them switches over eight routes).
    """
    lines = path.read_text(encoding="utf-8").splitlines()
    end = len(lines)
    for k in range(line_index + 1, len(lines)):
        if ".sheet(" in lines[k] or ".fullScreenCover(" in lines[k]:
            end = k
            break
    return any(".hermesSheetChrome()" in lines[k] for k in range(line_index, end))


class TheRuleIsWrittenOnce(unittest.TestCase):
    def test_it_is_one_modifier_in_the_shared_ui_package(self) -> None:
        self.assertIn("public struct HermesSheetChrome", LANGUAGE)
        self.assertIn("func hermesSheetChrome() -> some View", LANGUAGE)

    def test_it_sets_the_three_things_it_promises(self) -> None:
        # Background, appearance, corner radius. These are the three the owner could see disagreeing.
        self.assertIn("Tokens.canvas.ignoresSafeArea()", LANGUAGE)
        self.assertIn(".preferredColorScheme(.dark)", LANGUAGE)
        self.assertIn("presentationCornerRadius(Tokens.radiusGrouped)", LANGUAGE)
        self.assertIn("presentationBackground(Tokens.canvas)", LANGUAGE)

    def test_it_does_not_take_over_what_a_sheet_is(self) -> None:
        """Detents and sizes belong to the sheet; the rule is only how it looks."""
        self.assertNotIn("presentationDetents", LANGUAGE)


class EverySheetUsesIt(unittest.TestCase):
    def test_no_presentation_site_is_left_without_it(self) -> None:
        missing = []
        for path in APPS:
            for index in _sites(path):
                if not _has_chrome(path, index):
                    missing.append(f"{path.relative_to(ROOT)}:{index + 1}")
        self.assertEqual(missing, [], "these sheets are not using the house chrome")

    def test_there_are_sites_to_check(self) -> None:
        # A guard on the test itself: a rename that stopped matching would otherwise pass silently.
        total = sum(len(_sites(path)) for path in APPS)
        self.assertGreater(total, 30)


class TheAuditTableMatchesTheCode(unittest.TestCase):
    def test_the_doc_lists_every_app_that_presents_a_sheet(self) -> None:
        for app in ("HermesMac", "HermesMobile"):
            self.assertIn(f"| {app} |", DOC)

    def test_the_doc_claims_no_site_is_unfinished(self) -> None:
        self.assertNotIn("**no**", DOC)
        self.assertIn("with the house chrome", DOC)

    def test_the_doc_names_the_modifier_and_the_rule(self) -> None:
        self.assertIn("`.hermesSheetChrome()`", DOC)
        self.assertIn("SheetLanguage.swift", DOC)


if __name__ == "__main__":
    unittest.main()
