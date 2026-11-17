"""The launch face blinks — and does nothing else.

Asked for 2026-11-17: "would it be possible to add a eye blink on app boot screen during bootup". The
splash had been deliberately still (its own doc said so), so this pins the *scope* of the change as much
as the feature: two eyelids, a short close and open, a random rest between blinks, nothing per frame, and
nothing at all under Reduce Motion.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BOOT = (ROOT / "Sources" / "HermeyUI" / "BootScreen.swift").read_text(encoding="utf-8")


class TheBootFaceBlinks(unittest.TestCase):
    def testThereAreTwoEyelidsOverTheMark(self) -> None:
        self.assertIn("static let eyelids: [CGRect]", BOOT)
        self.assertIn(".overlay { eyelids }", BOOT,
                      "the lids must sit over the mark, not beside it")

    def testTheGeometryMatchesTheArtwork(self) -> None:
        # Measured from Resources/HermeyMark.png (790 x 770): the two dark bars are at
        # x 215–329 / 460–574 and y 266–455 / 283–472. A lid drawn anywhere else paints the face.
        self.assertIn("215.0 / 790", BOOT)
        self.assertIn("460.0 / 790", BOOT)
        self.assertIn("266.0 / 770", BOOT)
        self.assertIn("283.0 / 770", BOOT)
        self.assertIn("115.0 / 790", BOOT)
        self.assertIn("190.0 / 770", BOOT)

    def testTheLidUsesTheFacesOwnShading(self) -> None:
        # Sampled, not invented: the face is 250 where the bars begin and 206 where they end. A flat
        # colour, or the chin's 169, shows as a painted rectangle for the 90 ms the lid is up.
        self.assertIn("Color(white: 250.0 / 255)", BOOT)
        self.assertIn("Color(white: 206.0 / 255)", BOOT)

    def testItIsAShortBlinkNotALoopOfFrames(self) -> None:
        self.assertIn("static let lidCloseDuration: Double = 0.09", BOOT)
        self.assertIn("static let lidOpenDuration: Double = 0.14", BOOT)
        # A blink every ~4 s, and an early one so a fast launch still shows it.
        self.assertRegex(BOOT, r"blinkInterval: ClosedRange<Double> = 3\.4 \.\.\. 5\.6")
        self.assertIn("static let firstBlinkDelay: Double = 0.55", BOOT)
        # No TimelineView and no repeating animation: those are per-frame work on the launch path. The
        # word may appear in prose (the doc says what it does not use), never as an initialiser.
        self.assertNotIn("TimelineView(", BOOT)
        self.assertNotIn("repeatForever", BOOT)

    def testReduceMotionKeepsTheFaceOpen(self) -> None:
        self.assertIn("@Environment(\\.accessibilityReduceMotion) private var reduceMotion", BOOT)
        self.assertRegex(BOOT, r"guard !reduceMotion else \{ return \}")

    def testTheTaskIsCancellable(self) -> None:
        # The screen goes away in well under a second on a warm launch; a sleep loop that outlived it
        # would keep waking for nothing.
        self.assertIn(".task { await blink() }", BOOT)
        self.assertIn("while !Task.isCancelled", BOOT)

    def testTheDocSaysWhatChanged(self) -> None:
        # The old heading promised a face that never moves, which is now false.
        self.assertNotIn("## It does not move", BOOT)
        self.assertIn("## It blinks, and does nothing else", BOOT)
