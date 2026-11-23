"""The panel's two rows of chrome, and the one list of what is waiting.

The owner's arrangement, pinned because it is geometry a compiler cannot see:

* the top row holds **exactly** two verbs — the bell and the ＋ — right-aligned;
* the floor holds Settings on the left, search and the panel's toggle on the right;
* the bell and the ＋ open a list built from the model's own `unreadCounts` / `unreadBots`, and
  reading a row goes through `markBotRead` (no second unread source anywhere);
* the floor dissolves into the list with the mirror of the header's own fade;
* on iOS the bell sits immediately left of Settings and opens the same list.

The Mac source is read as text: these are arrangements, not behaviours a test can call.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

MAC = (ROOT / "Apps" / "HermesMac" / "Sidebar" / "BotSidebarView.swift").read_text(encoding="utf-8")
IOS_LIST = (ROOT / "Apps" / "HermesMobile" / "Views" / "BotListScreen.swift").read_text(encoding="utf-8")
SHARED = (ROOT / "Sources" / "HermeyUI" / "WaitingBotsInbox.swift").read_text(encoding="utf-8")
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")


def block(source: str, opening: str, closing: str) -> str:
    """The text between one declaration and the next marker, exclusive."""
    assert opening in source, f"{opening!r} is gone"
    tail = source.split(opening, 1)[1]
    assert closing in tail, f"{closing!r} did not follow {opening!r}"
    return tail.split(closing, 1)[0]


class TopRowIsTheBellAndThePlus(unittest.TestCase):
    """Two verbs, right-aligned, and nothing else."""

    def setUp(self) -> None:
        self.header = block(MAC, "private var header: some View {", "    /// Everything waiting")

    def test_the_bell_and_the_plus_are_the_row(self) -> None:
        self.assertIn("notificationsButton", self.header)
        self.assertIn("addMenu", self.header)

    def test_the_old_verbs_are_not_in_the_top_row(self) -> None:
        # Search, the panel's toggle and Settings all moved to the floor. Any of them still up here
        # would be the row the owner asked to end — four glyphs and two groups.
        for moved in ("magnifyingglass", "sidebar.left", "SettingsLink", "gearshape"):
            self.assertNotIn(moved, self.header, f"{moved} is still in the top row")

    def test_the_row_is_still_a_title_bar(self) -> None:
        # The drag area is what makes the empty left half of the row do something; losing it costs
        # the window its double-click-to-zoom target (reported 2026-11-17).
        self.assertIn("TitlebarDragArea()", self.header)
        self.assertIn("WorkspaceShell.titlebarStrip", self.header)


class FloorHoldsTheOtherVerbs(unittest.TestCase):
    """Settings bottom-left; search and the sidebar toggle bottom-right."""

    def setUp(self) -> None:
        self.bar = block(MAC, "private var bottomBar: some View {", "    // MARK: Waiting")

    def test_settings_is_on_the_left_and_the_panel_controls_on_the_right(self) -> None:
        gear = self.bar.index("SettingsLink")
        spacer = self.bar.index("Spacer(minLength: 0)")
        search = self.bar.index("magnifyingglass")
        toggle = self.bar.index("sidebar.left")
        self.assertLess(gear, spacer, "Settings must be the left group")
        self.assertLess(spacer, search, "search must be in the right group")
        self.assertLess(search, toggle, "the toggle is the last control on the row")
        # Exactly one Settings door on the panel, and it is the floor's.
        self.assertEqual(MAC.count("SettingsLink"), 1)

    def test_the_bar_does_not_scroll_with_the_list(self) -> None:
        body = block(MAC, "var body: some View {", "        .background(Tokens.sidebar)")
        # The list (and its dissolve) come first; the floor is a sibling *after* them, so it cannot
        # scroll away with the rows.
        self.assertLess(body.index("ZStack(alignment: .bottom)"), body.index("bottomDissolve"))
        self.assertLess(body.index("bottomDissolve"), body.index("bottomChrome"))

    def test_the_bar_is_the_same_height_and_fill_as_the_window(self) -> None:
        self.assertIn("Self.bottomBarHeight", self.bar)
        self.assertIn(".background(Tokens.sidebar)", self.bar)
        self.assertIn("private static let bottomBarHeight: CGFloat = 34", MAC)

    def test_search_expands_above_the_bar_rather_than_inside_it(self) -> None:
        chrome = block(MAC, "private var bottomChrome: some View {", "    /// The live field")
        # The field is stacked *over* the bar, not given a slot inside it: the bar's grouping never
        # moves when someone types.
        self.assertLess(chrome.index("searchRow"), chrome.index("bottomBar"))


class TheFloorDissolvesIntoTheList(unittest.TestCase):
    """The owner's addition: the bar's edge is the header's fade, mirrored."""

    def setUp(self) -> None:
        self.top = block(MAC, "private var listFade: some View {", "    /// The bottom of the same dissolve")
        self.bottom = block(MAC, "private var bottomDissolve: some View {",
                            "    /// The height of one end of the dissolve")

    def test_both_ends_are_the_same_height(self) -> None:
        self.assertIn("Self.dissolveHeight", self.top)
        self.assertIn("private static let dissolveHeight: CGFloat = 26", MAC)
        self.assertIn("bottomDissolve\n                    .frame(height: Self.dissolveHeight)", MAC)
        self.assertNotIn(".frame(height: 26)", MAC, "a hardcoded leg would drift from its mirror")

    def test_the_top_end_fades_in_from_the_header(self) -> None:
        self.assertIn("LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)",
                      self.top)
        # One leg only: the bottom of the list is the floor's scrim now, not a second mask leg.
        self.assertNotIn("[.black, .clear]", self.top)

    def test_the_bottom_end_is_the_mirror_in_the_panels_own_fill(self) -> None:
        self.assertIn("LinearGradient(colors: [Tokens.sidebar, Tokens.sidebar.opacity(0)]",
                      self.bottom)
        self.assertIn("startPoint: .bottom", self.bottom)
        self.assertIn("endPoint: .top", self.bottom)
        # Transparent where the rows are, opaque where the bar is — the same story as the top leg,
        # told from the other end.
        self.assertIn("opacity(0)", self.bottom)

    def test_the_bar_has_no_hard_edge_of_its_own(self) -> None:
        bar = block(MAC, "private var bottomBar: some View {", "    // MARK: Waiting")
        # No hairline and no rule over the dissolve: the gradient is the separation, and a line on
        # top of it is the cut it exists to replace.
        self.assertNotIn("Divider()", bar)
        self.assertNotIn(".overlay(alignment: .top)", bar)
        # …and the dissolve is drawn over the list, above the bar, so the bar's fill is what the
        # rows fade into.
        self.assertIn("bottomDissolve\n                    .frame(height: Self.dissolveHeight)",
                      MAC)


