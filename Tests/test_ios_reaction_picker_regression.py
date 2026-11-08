"""Source-level guards for iOS reaction picker wiring; not a UI test."""
from pathlib import Path
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "Apps/HermesMobile/Views/MobileTranscript.swift"


class ReactionPickerRegressionTests(unittest.TestCase):
    def test_reaction_action_presents_compact_grid_and_selection_dismisses(self):
        source = SOURCE.read_text()
        self.assertIn('Button { showingReactionPicker = true } label:', source)
        self.assertIn('.popover(isPresented: $showingReactionPicker', source)
        self.assertIn('.presentationCompactAdaptation(.popover)', source)
        self.assertIn('LazyVGrid(', source)
        self.assertIn('setReaction(emoji)\n', source)
        self.assertIn('showingReactionPicker = false', source)
        self.assertNotIn('Menu {\n                    ForEach(Self.emojis', source)

    def test_existing_reaction_storage_and_toggle_remain_wired(self):
        source = SOURCE.read_text()
        self.assertIn('@AppStorage("mobile.messageReactions.v1")', source)
        self.assertIn('values[key] = values[key] == emoji ? nil : emoji', source)
        self.assertIn('.accessibilityLabel("Remove reaction \\(emoji)")', source)
        self.assertIn('.accessibilityLabel("React with \\(emoji)")', source)


if __name__ == "__main__":
    unittest.main()
