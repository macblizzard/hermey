"""The face is a blob now, and the first row is on the traffic lights' line.

Both are appearance rules that a compiler cannot see and a screenshot review keeps having to
re-check, so they are pinned here: the silhouette is filled and carries exactly two eyes, the
sixteen shapes exist on both sides of the wire, and the chrome's top line is arithmetic that adds up.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def source(*parts: str) -> str:
    return (ROOT.joinpath(*parts)).read_text()


GALLERY = source("Sources", "OpenBotUI", "BotIconGallery.swift")
SILHOUETTE = source("Sources", "OpenBotUI", "BotSilhouette.swift")
HEADER = source("Apps", "HermesMac", "Conversation", "ConversationHeader.swift")
SIDEBAR = source("Apps", "HermesMac", "Sidebar", "BotSidebarView.swift")
ROOTVIEW = source("Apps", "HermesMac", "Workspace", "WorkspaceRoot.swift")
PANEL = source("Apps", "HermesMac", "Workspace", "MacBotPanel.swift")
BRIDGE = source("Bridge", "hermes_bridge", "bot_icons.py")


class TheFaceIsASilhouette(unittest.TestCase):
    def test_the_portrait_draws_a_filled_shape_and_two_eyes(self) -> None:
        portrait = GALLERY.split("public struct BotIconPortrait", 1)[1]
        body = portrait.split("public var body: some View", 1)[1]
        self.assertIn("BotSilhouette(icon)", body)
        self.assertIn(".fill(tint)", body)
        self.assertIn("BotEyes(size: size, tilt: icon.eyeTilt)", body)

    def test_the_ring_and_the_line_art_are_gone(self) -> None:
        # A ring around a ring around a body was the old drawing; the mass is the whole mark now.
        portrait = GALLERY.split("public struct BotIconPortrait", 1)[1]
        body = portrait.split("public var body: some View", 1)[1].split("/// Shared working", 1)[0]
        self.assertNotIn("Circle().strokeBorder", body)
        self.assertNotIn("newPortrait", GALLERY)

    def test_the_state_badge_still_sits_on_the_face(self) -> None:
        portrait = GALLERY.split("public struct BotIconPortrait", 1)[1]
        body = portrait.split("public var body: some View", 1)[1]
        for badge in ("NeedsYouFlash", "BotWorkingSparks", "CompactingZip"):
            self.assertIn(badge, body, f"{badge} no longer drawn on the portrait")

    def test_sixteen_shapes_and_four_new_silhouettes_draw_paths(self) -> None:
        cases = re.search(r"public enum BotIcon:.*?\n\}", GALLERY, re.S).group(0)
        self.assertIn("lump, mushroom, blob, capsule, droplet, scallop", cases)
        for kind in ("case .mushroom", "case .capsule", "case .scallop", "case .droplet"):
            self.assertIn(kind, SILHOUETTE, f"{kind} has no path")

    def test_the_host_accepts_every_shape_the_apps_draw(self) -> None:
        for kind in ("lump", "mushroom", "blob", "capsule", "droplet", "scallop"):
            self.assertIn(f"'{kind}'", BRIDGE, f"the host would reject {kind}")
        # And the ten that were there before are still accepted, because stored faces use them.
        for kind in ("ember", "nova", "cobalt", "orbit", "moss", "dusk", "beacon", "pixel",
                     "rover", "prism"):
            self.assertIn(f"'{kind}'", BRIDGE, f"the host dropped {kind}")

    def test_the_picker_holds_eight_per_row(self) -> None:
        picker = GALLERY.split("public struct BotFacePicker", 1)[1]
        self.assertIn("count: 8", picker)


class TheFirstRowIsOnTheLightsLine(unittest.TestCase):
    def test_the_strip_and_the_row_add_up_to_the_pill_centre(self) -> None:
        # 4 pt strip + a 34 pt row = a 21 pt centre; the pill is 40 pt in a 42 pt box = 21 pt.
        strip = re.search(r"static let titlebarStrip: CGFloat = (\d+)", ROOTVIEW)
        self.assertIsNotNone(strip)
        self.assertEqual(int(strip.group(1)), 4)
        self.assertIn(".frame(height: WorkspaceShell.titlebarStrip + 34)", SIDEBAR)
        self.assertIn(".frame(width: width, height: Geometry.chatHeaderPill + 2)", HEADER)

    def test_the_drag_band_is_its_own_and_the_window_moves_by_its_background(self) -> None:
        self.assertIn("static let dragStrip: CGFloat = 6", ROOTVIEW)
        self.assertIn(".frame(height: WorkspaceShell.dragStrip)", ROOTVIEW)
        self.assertIn("isMovableByWindowBackground = true",
                      source("Apps", "HermesMac", "Support", "TitlebarDragArea.swift"))


class ThePanelStaysAboutTheBot(unittest.TestCase):
    def test_no_palette_no_settings_no_shortcut_hints(self) -> None:
        self.assertNotIn('row("Command palette"', PANEL)
        self.assertNotIn('row("Settings"', PANEL)
        self.assertNotIn('detail: "⌘', PANEL)

    def test_the_pill_carries_no_dots(self) -> None:
        pill = HEADER.split("private func pill(width: CGFloat)", 1)[1]
        self.assertNotIn('systemName: "ellipsis"', pill)


if __name__ == "__main__":
    unittest.main()


class TheLaunchIsAConversation(unittest.TestCase):
    """A paired host is dialled at launch, and the last conversation is what comes back."""

    STORE = source("Apps", "HermesMac", "Workspace", "WorkspaceStore.swift")
    APP = source("Apps", "HermesMac", "HermesMacApp.swift")

    def test_the_window_dials_a_paired_host_without_being_asked(self) -> None:
        self.assertIn("await store.connectOnLaunchIfPaired()", self.APP)
        self.assertIn("func connectOnLaunchIfPaired() async", self.STORE)
        self.assertIn("guard isPaired, !connectAttempted, !didDisconnectThisRun else { return }",
                      self.STORE)

    def test_an_explicit_disconnect_survives_the_next_launch(self) -> None:
        # The one thing that stops the dial is the user's own Disconnect.
        self.assertIn("didDisconnectThisRun = true", self.STORE)
        self.assertIn("didDisconnectThisRun = false", self.STORE)

    def test_the_last_bot_comes_back(self) -> None:
        self.assertIn('"hermey.lastBot.', self.STORE)
        self.assertIn("func restoreLastBot()", self.STORE)
        self.assertIn("rememberOpenBot()", self.STORE)
        # Restored before the "nothing on screen yet" open, so the two do not both open a bot.
        restore = self.STORE.index("restoreLastBot()")
        needed = self.STORE.index("await openConversationIfNeeded()")
        self.assertLess(restore, needed)

    def test_connecting_is_not_not_connected(self) -> None:
        sidebar = source("Apps", "HermesMac", "Sidebar", "BotSidebarView.swift")
        self.assertIn('model.connection == .connecting ? "CONNECTING" : "NOT CONNECTED"', sidebar)


class ThePanelIsOnlyVerbs(unittest.TestCase):
    PANEL = source("Apps", "HermesMac", "Workspace", "MacBotPanel.swift")

    def test_no_header_the_pill_already_says(self) -> None:
        self.assertNotIn("BotIconPortrait", self.PANEL)
        self.assertNotIn("bot?.displayName ?? model.hostName", self.PANEL)

    def test_no_connection_row(self) -> None:
        self.assertNotIn("connectionRow", self.PANEL)
        self.assertNotIn('"Disconnect"', self.PANEL)
        self.assertNotIn('"Pair host…"', self.PANEL)

    def test_the_close_button_stays(self) -> None:
        self.assertIn('OpenBotIconButton("xmark", label: "Close the bot panel"', self.PANEL)


class ThePhoneFloatsLikeTheWindow(unittest.TestCase):
    """The phone's chat is the desktop's arrangement: chrome over the transcript, not around it."""

    CHAT = source("Apps", "HermesMobile", "Views", "ConversationScreen.swift")
    MAC_SCROLL = source("Apps", "HermesMac", "Conversation", "TranscriptScroll.swift")

    def test_no_navigation_bar_and_no_three_dots(self) -> None:
        self.assertIn(".toolbar(.hidden, for: .navigationBar)", self.CHAT)
        self.assertNotIn("ToolbarItem(placement: .topBarTrailing)", self.CHAT)
        # The ellipse belongs to the bot list now, not to the conversation.
        self.assertNotIn('systemName: "ellipsis"', self.CHAT)

    def test_the_pill_is_the_door(self) -> None:
        pill = self.CHAT.split("private var pill: some View", 1)[1]
        self.assertIn("showDrawer.toggle()", pill)
        self.assertIn('accessibilityIdentifier("chatDrawerButton")', pill)

    def test_the_transcript_runs_behind_both_ends(self) -> None:
        self.assertIn(".overlay(alignment: .top) { floatingTop }", self.CHAT)
        self.assertIn(".overlay(alignment: .bottom) { floatingComposer }", self.CHAT)
        # No safe-area insets: those are what clipped the transcript short of the chrome.
        self.assertNotIn(".safeAreaInset(edge: .top", self.CHAT)
        self.assertNotIn(".safeAreaInset(edge: .bottom", self.CHAT)
        # And room for the composer's real height at the foot of the transcript.
        self.assertIn("frame(height: composerHeight + 16)", self.CHAT)

    def test_the_composer_no_longer_draws_a_rule(self) -> None:
        composer = self.CHAT.split("private var composerArea: some View", 1)[1]
        head = composer.split("if let reply = model.replyTarget", 1)[0]
        self.assertNotIn("Hairline(", head)

    def test_the_mac_stops_following_new_messages(self) -> None:
        # Off while the blank-out is chased: a scroll request per token is the shape of the bug.
        self.assertIn("static let followsNewMessages = false", self.MAC_SCROLL)
        follow = self.MAC_SCROLL.split("private func follow(", 1)[1]
        self.assertIn("guard Self.followsNewMessages else { return }", follow)


class ThePhoneKeepsItsWayBack(unittest.TestCase):
    """Hiding the bar must not take the swipe with it, and the chrome is a thumb's target."""

    CHAT = source("Apps", "HermesMobile", "Views", "ConversationScreen.swift")
    DRAWER = source("Apps", "HermesMobile", "Views", "ConversationDrawer.swift")
    ENabler = source("Apps", "HermesMobile", "Views", "PopGestureEnabler.swift")

    def test_the_swipe_back_is_restored(self) -> None:
        # UIKit refuses the interactive pop while the bar is hidden; the enabler uncorks it.
        self.assertIn(".restoresSwipeBack()", self.CHAT)
        self.assertIn("interactivePopGestureRecognizer", self.ENabler)
        self.assertIn("gesture.delegate = nil", self.ENabler)
        # Not on the root screen: a swipe there would pop nothing and freeze the recogniser.
        self.assertIn("navigation.viewControllers.count > 1", self.ENabler)

    def test_the_composer_floats_so_it_has_no_border(self) -> None:
        self.assertIn("floats: true", self.CHAT)

    def test_the_chrome_is_a_thumbs_target(self) -> None:
        self.assertIn(".frame(height: 42)", self.CHAT)          # the pill
        self.assertIn("size: 28,", self.CHAT)                   # its portrait
        self.assertIn(".frame(width: 40, height: 40)", self.CHAT)  # the back pill

    def test_the_drawer_does_not_repeat_the_pill(self) -> None:
        self.assertNotIn("Text(title)", self.DRAWER)
        self.assertNotIn("if let subtitle", self.DRAWER)
