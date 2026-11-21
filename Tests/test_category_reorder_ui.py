"""Both apps can arrange categories, and neither one can arrange them alone.

The host keeps the arrangement (`PUT /v1/bot-categories/order`), `AppModel.moveBotCategory` sends
the whole order, and both surfaces are supposed to be nothing but a door onto that call. What this
pins is the UI end of that chain, which is where the regression lived:

* the Mac's heading menu shipped, but its two actions were `Task { try? await … }` — a refused move
  was swallowed, so the group stayed put with no word said;
* the phone had no door at all: a category could be created and renamed-elsewhere but never moved.

These are source-level assertions: the SwiftUI has no unit-test surface here, and the alternative —
a snapshot of a context menu — would not survive a styling pass. What they check is the wiring that
is easy to lose in a refactor and impossible to see in a diff: the verb exists on both targets, it
reaches `moveBotCategory`, the ends are gated by the model, and a refusal is put on screen.
"""

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text()
MAC = (ROOT / "Apps" / "HermesMac" / "Sidebar" / "SidebarBotList.swift").read_text()
IOS = (ROOT / "Apps" / "HermesMobile" / "Views" / "BotListScreen.swift").read_text()


class BothTargetsHaveTheControl(unittest.TestCase):
    def test_the_mac_menu_moves_one_step_each_way(self) -> None:
        self.assertIn("move(category, by: -1)", MAC, "Move Up must reach the model")
        self.assertIn("move(category, by: 1)", MAC, "Move Down must reach the model")

    def test_the_phone_moves_one_step_each_way(self) -> None:
        self.assertIn("move(category, by: -1)", IOS, "Move Up must reach the model")
        self.assertIn("move(category, by: 1)", IOS, "Move Down must reach the model")

    def test_both_verbs_are_in_a_menu_a_person_can_open(self) -> None:
        self.assertIn(".contextMenu {", MAC)
        self.assertIn('Label("Move “\\(category.name)” Up", systemImage: "arrow.up")', MAC)
        self.assertIn('Label("Move “\\(category.name)” Down", systemImage: "arrow.down")', MAC)
        # The phone has both doors: the long press every row already has, and a visible ⋯ on a
        # heading, because a long press on a heading is a gesture nobody discovers.
        self.assertIn(".contextMenu { categoryArrangeItems(group) }", IOS)
        self.assertIn("Menu {\n                    categoryArrangeItems(group)", IOS)
        self.assertIn('.accessibilityLabel("Arrange \\(group.name)")', IOS)


class TheCallPathIsTheOneThatAlreadyExisted(unittest.TestCase):
    """No second write path: the UI calls `moveBotCategory`, which calls the client once."""

    def test_both_targets_call_the_model(self) -> None:
        self.assertIn("model.moveBotCategory(id: category.id, by: offset)", MAC)
        self.assertIn("model.moveBotCategory(id: category.id, by: offset)", IOS)

    def test_neither_app_builds_an_id_list_of_its_own(self) -> None:
        """An app that sent ids could send ids the other device deleted, or a pinned group."""
        for name, source in (("Mac", MAC), ("iOS", IOS)):
            self.assertNotIn("reorderBotCategories", source,
                             f"{name} must not talk to the endpoint: the model owns the order")
            start = source.index("private func move(_ category: BotCategory")
            body = source[start:start + 600]
            self.assertNotIn("ids", body, f"{name}'s move must not assemble the arrangement")
            self.assertNotIn(".map(", body, f"{name}'s move must not assemble the arrangement")

    def test_the_order_is_sent_whole_by_the_model(self) -> None:
        self.assertIn("client.reorderBotCategories(ids: ids)", MODEL)
        self.assertIn("filter { !$0.isPinned && !$0.isUncategorized }", MODEL)


class PinnedAndUncategorizedNeverMove(unittest.TestCase):
    def test_the_phone_hides_the_verb_for_the_apps_own_headings(self) -> None:
        self.assertIn("guard !group.isPinned, !group.isUncategorized else { return nil }", IOS,
                      "the UI applies the model's rule, so the two cannot disagree")

    def test_the_phone_shows_no_offered_action_for_them(self) -> None:
        snippet = IOS[IOS.index("private func categoryArrangeItems"):]
        snippet = snippet[:snippet.index("private func groupHeader")]
        self.assertIn("if let category = arrangeableCategory(group)", snippet,
                      "the verbs are drawn only for a real category")

    def test_the_ends_are_greyed_out_from_the_model(self) -> None:
        for name, source in (("Mac", MAC), ("iOS", IOS)):
            self.assertIn(".disabled(!model.canMoveBotCategory(id: category.id, by: -1))", source,
                          f"{name} must not offer a move with nowhere to go")
            self.assertIn(".disabled(!model.canMoveBotCategory(id: category.id, by: 1))", source)
        self.assertIn("public func canMoveBotCategory(id: String, by offset: Int) -> Bool", MODEL)
        self.assertIn("public func moveBotCategory(id: String, by offset: Int) async throws", MODEL)


class ARefusedMoveIsSaidOutLoud(unittest.TestCase):
    def test_the_mac_no_longer_swallows_it(self) -> None:
        self.assertNotIn("try? await model.moveBotCategory", MAC,
                         "try? here moved the group on one device and said nothing")

    def test_the_mac_keeps_the_refusal_on_screen(self) -> None:
        self.assertIn('failure = "The host did not move “\\(category.name)”', MAC)
        # …and `failure` is what the alert above the list draws.
        self.assertIn('.alert("Category not changed"', MAC)
        self.assertIn("Text(failure ?? \"\")", MAC)

    def test_the_phone_writes_through_the_helper_that_reports(self) -> None:
        self.assertIn("writeCategories { try await model.moveBotCategory", IOS)
        self.assertIn('categoryError = "Category not saved: \\(error.localizedDescription)"', IOS)
        self.assertIn("if let failure = categoryError", IOS, "the sentence has to be drawn")

    def test_the_phone_logs_it_too(self) -> None:
        self.assertIn('ClientLog.note("bots.categories write failed:', IOS)


if __name__ == "__main__":
    unittest.main()