class NotificationsReadTheModelsOwnUnread(unittest.TestCase):
    """One source: `unreadCounts` / `unreadBots`, cleared through `markBotRead`."""

    def test_the_model_is_the_authority(self) -> None:
        self.assertIn("public private(set) var unreadCounts: [String: Int]", MODEL)
        self.assertIn("public private(set) var unreadBots: Set<String>", MODEL)

    def test_the_rows_take_both_statements_and_the_preview_cache(self) -> None:
        self.assertIn("public static func rows(unread: Set<String>,", SHARED)
        self.assertIn("counts: [String: Int],", SHARED)
        self.assertIn("previews: [String: String] = [:]", SHARED)
        self.assertIn("faces: [String: String] = [:]", SHARED)
        # A bot in neither statement is not a row; a swept zero is not a reply.
        self.assertIn("Set(unread).union(counts.keys)", SHARED)
        self.assertIn("guard count > 0 else { continue }", SHARED)

    def test_count_then_name_is_the_order(self) -> None:
        self.assertIn("if lhs.count != rhs.count { return lhs.count > rhs.count }", SHARED)
        self.assertIn("localizedCaseInsensitiveCompare(rhs.name)", SHARED)

    def test_the_preview_is_the_first_line_only(self) -> None:
        self.assertIn("public static func firstLine(_ raw: String?) -> String?", SHARED)
        self.assertIn("$0.isNewline", SHARED)
        self.assertIn("public static let previewLimit", SHARED)

    def test_the_mac_builds_them_from_the_model_and_clears_with_mark_bot_read(self) -> None:
        waiting = block(MAC, "private var waitingBots: [WaitingBot] {", "    private var waitingNames")
        self.assertIn("store.model.unreadBots", waiting)
        self.assertIn("store.model.unreadCounts", waiting)
        self.assertIn("store.model.botPreviews", waiting)
        self.assertIn("store.botFaces.mapValues { $0.raw }", MAC)
        bell = block(MAC, "private var notificationsButton: some View {", "    // MARK: Floor")
        self.assertIn("store.model.markBotRead(botID)", bell)
        self.assertIn("store.selectBot(botID)", bell)

    def test_the_phone_builds_the_same_list_the_same_way(self) -> None:
        waiting = block(IOS_LIST, "private var waitingBots: [WaitingBot] {", "    /// Bot settings:")
        for source in ("model.unreadBots", "model.unreadCounts", "model.botPreviews",
                       "app.botFaces.mapValues { $0.raw }"):
            self.assertIn(source, waiting, f"the phone stopped reading {source}")
        sheet = block(IOS_LIST, ".sheet(isPresented: $showWaiting)", ".sheet(isPresented: $showStartGroupChat)")
        self.assertIn("model.markBotRead(botID)", sheet)
        self.assertIn("WaitingBotsInbox(bots: waitingBots)", sheet)

    def test_a_row_is_the_avatar_the_name_the_count_and_the_line(self) -> None:
        row = block(SHARED, "private func row(_ bot: WaitingBot) -> some View {", "    private var emptyState")
        for part in ("BotAvatarView(identity: bot.id",
                     "Text(bot.name)",
                     "UnreadBadge(count: bot.count",
                     "if let preview = bot.preview"):
            self.assertIn(part, row)
        self.assertIn("color: bot.face", row)

    def test_the_empty_state_says_the_house_words(self) -> None:
        self.assertIn('Text("Nothing waiting.")', SHARED)


