"""The Rakazo shell's numbers, pinned.

The restyle is a port of a specification taken from Rakazo's own source (`packages/ui-tokens`,
`apps/web/src/pages/shell/*`, `apps/web/src/lib/bots-sidebar-pref.ts`). A port drifts one number at
a time — a 16 that becomes a 12, a 38 pt avatar that shrinks back to 26 — and nothing catches it
because every individual value still looks reasonable. These cases fail when a ported value moves,
so a later change has to say out loud that it is leaving the spec.
"""
from __future__ import annotations

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
TOKENS = (ROOT / "Sources/OpenBotUI/Tokens.swift").read_text()
THEME = (ROOT / "Sources/OpenBotUI/Theme.swift").read_text()
WINDOW = (ROOT / "Sources/HermesAppKit/WindowLayout.swift").read_text()
ROSTER = (ROOT / "Apps/HermesMac/Sidebar/SidebarBotList.swift").read_text()
HEADER = (ROOT / "Apps/HermesMac/Conversation/ConversationHeader.swift").read_text()


def value(source: str, name: str) -> str:
    match = re.search(rf"static (?:let|var) {name}\s*:\s*CGFloat\s*=\s*([0-9.]+)", source)
    if match is None:
        raise AssertionError(f"{name} is not declared")
    return match.group(1)


class RakazoTokensTests(unittest.TestCase):
    def test_the_palette_is_the_one_from_rakazo(self) -> None:
        self.assertIn('id: "rakazo", name: "Rakazo"', THEME)
        self.assertIn("canvas: 0x0A0A0A", THEME)          # webDarkTokens.background
        self.assertIn("surface: 0x232323", THEME)         # webDarkTokens.muted
        self.assertIn("accent: 0x4D9BFF", THEME)          # unread / statusWorking
        self.assertIn("success: 0x00BA69", THEME)         # webDarkTokens.success
        self.assertIn("danger: 0xFF6463", THEME)          # webDarkTokens.destructive
        self.assertIn("borderAlpha: 0.10", THEME)         # border #F5F5F51A

    def test_rakazo_is_the_house_theme_and_openbot_is_the_way_back(self) -> None:
        self.assertIn('public static let defaultID = "rakazo"', THEME)
        self.assertIn("all: [ThemePalette] = [\n        rakazo,\n        openbot,", THEME)

    def test_a_previous_install_moves_once_and_only_from_the_old_default(self) -> None:
        # Wearing "openbot" because it was the default is not a choice; picking it is.
        self.assertIn('stored == nil || stored == "openbot"', THEME)
        self.assertIn("hermey.theme.migrated.rakazo", THEME)


class RakazoGeometryTests(unittest.TestCase):
    def test_the_radius_chain(self) -> None:
        self.assertEqual(value(TOKENS, "radiusCard"), "16")      # rows and cards
        self.assertEqual(value(TOKENS, "radiusBubble"), "20")    # bubbles, large dialogs
        self.assertEqual(value(TOKENS, "radiusComposer"), "26")  # the composer bar
        self.assertEqual(value(TOKENS, "radiusPicker"), "14")    # mention popover
        self.assertEqual(value(TOKENS, "radiusControl"), "10")
        self.assertEqual(value(TOKENS, "radiusSmall"), "8")

    def test_the_sidebar_is_316_between_240_and_480_and_72_when_mini(self) -> None:
        self.assertEqual(value(TOKENS, "sidebarDefault"), "316")
        self.assertEqual(value(TOKENS, "sidebarMin"), "240")
        self.assertEqual(value(TOKENS, "sidebarMax"), "480")
        self.assertEqual(value(TOKENS, "sidebarCompact"), "72")
        self.assertEqual(value(TOKENS, "sidebarCollapseBelow"), "160")
        # The window's own floor is the same 240, or a drag could go below the panel's minimum.
        self.assertEqual(value(WINDOW, "sidebarFloor"), "240")
        self.assertEqual(value(WINDOW, "sidebarMax"), "480")

    def test_the_reading_column_and_the_panel(self) -> None:
        self.assertEqual(value(TOKENS, "conversationMeasure"), "960")
        self.assertEqual(value(TOKENS, "readingInset"), "28")
        self.assertEqual(value(TOKENS, "composerInset"), "24")
        self.assertEqual(value(TOKENS, "contextPanel"), "384")
        self.assertEqual(value(WINDOW, "computerIdeal"), "384")

    def test_the_roster_row(self) -> None:
        self.assertEqual(value(TOKENS, "rosterRow"), "58")
        self.assertEqual(value(TOKENS, "rosterAvatar"), "38")
        self.assertEqual(value(TOKENS, "rosterRowPadding"), "10")
        self.assertEqual(value(TOKENS, "rosterRowGap"), "12")
        self.assertEqual(value(TOKENS, "rosterRowSpacing"), "2")
        self.assertEqual(value(TOKENS, "rosterName"), "13")
        self.assertEqual(value(TOKENS, "rosterMeta"), "12")

    def test_the_chat_header_floats_and_the_transcript_reserves_room(self) -> None:
        self.assertEqual(value(TOKENS, "chatHeader"), "62")
        self.assertEqual(value(TOKENS, "chatHeaderAvatar"), "28")
        self.assertEqual(value(TOKENS, "chatHeaderPill"), "40")
        self.assertEqual(value(TOKENS, "chatHeaderTitle"), "15")
        self.assertEqual(value(TOKENS, "transcriptTopInset"), "84")
        # No bar: a header with a fill or a hairline is the thing the spec replaced.
        self.assertNotIn(".background(Tokens.canvas)\n        // Owned by the store", HEADER)
        # The pill is the control, and it is opaque: the transcript scrolls behind it, so a
        # translucent fill let the text underneath show through the name.
        self.assertIn("Capsule().fill(Tokens.surface)", HEADER)
        self.assertNotIn("Tokens.surface.opacity(store.isBotPanelPresented", HEADER)
        self.assertIn("botPanelButton", HEADER, "the pill is the way into the bot's panel")

    def test_the_transcript_and_the_composer(self) -> None:
        self.assertEqual(value(TOKENS, "transcriptRowSpacing"), "8")
        self.assertEqual(value(TOKENS, "bubblePaddingH"), "18")
        self.assertEqual(value(TOKENS, "bubblePaddingV"), "12")
        self.assertEqual(value(TOKENS, "bubbleMaxWidth"), "624")
        self.assertEqual(value(TOKENS, "userBubbleFraction"), "0.84")
        self.assertEqual(value(TOKENS, "botBubbleFraction"), "0.88")
        self.assertEqual(value(TOKENS, "composerHeight"), "52")
        self.assertEqual(value(TOKENS, "composerButton"), "32")
        self.assertEqual(value(TOKENS, "composerTextMaxHeight"), "100")

    def test_the_row_is_built_from_the_tokens_not_from_literals(self) -> None:
        self.assertIn("size: Geometry.rosterAvatar", ROSTER)
        self.assertIn(".frame(height: Geometry.rosterRow)", ROSTER)
        self.assertIn("spacing: Geometry.rosterRowGap", ROSTER)
        self.assertIn("TypeScale.font(Tokens.rosterName", ROSTER)
        self.assertIn("TypeScale.font(Tokens.rosterMeta", ROSTER)


