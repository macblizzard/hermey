"""Source-level guards for the phone's reactions; not a UI test.

The picker used to be a grid behind an "Add reaction" menu item. The emoji now sit on the card a long
press raises (`QuickReactionRow`, shared with the Mac), so these guards point at the card and at the
shared row instead of at the old grid.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Apps/HermesMobile/Views/MobileTranscript.swift").read_text(encoding="utf-8")
ROW = (ROOT / "Sources/OpenBotUI/QuickReactionRow.swift").read_text(encoding="utf-8")


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
        self.assertIn('.accessibilityLabel(emoji)', ROW)
        self.assertIn('"React with \\(emoji)"', ROW)
        self.assertIn('"Select again to remove this reaction"', ROW)

    def test_existing_reaction_storage_and_toggle_remain_wired(self):
        self.assertIn('@AppStorage("mobile.messageReactions.v1")', SOURCE)
        self.assertIn('values[key] = values[key] == emoji ? nil : emoji', SOURCE)
        self.assertIn('.accessibilityLabel("Remove reaction \\(emoji)")', SOURCE)


if __name__ == "__main__":
    unittest.main()
