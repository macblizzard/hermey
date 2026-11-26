"""One registry for the keyboard, and the rules that keep it the only one.

The owner asked for a Shortcuts panel in Settings. The panel is the visible half; the half that
matters is that there is **one** description of what each key does, that the Mac's menu bar reads it,
and that the panel draws it instead of a list of its own. Before this, three places disagreed: the
menu bar bound ⌘S for the bot panel and the ⌘K palette advertised ⌘⌥S, ⌘R was offered for "Refresh
this conversation" with nothing bound to it at all, and the bell's tooltip spelled ⇧⌘N beside a
`.keyboardShortcut` that spelled it again.

These tests read the Swift as text, which is what this suite can do without a Mac. They are written
so that the two failures that matter are loud: a second copy of an action (a title spelled in the
pane, a key spelled in the menu) and two actions holding one combination.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

REGISTRY = ROOT / "Sources" / "HermesKit" / "ShortcutRegistry.swift"
DOCUMENT = ROOT / "Sources" / "HermesKit" / "ShortcutDocument.swift"
CENTER = ROOT / "Apps" / "HermesMac" / "Shortcuts" / "ShortcutCenter.swift"
SYNC = ROOT / "Apps" / "HermesMac" / "Shortcuts" / "ShortcutMenuSync.swift"
RECORDER = ROOT / "Apps" / "HermesMac" / "Shortcuts" / "ShortcutRecorderField.swift"
PANE = ROOT / "Apps" / "HermesMac" / "Views" / "ShortcutsSettingsTab.swift"
SETTINGS = ROOT / "Apps" / "HermesMac" / "Views" / "MacSettingsView.swift"
APP = ROOT / "Apps" / "HermesMac" / "HermesMacApp.swift"
STORE = ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceStore.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def between(text: str, start: str, end: str) -> str:
    """The source between two markers, exclusive of `end`."""
    assert start in text, f"missing start marker: {start!r}"
    body = text.split(start, 1)[1]
    assert end in body, f"missing end marker: {end!r}"
    return body.split(end, 1)[0]


def combos_in(text: str) -> list[tuple[str, frozenset[str]]]:
    """Every `ShortcutCombo("k", .command, .shift)` call, as (key, modifiers)."""
    found: list[tuple[str, frozenset[str]]] = []
    for match in re.finditer(r'ShortcutCombo\(\s*"([^"]+)"((?:\s*,\s*\.\w+)*)\s*\)', text):
        key = match.group(1)
        modifiers = frozenset(re.findall(r"\.(\w+)", match.group(2)))
        found.append((key.lower(), modifiers))
    return found


def registry_rows() -> list[dict]:
    """The action table, one dict per `ShortcutAction(...)` call."""
    source = read(REGISTRY)
    table = between(source, "public static let actions: [ShortcutAction] = navigation + conversation + message + window",
                    "\n    public static func action(_ id: String)")
    # The four private arrays hold the rows; read the whole region that declares them.
    region = between(source, "private static let navigation: [ShortcutAction] = [",
                     "// MARK: Reserved")
    rows: list[dict] = []
    for block in region.split("ShortcutAction(")[1:]:
        body = block.split("\n        ShortcutAction(")[0]

        def field(name: str) -> str | None:
            match = re.search(rf"\n\s*{name}:\s*(.+?),\n", body, re.S)
            return match.group(1).strip() if match else None

        identifier = field("id")
        if not identifier:
            continue
        identifier = identifier.strip('"')
        default_raw = field("defaultCombo")
        combo = None
        if default_raw and default_raw != "nil":
            parsed = combos_in(default_raw)
            assert len(parsed) == 1, f"unreadable defaultCombo for {identifier}: {default_raw!r}"
            combo = parsed[0]
        rows.append(
            {
                "id": identifier,
                "title": (field("title") or "").strip('"'),
                "group": (field("group") or "").lstrip("."),
                "owner": (field("owner") or ".appMenu").lstrip("."),
                "combo": combo,
                "menu_titles": re.findall(r'"([^"]+)"', field("menuItemTitles") or ""),
                "raw": body,
            }
        )
    assert len(rows) >= 15, f"the registry parsed as {len(rows)} rows — the table shape moved"
    return rows


class RegistryShape(unittest.TestCase):
    def test_every_action_has_a_unique_id_a_group_and_a_title(self) -> None:
        rows = registry_rows()
        ids = [row["id"] for row in rows]
        self.assertEqual(len(ids), len(set(ids)), f"duplicate ids: {sorted(ids)}")
        for row in rows:
            self.assertRegex(row["id"], r"^[a-z]+(\.[A-Za-z]+)+$", f"{row['id']} is not namespaced")
            self.assertTrue(row["title"], f"{row['id']} has no title for the pane to draw")
            self.assertIn(row["group"], {"navigation", "conversation", "message", "window"},
                          f"{row['id']} is in no group")

    def test_every_action_declares_its_default_even_when_it_has_none(self) -> None:
        # `defaultCombo: nil` is a decision ("this one ships unbound"); a missing line would be an
        # accident that the pane and the menu would each answer differently.
        source = read(REGISTRY)
        region = between(source, "private static let navigation: [ShortcutAction] = [", "// MARK: Reserved")
        blocks = [block.split("\n        ShortcutAction(")[0] for block in region.split("ShortcutAction(")[1:]]
        for block in blocks:
            if "\n            id:" not in block:
                continue
            self.assertIn("defaultCombo:", block, f"no defaultCombo in:\n{block[:400]}")

    def test_no_two_actions_hold_the_same_combination(self) -> None:
        # THE duplicate guard. Two rows with one combination is not a style problem: the menu bar
        # would dispatch whichever it built last and the pane would show both as working.
        holders: dict[tuple[str, frozenset[str]], list[str]] = {}
        for row in registry_rows():
            if row["combo"] is None:
                continue
            holders.setdefault(row["combo"], []).append(row["id"])
        clashes = {combo: ids for combo, ids in holders.items() if len(ids) > 1}
        self.assertEqual(clashes, {}, f"two actions share a combination: {clashes}")

    def test_system_owned_rows_are_never_rebindable(self) -> None:
        for row in registry_rows():
            if row["owner"] == "system":
                self.assertIn("isRebindable", read(REGISTRY))
                self.assertFalse(row["raw"].lstrip().startswith("ShortcutAction(id:"),
                                 "a system row must be declared with its owner, like the rest")

    def test_the_reserved_list_covers_what_macos_keeps(self) -> None:
        source = read(REGISTRY)
        reserved = between(source, "public static let reserved: [ShortcutCombo] = [", "\n    ]")
        combos = combos_in(reserved)
        for key, modifiers in [("q", frozenset({"command"})),
                               ("w", frozenset({"command"})),
                               (",", frozenset({"command"}))]:
            self.assertIn((key, modifiers), combos, f"⌘{key.upper()} is not reserved")

    def test_a_reserved_combination_is_refused_before_anything_is_written(self) -> None:
        # The order inside `rejection(of:for:in:)` is the rule: reserved is checked before the
        # duplicate test, and `set` writes only after every rule passed.
        source = read(REGISTRY)
        body = between(source, "public static func rejection(of combo: ShortcutCombo,",
                       "/// The action the pane should show for a row")
        self.assertLess(body.index("reservedOwner(combo)"), body.index("document.owner(of: combo"))
        document = read(DOCUMENT)
        setter = between(document, "public mutating func set(_ binding: ShortcutBinding, for id: String)",
                         "/// Put one row back to its shipped combination.")
        self.assertLess(setter.index("ShortcutRegistry.rejection"), setter.index("bindings[id] = binding"))


class OnePane(unittest.TestCase):
    def test_the_pane_draws_the_registry_rather_than_a_hand_written_list(self) -> None:
        pane = read(PANE)
        self.assertIn("ShortcutRegistry.actions", pane)
        self.assertIn("ShortcutAction.Group.allCases", pane)
        self.assertIn("ForEach", pane)
        # No row may be spelled here: a title in *any* string literal in this file is a second copy
        # of the registry, even one stitched into a longer sentence.
        literals = re.findall(r'"((?:[^"\\]|\\.)*)"', pane)
        for row in registry_rows():
            for literal in literals:
                self.assertNotIn(row["title"], literal,
                                 f"{row['title']!r} is spelled in the pane; draw it from the registry")
        self.assertNotIn("ShortcutCombo(", pane, "the pane must not invent a combination")

    def test_the_pane_offers_a_recorder_a_reset_and_a_restore(self) -> None:
        pane = read(PANE)
        self.assertIn("ShortcutKeyChip(", pane)
        self.assertIn("center.reset(action.id)", pane)
        self.assertIn("center.restoreDefaults()", pane)
        self.assertIn('Button("Restore Defaults")', pane)
        # Every refusal is drawn under the row that caused it, from the registry's own sentence.
        self.assertIn("rejection.message", pane)

    def test_the_settings_window_carries_the_pane(self) -> None:
        settings = read(SETTINGS)
        self.assertIn("ShortcutsSettingsTab(center: store.shortcuts)", settings)
        self.assertIn('Label("Shortcuts", systemImage: "keyboard")', settings)

    def test_the_recorder_cancels_on_escape_and_clears_on_backspace(self) -> None:
        recorder = read(RECORDER)
        self.assertIn("event.keyCode == 53", recorder, "Escape must cancel")
        self.assertIn("event.keyCode == 51", recorder, "⌫ must clear the row")
        # The menu bar must not swallow a combination the owner is trying to record.
        self.assertIn("override func performKeyEquivalent(with event: NSEvent) -> Bool", recorder)


class OneMenu(unittest.TestCase):
    def test_the_mac_menu_spells_no_combination_of_its_own(self) -> None:
        app = read(APP)
        self.assertNotIn(".keyboardShortcut(", app,
                         "the app's menus must read the registry, not spell keys")
        self.assertIn(".hermeyShortcut(", app)

    def test_every_menu_action_is_wired_through_the_registry(self) -> None:
        app = read(APP)
        wired = set(re.findall(r'\.hermeyShortcut\("([^"]+)"', app))
        for row in registry_rows():
            if not row["menu_titles"]:
                continue  # a view-level row: the bell lives in the sidebar, not the menu bar
            if row["owner"] == "system":
                continue  # macOS draws that item: the Settings scene owns ⌘, and we must not
            self.assertIn(row["id"], wired,
                          f"{row['id']} has menu items but the menu never reads it")

    def test_every_identifier_the_app_binds_exists_in_the_registry(self) -> None:
        ids = {row["id"] for row in registry_rows()}
        used = set()
        for path in (APP, ROOT / "Apps" / "HermesMac" / "Sidebar" / "BotSidebarView.swift"):
            used |= set(re.findall(r'\.hermeyShortcut\("([^"]+)"', read(path)))
        unknown = used - ids
        self.assertEqual(unknown, set(), f"bound ids with no registry row: {sorted(unknown)}")

    def test_the_live_rebind_is_appkit_and_names_what_it_writes(self) -> None:
        # SwiftUI's `.keyboardShortcut` cannot be rebound at runtime: it is read when the menu item
        # is built. The sync pass is the mechanism, and it must write the two documented properties.
        sync = read(SYNC)
        self.assertIn("item.keyEquivalent = ", sync)
        self.assertIn("item.keyEquivalentModifierMask = ", sync)
        self.assertIn("NSApplication.didBecomeActiveNotification", sync,
                      "a rebuilt item carries the default again; activation repairs it")
        self.assertIn("action.owner == .appMenu", sync, "a system row is not ours to rewrite")

    def test_the_palette_hint_is_the_registrys_label(self) -> None:
        store = read(STORE)
        self.assertNotRegex(store, r'shortcut: "', "the palette must not spell a combination")
        for identifier in ("chat.find", "turn.interrupt", "view.sidebar", "host.connect",
                           "host.pair", "chat.refresh"):
            self.assertIn(f'shortcuts.label("{identifier}")', store)


class OneDocument(unittest.TestCase):
    def test_the_store_is_one_key_of_overrides(self) -> None:
        document = read(DOCUMENT)
        self.assertIn('public static let defaultsKey = "hermey.shortcuts"', document)
        self.assertIn("public static let version = 1", document)
        # Overrides only: an action with no stored row is at its default, so adding one is not a
        # migration.
        self.assertIn("if let stored = bindings[id] { return stored.combo }", document)
        self.assertIn("return action.defaultCombo", document)

    def test_unknown_ids_and_unreadable_rows_decode_without_throwing(self) -> None:
        document = read(DOCUMENT)
        # Per-entry tolerance: one bad row must not cost the owner every other binding.
        self.assertIn("private struct LenientBinding: Decodable", document)
        self.assertIn("binding = try? ShortcutBinding(from: decoder)", document)
        self.assertIn("guard ShortcutRegistry.action(id) != nil else { continue }", document)

    def test_a_cleared_row_stays_cleared(self) -> None:
        # `.unassigned` is a state, not a missing value: storing nothing would resurrect the default
        # on the next launch.
        document = read(DOCUMENT)
        self.assertIn("case unassigned", document)
        self.assertIn("try container.encodeNil()", document)


class MessageVerbs(unittest.TestCase):
    def test_the_last_message_verbs_go_through_the_models_own_methods(self) -> None:
        store = read(STORE)
        self.assertIn("func copyLastMessage()", store)
        self.assertIn("func editLastMessage()", store)
        self.assertIn("func deleteLastMessage()", store)
        self.assertIn("model.requestEditAndResend(entry)", store)
        self.assertIn("model.requestDelete(entry)", store)
        # A tool card or the model's reasoning is never "the last message" for these verbs.
        self.assertIn("($0.role == .user || $0.role == .assistant) && !$0.text.isEmpty", store)

    def test_the_bot_walk_is_one_method(self) -> None:
        store = read(STORE)
        self.assertIn("func stepBot(_ delta: Int)", store)
        self.assertIn("((current + delta) % bots.count + bots.count) % bots.count", store)


if __name__ == "__main__":
    unittest.main()
