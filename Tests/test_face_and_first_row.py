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
        # Room for half the composer at the foot of the transcript, so the last message's tail runs
        # under the capsule and the glass has something to refract.
        self.assertIn("frame(height: max(1, composerHeight + 1))", self.CHAT)
        # Nothing may follow the bottom id, or scrollTo stops short of the end.
        self.assertIn(".id(ConversationScreen.bottomID)\n                // `maxY`", self.CHAT)

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
        self.assertIn(".restoresSwipeBack(enabled: !showDrawer)", self.CHAT)
        # Owning the gesture, not reviving the system one: hiding the bar disables that recogniser
        # and a delegate does not bring it back — the repo's own notes say so.
        self.assertIn("UIScreenEdgePanGestureRecognizer", self.ENabler)
        self.assertIn("pan.edges = .left", self.ENabler)
        self.assertIn("let target = navigation.view", self.ENabler)
        self.assertIn("popViewController(animated: true)", self.ENabler)
        # One pop recogniser, or a single swipe pops twice.
        self.assertIn("interactivePopGestureRecognizer?.isEnabled = false", self.ENabler)
        # The transcript keeps its pan: touches are not cancelled, and a vertical drag from the
        # margin scrolls rather than going back.
        self.assertIn("cancelsTouchesInView = false", self.ENabler)
        self.assertIn("abs(translation.x) > abs(translation.y)", self.ENabler)

    def test_the_composer_floats_so_it_has_no_border(self) -> None:
        self.assertIn("floats: true", self.CHAT)

    def test_the_chrome_is_a_thumbs_target(self) -> None:
        self.assertIn(".frame(height: 52)", self.CHAT)          # the pill
        self.assertIn("size: 32,", self.CHAT)                   # its portrait
        self.assertIn(".frame(width: 44, height: 44)", self.CHAT)  # the back pill

    def test_the_drawer_names_the_bot_once(self) -> None:
        # The pill is not beside it any more — the page covers the chat — so the page says whose
        # page it is, with one Edit verb, and never the description.
        self.assertIn("Text(title)", self.DRAWER)
        self.assertNotIn("if let subtitle", self.DRAWER)
        self.assertIn('Text("Edit")', self.DRAWER)


class TheChromeIsGlass(unittest.TestCase):
    """Liquid Glass where the OS has it, the theme's surface where it does not — one shape either way."""

    CHAT = source("Apps", "HermesMobile", "Views", "ConversationScreen.swift")
    GLASS = source("Sources", "OpenBotUI", "LiquidGlass.swift")
    COMPOSER = source("Sources", "OpenBotUI", "Composer.swift")

    def test_the_helper_is_the_platform_s_glass(self) -> None:
        # The hand-built wash-and-rim recipe is gone. It existed because an opaque canvas band sat
        # behind the composer and the real material had nothing to refract; that band is removed, so
        # the platform's glass is both the right answer and the one that reads as native.
        self.assertIn("glassEffect(interactive ? .regular.interactive() : .regular, in: shape)",
                      self.GLASS)
        self.assertIn("#available(iOS 26.0, macOS 26.0, *)", self.GLASS)
        self.assertNotIn("GlassSurface", self.GLASS, "no hand-painted glass")
        # The fallback is a material, not a flat theme fill.
        self.assertIn("shape.fill(.ultraThinMaterial)", self.GLASS)
        self.assertNotIn("Tokens.surface", self.GLASS)

    def test_every_floating_pill_uses_it(self) -> None:
        self.assertIn(".hermeyGlass(Circle(), interactive: true)", self.CHAT)   # back pill
        self.assertIn(".hermeyGlass(Capsule(), interactive: true)", self.CHAT)  # bot pill
        # Four: the two above, the way to the newest message, and the search field — which used to
        # be drawn bare onto the transcript and read as part of the conversation.
        self.assertEqual(self.CHAT.count("hermeyGlass"), 4)

    def test_the_floating_shape_has_one_radius(self) -> None:
        # The mismatched shapes left the canvas showing in every corner: a pill inside a rounded
        # rectangle. One shape now, and its radius is capped so eight lines is not a lozenge with
        # semicircular ends.
        self.assertIn("static var floatingShape: RoundedRectangle", self.COMPOSER)
        self.assertIn("static let floatingRadius: CGFloat = 26", self.COMPOSER)
        # One shape for the fill, one for nothing else: no stroke at all on the floating field.
        self.assertIn("Self.floatingShape", self.COMPOSER)
        self.assertNotIn("GlassSurface.rim", self.COMPOSER)

    def test_the_composer_is_glass_only_when_it_floats(self) -> None:
        # The composer wears the same glass as every other floating shape — the platform's, in its
        # own radius — with nothing painted over it.
        self.assertIn("Color.clear.hermeyGlass(Self.floatingShape, interactive: true)", self.COMPOSER)
        self.assertNotIn(".fill(Tokens.surface.opacity(0.97))", self.COMPOSER)
        self.assertNotIn("GlassSurface", self.COMPOSER, "no wash or rim drawn on the glass")
        # No drop shadow and no uniform border on it: the rim is the edge. A bar keeps its rule.
        self.assertNotIn("radius: 16, y: 6", self.COMPOSER)
        self.assertIn("if !floats {", self.COMPOSER)
        # A bar keeps the rounded rect and its control fill.
        self.assertIn(".fill(Tokens.control)", self.COMPOSER)

    def test_the_way_back_to_the_newest_message_clears_the_composer(self) -> None:
        control = self.CHAT.split("private func scrollToBottomControl(", 1)[1]
        self.assertIn(".padding(.bottom, composerHeight + 12)", control)


