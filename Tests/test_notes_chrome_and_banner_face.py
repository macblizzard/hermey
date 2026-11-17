"""Two chrome/asset fixes from 2026-11-17.

* "desktop notification banner still uses old app logo" — the Mac draws the banner's picture from a
  PNG cached by bot id + face colour; a renderer change left the old PNG valid forever.
* "notes sheet on mobile has a different chrome than rest of the sheets" — the notes sheet used the
  Mac's panel-with-a-title-bar on iOS while every other sheet used a navigable screen.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NOTES = (ROOT / "Sources" / "HermeyUI" / "BotNotesSheet.swift").read_text(encoding="utf-8")
FACE_CACHE = (ROOT / "Apps" / "HermesMac" / "Support" / "MacFaceCache.swift").read_text(encoding="utf-8")


class TheNotesSheetDressesLikeItsNeighbours(unittest.TestCase):
    def testThePhoneUsesANavigationStackWithAnInlineTitle(self) -> None:
        self.assertIn("#if os(iOS)", NOTES)
        self.assertIn("NavigationStack {", NOTES)
        self.assertIn('.navigationTitle("Notes")', NOTES)
        self.assertIn(".navigationBarTitleDisplayMode(.inline)", NOTES)

    def testTheMacTitleBarIsNotDrawnOnThePhone(self) -> None:
        # Two title bars on one screen is the failure being fixed, not a good.
        self.assertIn("#if !os(iOS)", NOTES)
        # The panel's hard frame belongs to the Mac window, not to a sheet on a phone.
        self.assertIn("#if os(macOS)", NOTES)

    def testTheDoneControlSurvivesInBoth(self) -> None:
        self.assertNotEqual(NOTES.count('Button("Done")'), 0)
        self.assertIn("dismiss()", NOTES)


class TheBannerFaceCannotGoStaleForever(unittest.TestCase):
    def testTheCacheKeyCarriesARendererVersion(self) -> None:
        self.assertIn('private static let schema = "v2"', FACE_CACHE)
        self.assertIn('\\(schema)-\\(slug(botID, color)).png', FACE_CACHE)
        # And the cache still keys on the stored face: changing a bot's portrait in settings must change
        # its next banner, not just every banner after the next app release.
        self.assertIn("appendingPathComponent", FACE_CACHE)

    def testTheOldKeyCannotBeAccidentallyReused(self) -> None:
        # Without the prefix, a PNG written by the pre-60a2993 renderer was a permanent cache hit.
        old_key = 'cacheDirectory().appendingPathComponent("\\(slug(botID, color)).png")'
        self.assertNotIn(old_key, FACE_CACHE)
