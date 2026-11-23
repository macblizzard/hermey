"""Source-level guards for the phone's reactions; not a UI test.

The picker used to be a grid behind an "Add reaction" menu item. The emoji now sit on the card a long
press raises (`QuickReactionRow`, shared with the Mac), so these guards point at the card and at the
shared row instead of at the old grid.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Apps/HermesMobile/Views/MobileTranscript.swift").read_text(encoding="utf-8")
ROW = (ROOT / "Sources/HermeyUI/QuickReactionRow.swift").read_text(encoding="utf-8")


class ReactionPickerRegressionTests(unittest.TestCase):
    def test_the_long_press_card_carries_the_reactions(self):
        self.assertIn("showingActions = true", SOURCE)
        self.assertIn(".popover(isPresented: $showingActions", SOURCE)
        self.assertIn(".presentationCompactAdaptation(.popover)", SOURCE)
        self.assertIn("QuickReactionRow(selected:", SOURCE)
        self.assertIn("setReaction(emoji)", SOURCE)
        self.assertIn("showingActions = false", SOURCE)
        # The two-step door is gone: no grid, no "Add reaction" item.
        self.assertNotIn("showingReactionPicker", SOURCE)
        self.assertNotIn('Label("Add reaction"', SOURCE)

    def test_the_shared_row_is_accessible_and_toggles(self):
        self.assertIn('.accessibilityLabel(ReactionEmoji.name(emoji))', ROW)
        self.assertIn('"React with \\(emoji)"', ROW)
        self.assertIn('"Select again to remove this reaction"', ROW)

    def test_the_reaction_is_shared_rather_than_kept_on_the_device(self):
        # The storage moved: it used to be this app's `@AppStorage`, which is why a reaction made on
        # the Mac never appeared here. One key rule (shared with the Mac) and the model's map now.
        self.assertIn("ReactionKey.message(rowID: entry.rowID, entryID: entry.id)", SOURCE)
        self.assertIn("app.model.reaction(for: key)", SOURCE)
        self.assertIn("await app.model.setReaction(next, for: key)", SOURCE)
        # The toggle is unchanged: tapping the emoji already there clears it.
        self.assertIn("currentReaction == emoji ? nil : emoji", SOURCE)
        self.assertIn('.accessibilityLabel("Remove \\(ReactionEmoji.name(emoji)) reaction")', SOURCE)
        # And the row no longer writes a device-local document of its own.
        self.assertNotIn('@AppStorage("', SOURCE)
        self.assertNotIn("storedReactions", SOURCE)


if __name__ == "__main__":
    unittest.main()