IOS_ROSTER = (ROOT / "Apps/HermesMobile/Views/BotListScreen.swift").read_text()
IOS_TRANSCRIPT = (ROOT / "Apps/HermesMobile/Views/MobileTranscript.swift").read_text()
IOS_CHAT = (ROOT / "Apps/HermesMobile/Views/ConversationScreen.swift").read_text()
ROOM_ROW = (ROOT / "Sources/OpenBotUI/GroupChatViews.swift").read_text()


class RakazoIOSShellTests(unittest.TestCase):
    """The phone's own anatomy, not just the shared tokens."""

    def test_the_roster_row_is_the_same_row_as_the_macs(self) -> None:
        self.assertIn("size: Geometry.rosterAvatar", IOS_ROSTER)
        self.assertIn("spacing: Geometry.rosterRowGap", IOS_ROSTER)
        self.assertIn(".frame(minHeight: Geometry.rosterRow)", IOS_ROSTER)
        self.assertIn(".padding(.vertical, Geometry.rosterRowPadding)", IOS_ROSTER)
        self.assertIn("TypeScale.font(Tokens.rosterMeta", IOS_ROSTER)
        # Two lines of text — the chevron was what made it three — but the two unread indicators
        # are back on the row after the restyle dropped them: Mohammad asked for the count on the
        # face and the beacon at the edge twice, and a single static dot lost the number
        # (reported 2026-11-14). They are overlays, so the row is still two lines.
        self.assertNotIn('Image(systemName: "chevron.right")', IOS_ROSTER)
        self.assertIn("UnreadBadge(count: model.unreadCount(bot.id)", IOS_ROSTER)
        self.assertIn("UnreadBeacon(diameter: 8)", IOS_ROSTER)

    def test_a_group_chat_is_a_row_of_the_same_shape(self) -> None:
        self.assertIn("spacing: Geometry.rosterRowGap", ROOM_ROW)
        self.assertIn("TypeScale.font(Tokens.rosterName", ROOM_ROW)
        self.assertIn("frame(width: 8, height: 8)", ROOM_ROW)
        self.assertNotIn("UnreadBadge(count: unread", ROOM_ROW)

    def test_the_phone_bubble_matches_the_macs(self) -> None:
        self.assertIn(".padding(.horizontal, Geometry.bubblePaddingH)", IOS_TRANSCRIPT)
        self.assertIn(".padding(.vertical, Geometry.bubblePaddingV)", IOS_TRANSCRIPT)
        self.assertIn("cornerRadius: Tokens.radiusBubble", IOS_TRANSCRIPT)

    def test_the_phone_header_is_one_line_at_the_same_weight(self) -> None:
        pill = IOS_CHAT.split("private var pill: some View", 1)[1]
        self.assertIn("TypeScale.font(Tokens.chatHeaderTitle, weight: .semibold)", pill)
        # The description line moved to the roster; only the two actionable chips survive.
        self.assertNotIn("if let described = bot.description", IOS_CHAT)
        self.assertIn("if unreadElsewhere > 0 {", IOS_CHAT)
        self.assertNotIn("SectionCaption", IOS_CHAT)


if __name__ == "__main__":
    unittest.main()