class ThePhoneBellSitsLeftOfSettings(unittest.TestCase):
    def setUp(self) -> None:
        self.group = block(IOS_LIST, "ToolbarItemGroup(placement: .topBarTrailing)", "// A plus, because")

    def test_the_bell_is_between_search_and_settings(self) -> None:
        bell = self.group.index('Image(systemName: "bell")')
        gear = self.group.index('Image(systemName: "gearshape")')
        self.assertLess(bell, gear, "the bell must be immediately left of Settings")
        # Nothing but the bell's own glyph sits between the two buttons: one image, no extra verb.
        between = self.group[bell:gear]
        self.assertEqual(between.count("Image(systemName:"), 1,
                         "a third control slipped in between the bell and Settings")

    def test_the_bell_wears_a_dot_only_when_something_waits(self) -> None:
        self.assertIn(".waitingDot(!waitingBots.isEmpty", self.group)
        self.assertIn('accessibilityIdentifier("botList.notifications")', self.group)

    def test_the_sheet_is_a_house_sheet(self) -> None:
        sheet = block(IOS_LIST, ".sheet(isPresented: $showWaiting)", ".sheet(isPresented: $showStartGroupChat)")
        self.assertIn(".hermesSheetChrome()", sheet)


class TheMacBellIsRightAlignedAndHasAPopover(unittest.TestCase):
    def setUp(self) -> None:
        self.bell = block(MAC, "private var notificationsButton: some View {", "    // MARK: Floor")

    def test_the_bell_is_a_popover_anchored_to_itself(self) -> None:
        self.assertIn(".popover(isPresented: $showsNotifications, arrowEdge: .top)", self.bell)
        self.assertIn("WaitingBotsInbox(bots: waitingBots)", self.bell)

    def test_the_dot_is_the_same_statement_here_as_on_the_phone(self) -> None:
        self.assertIn(".waitingDot(!waitingBots.isEmpty)", self.bell)
        self.assertIn("public struct WaitingDot: ViewModifier", SHARED)

    def test_the_shortcut_does_not_collide(self) -> None:
        # ⇧⌘N: no other binding in the window takes it. ⌘F (find in conversation), ⌘K (palette),
        # ⇧⌘P (pair), ⇧⌘R (reconnect), ⌘S (panel), ⌘E (bot panel) all stay where they were.
        self.assertIn('.keyboardShortcut("n", modifiers: [.command, .shift])', self.bell)
        app = (ROOT / "Apps" / "HermesMac" / "HermesMacApp.swift").read_text(encoding="utf-8")
        store_src = (ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceStore.swift").read_text(
            encoding="utf-8")
        self.assertNotIn('keyboardShortcut("n"', app)
        self.assertNotIn('"⇧⌘N"', store_src)


if __name__ == "__main__":
    unittest.main()
