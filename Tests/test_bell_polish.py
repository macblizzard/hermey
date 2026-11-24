"""The bell's three polish rules, pinned where a compiler cannot see them.

* The Mac popover's rows draw a hover fill and **no** system focus ring — but a focused row is
  still a button, so Space/Return keeps working;
* the phone's sheet is exactly as tall as the rows it holds, and a row is built like the bot
  list's: the count on the face's corner, name and stamp on one line, preview under it;
* every top and bottom bar icon is 1.25× its shipped glyph **and** frame.

The SwiftUI sources are read as text: these are arrangements and numbers, not behaviours a test
can call from Linux.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

MAC = (ROOT / "Apps" / "HermesMac" / "Sidebar" / "BotSidebarView.swift").read_text(encoding="utf-8")
IOS = (ROOT / "Apps" / "HermesMobile" / "Views" / "BotListScreen.swift").read_text(encoding="utf-8")
SHARED = (ROOT / "Sources" / "HermeyUI" / "WaitingBotsInbox.swift").read_text(encoding="utf-8")
CONTROLS = (ROOT / "Sources" / "HermeyUI" / "Controls.swift").read_text(encoding="utf-8")


def block(source: str, opening: str, closing: str) -> str:
    """The text between one declaration and the next marker, exclusive."""
    assert opening in source, f"{opening!r} is gone"
    tail = source.split(opening, 1)[1]
    assert closing in tail, f"{closing!r} did not follow {opening!r}"
    return tail.split(closing, 1)[0]


class PopoverRowsWearHoverNotAFocusRing(unittest.TestCase):
    """A ring on a list row reads as a selection nobody made."""

    def setUp(self) -> None:
        self.row = block(SHARED, "private func row(_ bot: WaitingBot) -> some View {",
                         "    private var emptyState")
        self.popover = block(MAC, "private var notificationsButton: some View {", "    // MARK: Floor")

    def test_the_row_suppresses_the_ring(self) -> None:
        # Through the app's one spelling of it — `hermeyFocusQuiet()` — not the system modifier by
        # hand; `test_focus_rings` holds that it is the only spelling in the tree.
        self.assertIn(".hermeyFocusQuiet()", self.row)

    def test_the_row_is_still_an_activatable_button(self) -> None:
        # The ring is gone, the tab stop is not: `focusable(false)` would have made the row
        # unreachable from the keyboard, which is not the fix the owner asked for.
        self.assertIn("Button { onOpen(bot.id) }", self.row)
        self.assertNotIn(".focusable(false)", self.row)
        self.assertIn(".buttonStyle(.plain)", self.row)

    def test_the_row_reads_as_hover_only(self) -> None:
        self.assertIn(".hoverFill(rest: .clear, hover: Tokens.controlHover", self.row)
        self.assertNotIn("PressableButtonStyle()", self.row)

    def test_the_popover_chrome_does_not_ring_either(self) -> None:
        inbox = self.popover.split("WaitingBotsInbox(bots: waitingBots,", 1)[1]
        self.assertIn(".hermeyFocusQuiet()", inbox)


class ThePhoneSheetIsSizedToItsRows(unittest.TestCase):
    """`.medium` for one row was a page of empty space above `WAITING`."""

    def setUp(self) -> None:
        self.sheet = block(IOS, ".sheet(isPresented: $showWaiting)", ".sheet(isPresented: $showStartGroupChat)")

    def test_the_detent_follows_the_row_count(self) -> None:
        # One `sheetHeight` call, and the host-update row declared to it: a sheet sized for the
        # bots alone would clip the one row above them.
        self.assertIn(".presentationDetents([.height(WaitingBotsInbox.sheetHeight(for: waitingBots.count,",
                      self.sheet)
        self.assertIn("hostUpdate: model.hostUpdate != nil", self.sheet)
        self.assertNotIn(".medium", self.sheet)
        self.assertNotIn(".large", self.sheet)

    def test_the_height_is_computed_from_the_shared_row_pitch(self) -> None:
        self.assertIn("public static func sheetHeight(for rowCount: Int, hostUpdate: Bool = false) -> CGFloat",
                      SHARED)
        height = block(SHARED,
                       "public static func sheetHeight(for rowCount: Int, hostUpdate: Bool = false) -> CGFloat {",
                       "    private var listHeight")
        self.assertIn("CGFloat(max(rowCount, 1)) * Self.rowPitch", height,
                      "one row must be one row tall, and zero rows must not be negative")
        self.assertIn("Self.listCap", height, "a long list caps and scrolls instead of growing forever")
        # The stack is pinned to the top of the sheet, so the header sits under the grab handle.
        self.assertIn(".frame(maxHeight: .infinity, alignment: .topLeading)", SHARED)
        self.assertIn("return 8", block(SHARED, "private static var headerTop: CGFloat {",
                                       "    /// One row's pitch"))


class ThePhoneRowIsTheListsRow(unittest.TestCase):
    """Avatar + badge, name + stamp, preview — one leading edge."""

    def setUp(self) -> None:
        self.row = block(SHARED, "private func row(_ bot: WaitingBot) -> some View {",
                         "    private var emptyState")

    def test_the_badge_rides_the_avatars_bottom_right_corner(self) -> None:
        avatar = self.row.index("BotAvatarView(identity: bot.id")
        overlay = self.row.index(".overlay(alignment: .bottomTrailing)", avatar)
        badge = self.row.index("UnreadBadge(count: bot.count", overlay)
        nudge = self.row.index(".offset(x: Self.badgeNudge, y: Self.badgeNudge - 1)", badge)
        self.assertLess(avatar, overlay)
        self.assertLess(overlay, badge)
        self.assertLess(badge, nudge)
        # Not at the row's trailing edge, which is where it floated detached.
        self.assertLess(badge, self.row.index("Spacer(minLength: 0)"))

    def test_the_phone_uses_the_lists_face_and_badge_sizes(self) -> None:
        avatar = block(SHARED, "private static var avatarSize: CGFloat {", "    private static var badgeSize")
        badge = block(SHARED, "private static var badgeSize: CGFloat {", "    private static var badgeNudge")
        self.assertIn("return Geometry.rosterAvatar", avatar)
        self.assertIn("return 19", badge)

    def test_the_name_and_the_stamp_share_a_line(self) -> None:
        title = block(self.row, "VStack(alignment: .leading, spacing: 2) {", "                Spacer(minLength: 0)")
        self.assertIn("Text(bot.name)", title)
        self.assertIn("Text(RelativeTime.stamp(at))", title)
        self.assertIn("if let preview = bot.preview", title)

    def test_every_row_starts_on_the_headers_leading_edge(self) -> None:
        # Header at `inset` (8); the list is inset 4 and the row another 4 — the same 8.
        self.assertIn("private static let rowInset: CGFloat = 4", SHARED)
        self.assertIn(".padding(.horizontal, Self.rowInset)", SHARED)
        self.assertIn(".padding(.horizontal, inset)", SHARED)

    def test_the_empty_state_still_says_the_house_words(self) -> None:
        self.assertIn('Text("Nothing waiting.")', SHARED)


class EveryBarIconIsAQuarterBigger(unittest.TestCase):
    """The owner's one measurement: glyph and tap frame together, written as base × 1.25."""

    def setUp(self) -> None:
        self.header = block(MAC, "private var header: some View {", "    /// Everything waiting")
        self.floor = block(MAC, "private var bottomBar: some View {", "    // MARK: Waiting")
        self.toolbar = block(IOS, "private var toolbarContent: some ToolbarContent {", "    /// The search field")

    def test_the_scale_is_written_as_one_multiplier(self) -> None:
        self.assertIn("public static let factor: CGFloat = 1.25", CONTROLS)
        scale = block(CONTROLS, "public enum BarIconScale {", "// MARK: - Buttons")
        self.assertIn("public static func of(_ base: CGFloat) -> CGFloat { base * factor }", scale)

    def test_the_mac_bar_button_frames_and_glyphs_both_grow(self) -> None:
        icon = block(CONTROLS, "public struct HermeyIconButton", "    public var body: some View")
        self.assertIn("case .bar: return BarIconScale.of(24)", icon)
        self.assertIn("case .bar: return BarIconScale.of(11)", icon)
        # 30 pt inside a bar that is the icon plus `barInset` above and below it: the frame fits, and
        # the corner inset is the same on every side (owner: "equal distance from the border").
        self.assertIn("static let barInset: CGFloat = 10", MAC)
        self.assertIn("private static let bottomBarHeight: CGFloat = 30 + barInset * 2", MAC)
        self.assertIn(".frame(height: WorkspaceShell.titlebarStrip + 30 + Self.barInset * 2)", self.header)

    def test_the_bell_and_plus_are_the_bar_size(self) -> None:
        self.assertIn("size: .bar", MAC.split("private var notificationsButton: some View {", 1)[1])
        plus = block(MAC, "private var addMenu: some View {", "    /// The top of the list's dissolve")
        self.assertIn("BarIconScale.of(11)", plus)
        self.assertIn("BarIconScale.of(24)", plus)
        self.assertIn("BarIconScale.of(7)", plus, "the plus's filled square grew with its glyph")

    def test_settings_update_search_and_the_toggle_all_grew(self) -> None:
        self.assertIn("BarIconScale.of(TypeScale.label)", self.floor)   # gear glyph 11 × 1.25
        self.assertIn("BarIconScale.of(24)", self.floor)                # and its 24 pt frame
        update = block(self.floor, 'HermeyIconButton("arrow.down.circle"',
                       "            HermeyIconButton(\"magnifyingglass\"")
        self.assertIn("size: .bar", update)
        for control in ('HermeyIconButton("magnifyingglass"',
                        'HermeyIconButton("sidebar.left"'):
            start = self.floor.index(control)
            self.assertIn("size: .bar", self.floor[start:start + 260], control)
        self.assertEqual(self.floor.count("size: .bar"), 3)

    def test_the_phone_toolbar_kept_its_size(self) -> None:
        # The owner asked for the growth on the Mac only: the phone's header is unchanged, at the sizes
        # it shipped with, so the search button beside the capsule still matches it.
        self.assertEqual(self.toolbar.count(".frame(width: 36, height: 36)"), 4,
                         "the search, bell, gear and plus keep their 36 pt frame")
        self.assertNotIn("BarIconScale", self.toolbar, "no scaling crept into the phone's toolbar")
        self.assertEqual(self.toolbar.count(".font(.system(size: 16,"), 1)
        self.assertEqual(self.toolbar.count(".font(.system(size: 17,"), 3)

    def test_every_base_is_a_shipped_size(self) -> None:
        # Not one rounded result typed in by hand: each `of(N)` still names the size that shipped,
        # and the multiplier is the only thing that changed.
        import re
        bases = {int(n) for n in re.findall(r"BarIconScale\.of\((\d+)\)", CONTROLS + MAC)}
        self.assertEqual(bases, {7, 11, 12, 24, 34},
                         "a hand-tuned size slipped in where a base × 1.25 belongs")
        self.assertNotIn("BarIconScale.of(", IOS, "the phone does not scale: the owner asked for the Mac only")


if __name__ == "__main__":
    unittest.main()
