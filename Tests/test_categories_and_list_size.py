"""Categories on the host, headings in both lists, and one size slider.

Asked for 2026-11-15. What is pinned here is the part a user would notice breaking:

* the groups are the *host's* — one file, read by both apps, so the phone and the Mac cannot
  disagree;
* Pinned comes first and Uncategorized last, and neither is a category anyone can delete;
* a category with no bots is still drawn, so it can be filled or deleted;
* the size slider defaults to the size the list shipped with, and both settings screens have it.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# The host service is the Rust crate in `hermeyd/` now; categories are a document there.
BRIDGE = ROOT / "hermeyd" / "src" / "bridge_routes.rs"
APP_PY = (ROOT / "hermeyd" / "src" / "main.rs").read_text(encoding="utf-8")
GROUPING = (ROOT / "Sources" / "HermesAppKit" / "BotGrouping.swift").read_text(encoding="utf-8")
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")
IOS_LIST = (ROOT / "Apps" / "HermesMobile" / "Views" / "BotListScreen.swift").read_text(encoding="utf-8")
MAC_LIST = (ROOT / "Apps" / "HermesMac" / "Sidebar" / "SidebarBotList.swift").read_text(encoding="utf-8")
ADMIN = (ROOT / "Sources" / "HermeyUI" / "BotAdminViews.swift").read_text(encoding="utf-8")
METRICS = (ROOT / "Sources" / "HermeyUI" / "BotListMetrics.swift").read_text(encoding="utf-8")
IOS_SETTINGS = (ROOT / "Apps" / "HermesMobile" / "Views" / "SettingsScreen.swift").read_text(encoding="utf-8")
MAC_SETTINGS = (ROOT / "Apps" / "HermesMac" / "Views" / "AppearanceSettingsTab.swift").read_text(encoding="utf-8")
POINTER = (ROOT / "Sources" / "HermesKit" / "EndlessSessionPointer.swift").read_text(encoding="utf-8")
MAC_STORE = (ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceStore.swift").read_text(encoding="utf-8")


class TheHostOwnsTheGroups(unittest.TestCase):
    def test_the_routes_exist_and_are_mounted(self) -> None:
        # Retargeted from `hermes_bridge/bot_categories.py` (deleted with the Python bridge):
        # hermeyd mounts each verb explicitly on one path.
        source = BRIDGE.read_text(encoding="utf-8")
        for handler in ("get_categories", "post_categories", "patch_category",
                        "delete_category", "put_bot_category", "put_category_order"):
            self.assertIn(f"pub async fn {handler}(", source, handler)
        self.assertIn('"/v1/bot-categories"', APP_PY)
        self.assertIn('"/v1/bot-categories/{category}"', APP_PY)
        self.assertIn('"/v1/bots/{profile}/category"', APP_PY)

    # Removed with the Python bridge: `test_every_mutation_is_one_locked_read_modify_write`
    # guarded `bot_categories.py`'s file lock (`_lock_for(path)` / `mutate(runtime, change)`) and
    # `test_last_write_wins_is_the_documented_rule` guarded its docstring. hermeyd has no file to
    # lock: the document is a row in the service's SQLite store, read and written under one
    # connection, so the race those tests existed for cannot take that shape. Nothing in this
    # repository can assert it without inventing a symbol.

    def test_the_client_contract_is_read_on_connect_and_after_a_write(self) -> None:
        # The Mac read the roster on connect and never the groups: creating one on the phone was
        # invisible there. Both of these are the fix, and both are easy to delete by accident.
        self.assertIn("await loadBotCategories()", MODEL.split("public func start()", 1)[1].split("public func stop()", 1)[0])
        self.assertIn("await model.loadBotCategories()", MAC_STORE)
        # And after a write, the document is re-read from the host instead of trusted from the answer.
        self.assertIn("await loadBotCategories()", MODEL.split("private func writeBotCategories", 1)[1])

    def test_the_last_document_is_cached_per_host_and_read_before_the_wire(self) -> None:
        self.assertIn('private var botCategoriesKey: String { "hermes.botCategories.\\(hostName)" }', MODEL)
        self.assertIn("loadCachedBotCategories()", MODEL.split("public init(client:", 1)[1])
        # Offline is a read cache, never a second place a group can be created.
        self.assertIn("guard let data = Self.defaults.data(forKey: botCategoriesKey)", MODEL)

    def test_the_phone_says_when_a_category_write_did_not_land(self) -> None:
        self.assertIn("writeCategories", IOS_LIST)
        self.assertNotIn("try? await model.addBotCategory", IOS_LIST)
        self.assertNotIn("try? await model.setBotCategory", IOS_LIST)
        self.assertIn("Category not saved", IOS_LIST)

    def test_deleting_a_group_never_deletes_a_bot(self) -> None:
        source = BRIDGE.read_text(encoding="utf-8")
        body = source.split("pub async fn delete_category(", 1)[1].split("pub async fn ", 1)[0]
        # The assignment is what is dropped, and the bot falls to Uncategorized by having none.
        self.assertIn('map.retain(|_, v| v.as_str() != Some(category.as_str()))', body)
        self.assertNotIn("purge", body)
        self.assertNotIn("remove_dir_all", body)

    # Removed with the Python bridge: `test_the_file_lives_beside_the_bridge_database` pinned
    # `bot-categories.json` next to the bridge's SQLite file. hermeyd keeps the same document in its
    # own `documents` table (`DOC_CATEGORIES`), so there is no second file to point at.

    def test_the_client_speaks_all_five_verbs(self) -> None:
        for call in ['"v1/bot-categories"', 'bridgePATCH("v1/bot-categories/', 'bridgeDELETE("v1/bot-categories/',
                     '"v1/bots/\\(name)/category"']:
            self.assertIn(call, POINTER)


class TheListIsGrouped(unittest.TestCase):
    def test_pinned_first_and_uncategorized_last(self) -> None:
        self.assertIn('public static let pinnedID', GROUPING)
        self.assertIn('public static let uncategorizedID', GROUPING)
        # Pinned is appended before the categories, Uncategorized after them.
        pinned_at = GROUPING.index("isPinned: true")
        categories_at = GROUPING.index("for category in arranged(state.categories, by: state.order)")
        uncategorized_at = GROUPING.index("isUncategorized: true")
        self.assertLess(pinned_at, categories_at)
        self.assertLess(categories_at, uncategorized_at)

    def test_an_empty_category_is_still_drawn(self) -> None:
        # The loop appends every category in the document, member or not.
        self.assertIn("bots: byCategory[category.id] ?? []", GROUPING)
        self.assertIn("groups.append(BotGroup(id: category.id", GROUPING)

    def test_a_pinned_bot_is_not_drawn_twice(self) -> None:
        self.assertIn("if pinned.contains(bot.id) { continue }", GROUPING)

    def test_both_lists_draw_the_headings(self) -> None:
        self.assertIn("ForEach(model.botGroups)", IOS_LIST)
        self.assertIn("ForEach(model.botGroups)", MAC_LIST)
        # A search stays flat in both apps.
        self.assertIn("if isSearching {", MAC_LIST)
        self.assertIn("} else if !trimmedQuery.isEmpty {", IOS_LIST)

    def test_collapsing_is_remembered_per_device(self) -> None:
        self.assertIn("@AppStorage(\"hermey.collapsedBotGroups\")", IOS_LIST)
        self.assertIn("@AppStorage(\"hermey.collapsedBotGroups.mac\")", MAC_LIST)

    def test_a_category_is_added_from_the_plus_menu(self) -> None:
        self.assertIn('Label("Add category", systemImage: "folder.badge.plus")', IOS_LIST)
        self.assertIn('.alert("New category"', IOS_LIST)

    def test_manage_bots_can_file_a_bot(self) -> None:
        self.assertIn("Picker(\"Category\"", ADMIN)
        self.assertIn("onSetCategory", ADMIN)
        self.assertIn("categories: model.botCategories", IOS_LIST)
        self.assertIn("categories: model.botCategories",
                      (ROOT / "Apps" / "HermesMac" / "Sidebar" / "BotSidebarView.swift").read_text(encoding="utf-8"))


class TheSizeSliderIsOneNumber(unittest.TestCase):
    def test_the_default_is_the_shipped_size(self) -> None:
        self.assertIn("public static let defaultScale: Double = 1", METRICS)
        self.assertIn("public static let storageKey = \"hermey.botListScale\"", METRICS)

    def test_it_is_clamped_at_both_ends(self) -> None:
        self.assertIn("public static let minScale: Double = 0.85", METRICS)
        self.assertIn("public static let maxScale: Double = 1.35", METRICS)
        self.assertIn("min(max(scale, Self.minScale), Self.maxScale)", METRICS)

    def test_every_part_of_the_row_comes_from_it(self) -> None:
        for token in ("avatar", "rowHeight", "rowPadding", "gap", "nameSize", "previewSize"):
            self.assertIn(f"public var {token}", METRICS)
        # The row itself reads the metrics, not the fixed tokens.
        self.assertIn("size: metrics.avatar", IOS_LIST)
        self.assertIn("size: metrics.avatar", MAC_LIST)
        self.assertIn(".frame(minHeight: metrics.rowHeight)", IOS_LIST)
        self.assertIn(".frame(height: metrics.rowHeight)", MAC_LIST)

    def test_both_settings_screens_have_the_slider(self) -> None:
        for screen in (IOS_SETTINGS, MAC_SETTINGS):
            self.assertIn("BotListMetrics.minScale...BotListMetrics.maxScale", screen)
            self.assertIn("BotListScalePreview(scale: listScale)", screen)


if __name__ == "__main__":
    unittest.main()
