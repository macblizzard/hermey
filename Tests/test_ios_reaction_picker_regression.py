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
        self.assertIn("QuickReactionRow(selected: reaction)", SOURCE)
        self.assertIn("onReact(emoji)", SOURCE)
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
        # the Mac never appeared here. The model owns the key and the map now; the row is handed a
        # *value* so a badge that arrives by WS repaints the row it belongs to instead of waiting for
        # the next scroll (a row that reached into a model it does not observe never repainted).
        self.assertIn("var reaction: String? = nil", SOURCE)
        self.assertIn("var onReact: (String) -> Void = { _ in }", SOURCE)
        self.assertIn("if let emoji = reaction {", SOURCE)
        self.assertIn("Button(emoji) { onReact(emoji) }", SOURCE)
        self.assertIn(r'.accessibilityLabel("Remove your \(ReactionEmoji.name(emoji)) reaction")',
                      SOURCE)
        # The screen is what reads and writes, through the model's one rule.
        screen = (ROOT / "Apps" / "HermesMobile" / "Views" / "ConversationScreen.swift").read_text()
        self.assertIn("reaction: model.reaction(forRowID: entry.rowID,", screen)
        self.assertIn("entryID: entry.id)", screen)
        self.assertIn("Task { await model.react(emoji, rowID: entry.rowID,", screen)
        # And the row no longer spells a key or writes a device-local document of its own.
        self.assertNotIn("ReactionKey(", SOURCE)
        self.assertNotIn('@AppStorage("', SOURCE)
        self.assertNotIn("storedReactions", SOURCE)


if __name__ == "__main__":
    unittest.main()