class NoTabBarAndTwoFades(unittest.TestCase):
    """The bot list is the app, and the transcript leaves the screen instead of being cut by it."""

    APP = source("Apps", "HermesMobile", "HermesMobileApp.swift")
    LIST = source("Apps", "HermesMobile", "Views", "BotListScreen.swift")
    CHAT = source("Apps", "HermesMobile", "Views", "ConversationScreen.swift")
    MENU = source("Apps", "HermesMobile", "Views", "AttachmentMenu.swift")
    PICKER = source("Apps", "HermesMobile", "Views", "AttachmentPicker.swift")

    def test_the_bottom_pill_is_gone(self) -> None:
        self.assertNotIn("TabView(selection:", self.APP)
        self.assertNotIn("tabItem", self.APP)
        # The bot list is the root, and it is the whole root.
        self.assertIn("BotsTab(model: app.model)", self.APP)

    def test_settings_still_has_a_door(self) -> None:
        self.assertIn("Button { showAppSettings = true }", self.LIST)
        self.assertIn('Label("Settings", systemImage: "gearshape")', self.LIST)
        self.assertIn("SettingsScreen(model: model)", self.LIST)

    def test_nothing_is_masked_or_faded_over_the_transcript(self) -> None:
        # Not a fade at the foot, not a fade at the top, not a gradient laid over the words. Every
        # one of those is a shade above the compose box on a near-black canvas, and the glass has to
        # have the transcript under it — at full strength — to look like anything.
        self.assertNotIn(".mask(", self.CHAT)
        self.assertNotIn("LinearGradient", self.CHAT)

    def test_nothing_opaque_sits_under_the_glass_composer(self) -> None:
        # The slab was the black box: an opaque gradient under a glass capsule.
        self.assertNotIn("Tokens.canvas, Tokens.canvas],\n                               startPoint: .top, endPoint: .center",
                         self.CHAT)

    def test_the_attach_menu_is_a_panel_of_three_rows(self) -> None:
        self.assertIn("static let rowHeight: CGFloat = 56", self.MENU)
        self.assertIn("static let width: CGFloat = 252", self.MENU)
        # No rules between rows: the spacing is the separator.
        self.assertEqual(self.MENU.count("Hairline("), 0)
        # File first, as the reference has it.
        self.assertIn("static let menuOrder: [AttachmentSource] = [.files, .camera, .photos]",
                      self.PICKER)
