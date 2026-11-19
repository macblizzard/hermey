"""Right-click a category on the Mac to move it up or down.

Asked for 2026-11-19: the categories could be renamed and deleted from the context menu but not
arranged, and the list sorted them by name, so there was no order to arrange in the first place.

The shape these pin is the one that survives two devices:

* the arrangement is the host's, stored with the categories, not a per-device preference;
* an empty arrangement means "nobody has arranged them" and still reads alphabetically, so an
  install that never uses the menu looks exactly as it did;
* the arrangement is sent whole, never as "move X up", because a swap computed from a document
  another device already changed moves the wrong group;
* Pinned and Uncategorized are the app's own headings and never enter the arrangement.
"""

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
BRIDGE = (ROOT / "Bridge" / "hermes_bridge" / "bot_categories.py").read_text()
GROUPING = (ROOT / "Sources" / "HermesAppKit" / "BotGrouping.swift").read_text()
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text()
STATE = (ROOT / "Sources" / "HermesKit" / "BotCategories.swift").read_text()
CLIENT = (ROOT / "Sources" / "HermesKit" / "EndlessSessionPointer.swift").read_text()
SIDEBAR = (ROOT / "Apps" / "HermesMac" / "Sidebar" / "SidebarBotList.swift").read_text()
SESSION = (ROOT / "Sources" / "HermesKit" / "EndlessSessionPointer.swift").read_text()
PROTOCOL = (ROOT / "Sources" / "HermesKit" / "GatewayClient.swift").read_text()


class TheHostKeepsTheArrangement(unittest.TestCase):
    def test_there_is_a_route_for_it(self) -> None:
        self.assertIn('@router.put("/bot-categories/order")', BRIDGE)

    def test_it_rejects_ids_it_does_not_know(self) -> None:
        """A device with a stale document cannot add a category by arranging it."""
        self.assertIn("data[\"order\"] = [cid for cid in body.ids if cid in known]", BRIDGE)

    def test_deleting_a_category_drops_it_from_the_arrangement(self) -> None:
        self.assertIn('data["order"] = [cid for cid in data["order"] if cid != category_id]', BRIDGE)

    def test_the_document_comes_back_already_arranged(self) -> None:
        """A reader that ignores `order` still draws what the owner arranged."""
        self.assertIn("ids = _ordered_ids(data)", BRIDGE)
        self.assertIn("categories\": [by_id[cid] for cid in ids if cid in by_id]", BRIDGE)


class TheListFollowsTheArrangement(unittest.TestCase):
    def test_grouping_asks_for_the_arrangement(self) -> None:
        self.assertIn("arranged(state.categories, by: state.order)", GROUPING)

    def test_an_empty_arrangement_stays_alphabetical(self) -> None:
        self.assertIn("guard !order.isEmpty else { return alphabetical }", GROUPING)
        self.assertIn("localizedCaseInsensitiveCompare", GROUPING)

    def test_a_category_outside_the_arrangement_takes_its_alphabetical_place(self) -> None:
        self.assertIn("rank[left.element.id] ?? Int.max", GROUPING,
                      "an unknown id must sort by name among the others, not jump to the end")

    def test_the_state_decodes_a_document_without_an_order(self) -> None:
        """The cache on disk predates `order`; a missing key must not fail the launch."""
        self.assertIn("decodeIfPresent([String].self, forKey: .order) ?? []", STATE)


class TheMenuMovesOneStep(unittest.TestCase):
    def test_up_and_down_are_in_the_category_context_menu(self) -> None:
        self.assertIn('Label("Move “\\(category.name)” Up", systemImage: "arrow.up")', SIDEBAR)
        self.assertIn('Label("Move “\\(category.name)” Down", systemImage: "arrow.down")', SIDEBAR)

    def test_the_items_are_disabled_where_there_is_nowhere_to_go(self) -> None:
        self.assertIn(".disabled(!model.canMoveBotCategory(id: category.id, by: -1))", SIDEBAR)
        self.assertIn(".disabled(!model.canMoveBotCategory(id: category.id, by: 1))", SIDEBAR)

    def test_the_move_is_computed_from_what_is_drawn(self) -> None:
        """'Up' is the group above the one you right-clicked, not the one above it in the file."""
        self.assertIn("filter { !$0.isPinned && !$0.isUncategorized }", MODEL)
        self.assertIn("ids.swapAt(from, to)", MODEL)

    def test_it_sends_the_arrangement_rather_than_a_swap(self) -> None:
        self.assertIn("client.reorderBotCategories(ids: ids)", MODEL)
        self.assertIn('bridgePUT("v1/bot-categories/order"', CLIENT)
        self.assertIn("body: [\"ids\": ids]", CLIENT)

    def test_every_layer_declares_the_call(self) -> None:
        """AppModel holds `GatewayClientProtocol`, not the actor: the actor alone is not enough.

        Pinned because it cost a build — the method went on the actor and on the inner session
        pointer while the protocol AppModel actually holds said nothing about it.
        """
        signature = "func reorderBotCategories(ids: [String]) async throws -> BotCategoryState"
        self.assertIn(signature, PROTOCOL, "GatewayClientProtocol is what AppModel calls")
        self.assertIn(signature, SESSION, "the inner pointer needs the same member")
        self.assertIn("throw BotAdminUnavailable()", PROTOCOL)

    def test_a_move_off_the_end_never_reaches_the_host(self) -> None:
        self.assertIn("guard ids.indices.contains(to) else { return }", MODEL)


if __name__ == "__main__":
    unittest.main()
