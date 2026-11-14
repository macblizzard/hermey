"""Escape, the computer's slot, and deleting a bot from its own settings.

Three requests from 2026-11-14, each with one rule worth keeping:

* Escape had no owner outside the palette — the panes are not modal — and the key has to stop at a
  text field, or the composer changes behaviour depending on which panel is open.
* The shared computer was a third pane with the window grown to fit it, which squeezed the
  transcript; it now takes the sidebar's slot on the leading edge.
* Deleting a bot lived only under Manage bots, a list of switches — a place you go to hide a row.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAC = ROOT / "Apps" / "HermesMac"
WORKSPACE = (MAC / "Workspace" / "WorkspaceRoot.swift").read_text(encoding="utf-8")
STORE = (MAC / "Workspace" / "WorkspaceStore.swift").read_text(encoding="utf-8")
ROOT_VIEW = (MAC / "Workspace" / "WorkspaceRoot.swift").read_text(encoding="utf-8")
CATCHER = (MAC / "Support" / "EscapeKeyCatcher.swift").read_text(encoding="utf-8")
MAC_SETTINGS = (MAC / "Views" / "MacBotSettingsSheet.swift").read_text(encoding="utf-8")
IOS_SETTINGS = (ROOT / "Apps/HermesMobile/Views/BotModelSettingsScreen.swift").read_text(encoding="utf-8")
IOS_LIST = (ROOT / "Apps/HermesMobile/Views/BotListScreen.swift").read_text(encoding="utf-8")
IOS_CHAT = (ROOT / "Apps/HermesMobile/Views/ConversationScreen.swift").read_text(encoding="utf-8")
GALLERY = (ROOT / "Sources/OpenBotUI/BotIconGallery.swift").read_text(encoding="utf-8")


class EscapeClosesTheTopmostThing(unittest.TestCase):
    def test_the_order_is_the_reverse_of_opening(self) -> None:
        body = STORE.split("func closeTopmostOnEscape()", 1)[1].split("\n    }", 1)[0]
        order = [body.index(token) for token in
                 ("isPalettePresented", "isComputerFullScreen", "isComputerPanelPresented",
                  "isBotPanelPresented", "isSidebarHidden")]
        self.assertEqual(order, sorted(order),
                         "the full-screen computer outranks a pane, which outranks the sidebar")
        self.assertIn("else { return false }", body, "nothing left to close means the key passes on")

    def test_the_shell_installs_the_catcher(self) -> None:
        self.assertIn("EscapeKeyCatcher { store.closeTopmostOnEscape() }", ROOT_VIEW)

    def test_a_field_keeps_escape_for_itself(self) -> None:
        # The field editor is an NSTextView and is the first responder for every text field in the
        # app: without this guard, Escape would close a panel instead of clearing a search.
        self.assertIn("key.firstResponder is NSTextView", CATCHER)
        self.assertIn("event.keyCode == 53", CATCHER)

    def test_only_its_own_window_answers(self) -> None:
        # With Settings or a sheet in front, the shell behind must not take the key: that is
        # exactly the report — Escape in Settings closed the sidebar (2026-11-14).
        self.assertIn("key === host", CATCHER)
        self.assertIn("host = view.window", CATCHER)

    def test_the_settings_window_closes_on_escape_and_outside_click(self) -> None:
        settings = (MAC / "Views" / "MacSettingsView.swift").read_text(encoding="utf-8")
        self.assertIn("NSApp.keyWindow?.performClose(nil)", settings)
        self.assertIn("ClosesOnResignKey()", settings)
        resign = (MAC / "Support" / "ClosesOnResignKey.swift").read_text(encoding="utf-8")
        # Its own sheet keeps it: the Bots tab opens bot settings as a sheet on this window.
        self.assertIn("next.sheetParent === window", resign)

    def test_a_sheet_keeps_its_own_escape(self) -> None:
        self.assertIn("attachedSheet != nil", CATCHER)


class TheComputerTakesTheBotPanelsSlot(unittest.TestCase):
    def test_it_takes_the_trailing_slot_the_panel_had(self) -> None:
        # The computer is a row on the bot panel, so it opens where the row is: the trailing edge,
        # in the panel's own slot. Not the sidebar's, and not a fourth pane.
        trailing = ROOT_VIEW.split("if store.isComputerPanelPresented, !store.isComputerFullScreen {", 1)[1]
        self.assertIn("computerPane(fullScreen: false)", trailing.split("} else if store.isBotPanelPresented {", 1)[0])
        self.assertIn("else if store.isBotPanelPresented {", trailing)
        self.assertIn("max(WindowLayout.botPanelWidth, WindowLayout.computerMin)", trailing)

    def test_the_panel_comes_back_exactly_as_it_was(self) -> None:
        # The slot is chosen by the computer's flag; `isBotPanelPresented` is left alone, so the
        # panel is still open underneath and a close hands it straight back.
        block = ROOT_VIEW.split("if store.isComputerPanelPresented, !store.isComputerFullScreen {", 1)[1]
        block = block.split("Group {", 1)[0]
        self.assertNotIn("isBotPanelPresented =", block)

    def test_the_sidebar_is_untouched_by_it(self) -> None:
        leading = ROOT_VIEW.split("HStack(spacing: 0) {", 1)[1].split("Group {", 1)[0]
        self.assertIn("if !store.isSidebarHidden {", leading)
        self.assertNotIn("computerPane", leading)

    def test_full_screen_is_still_an_overlay(self) -> None:
        self.assertIn("if store.isComputerPanelPresented, store.isComputerFullScreen {", ROOT_VIEW)


class ABotCanBeDeletedFromItsSettings(unittest.TestCase):
    def test_the_phone_offers_it_and_confirms(self) -> None:
        self.assertIn("var deleteBot: (() async throws -> Void)? = nil", IOS_SETTINGS)
        self.assertIn("private var dangerSection", IOS_SETTINGS)
        self.assertIn("showingDelete", IOS_SETTINGS)
        self.assertIn('Button("Delete bot", role: .destructive)', IOS_SETTINGS)
        # It has to be reachable from both doors into the sheet.
        self.assertIn("deleteBot: { try await model.deleteBot(bot.id) })", IOS_LIST)
        self.assertIn("deleteBot: { try await model.deleteBot(bot.id) })", IOS_CHAT)

    def test_the_mac_offers_it_and_confirms(self) -> None:
        self.assertIn("private var dangerSection", MAC_SETTINGS)
        self.assertIn('Button("Delete bot", role: .destructive)', MAC_SETTINGS)
        self.assertIn("try await model.deleteBot(bot.id)", MAC_SETTINGS)

    def test_it_is_a_confirmed_one_way_verb(self) -> None:
        for source in (IOS_SETTINGS, MAC_SETTINGS):
            self.assertIn("This cannot be undone from the app.", source)


class AModelIsItsOwnDoor(unittest.TestCase):
    PANEL = (MAC / "Workspace" / "MacBotPanel.swift").read_text(encoding="utf-8")
    MODEL = (MAC / "Views" / "MacModelSheet.swift").read_text(encoding="utf-8")

    def test_the_panel_has_a_model_row(self) -> None:
        self.assertIn('row("Model", icon: "cpu")', self.PANEL)
        self.assertIn("store.openModel(bot)", self.PANEL)

    def test_the_catalogue_is_no_longer_in_bot_settings(self) -> None:
        # It buried the delete verb under dozens of providers in a sheet opened to change a
        # description (reported 2026-11-14).
        self.assertNotIn("MODELS", MAC_SETTINGS)
        self.assertNotIn("modelCatalog", MAC_SETTINGS)

    def test_the_sheet_keeps_the_hosts_confirmation_gate(self) -> None:
        self.assertIn("case .confirmationRequired(let message):", self.MODEL)
        self.assertIn("confirm: confirmed", self.MODEL)


class TheFacesHaveLightAndMotion(unittest.TestCase):
    """#100, tiers one and two: shading inside the silhouette, then breathing and blinking."""

    SHADING = (ROOT / "Sources/OpenBotUI/BotFaceShading.swift").read_text(encoding="utf-8")
    SILHOUETTE = (ROOT / "Sources/OpenBotUI/BotSilhouette.swift").read_text(encoding="utf-8")

    def test_the_light_stays_inside_the_shape(self) -> None:
        # Three layers, all masked by the silhouette: the outline that makes a face recognisable
        # must not change, and an outer shadow at 22 pt is a smudge.
        self.assertEqual(self.SHADING.count("mask(BotSilhouette(icon).fill(Color.black))"), 2)
        self.assertIn("BotSilhouette(icon)\n                .stroke(Color.black.opacity(0.5)", self.SHADING)
        self.assertIn("allowsHitTesting(false)", self.SHADING)

    def test_small_faces_get_less_light(self) -> None:
        self.assertIn("size >= 40 ? 0.30", self.SHADING)
        self.assertIn("size >= 28 ? 0.26 : 0.20", self.SHADING)

    def test_the_eyes_blink_and_squint(self) -> None:
        self.assertIn("public var blink: Double", self.SILHOUETTE)
        self.assertIn("public var squint: Double", self.SILHOUETTE)
        # Closed is a line, never a zero: two eyes have to survive the blink.
        self.assertIn("max(size * 0.028, closed)", self.SILHOUETTE)

    def test_motion_is_cheap_and_has_a_switch(self) -> None:
        portrait = GALLERY.split("public struct BotIconPortrait", 1)[1]
        body = portrait.split("public var body: some View", 1)[1].split("/// Shared working", 1)[0]
        # Two mechanisms, neither of them ours to break: a system-driven `phaseAnimator` cycle for
        # the breath, and the clock for the blink. A `@State` loop was tried twice and never moved
        # on the Mac — once off the main actor, once for reasons never settled.
        self.assertIn(".phaseAnimator(", body)
        # Without `trigger:`: the trigger overload plays the phases once per trigger change, which is
        # a still face with extra steps.
        self.assertIn(".phaseAnimator(motionIsOn ? [0.0, 1.0] : [0.0])", body)
        self.assertIn("TimelineView(.animation(minimumInterval: 0.1, paused:", body)
        self.assertIn("blink: blink(at: context.date)", body)
        self.assertNotIn("@State private var breathing", portrait)
        # The app's own answer comes first; the system's Reduce Motion is the fallback.
        self.assertIn("BotFaceMotion.allows(reduceMotion: reduceMotion, size: size)", portrait)
        motion = (ROOT / "Sources/OpenBotUI/BotFaceShading.swift").read_text(encoding="utf-8")
        # An explicit answer in the app wins; without one, the system decides — and the answer is
        # seeded on first launch so the switch and the faces can never disagree again.
        self.assertIn("return choice ?? !reduceMotion", motion)
        self.assertIn("public static func seedIfNeeded(reduceMotion: Bool)", motion)
        self.assertIn("BotFaceMotion.seedIfNeeded(reduceMotion: systemReduceMotion)", WORKSPACE)
        self.assertIn("guard size >= 18 else { return false }", motion)

    def test_the_mac_has_the_switch(self) -> None:
        appearance = (MAC / "Views" / "AppearanceSettingsTab.swift").read_text(encoding="utf-8")
        self.assertIn("@AppStorage(BotFaceMotion.defaultsKey) private var animateFaces", appearance)
        self.assertIn('Toggle("Animate bot faces", isOn: $animateFaces)', appearance)

    def test_a_list_does_not_blink_in_unison(self) -> None:
        self.assertIn("let seed = Double(abs(icon.title.unicodeScalars.reduce(0)", GALLERY)
        self.assertIn("let period = 3.4 + seed", GALLERY)


class TheAppIconIsOneOfTheFaces(unittest.TestCase):
    IOS_ICON = ROOT / "Apps/HermesMobile/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
    MAC_DIR = ROOT / "Apps/HermesMac/Assets.xcassets/AppIcon.appiconset"

    def test_the_phone_icon_is_1024_and_opaque(self) -> None:
        # iOS rejects an icon with an alpha channel, and the system supplies the mask itself. Read
        # from the PNG's own IHDR rather than an imaging library the test venv does not have: width,
        # height, then a colour type of 2 (truecolour) rather than 6 (with alpha).
        import struct
        data = self.IOS_ICON.read_bytes()
        self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
        width, height, _depth, colour_type = struct.unpack(">IIBB", data[16:26])
        self.assertEqual((width, height), (1024, 1024))
        self.assertEqual(colour_type, 2, "truecolour, no alpha")

    def test_every_mac_size_is_present(self) -> None:
        for side in (16, 32, 128, 256, 512):
            for suffix in ("", "@2x"):
                name = f"icon_{side}x{side}{suffix}.png"
                self.assertTrue((self.MAC_DIR / name).exists(), name)

    def test_it_is_drawn_not_pasted(self) -> None:
        # A committed generator means the mark follows the faces instead of drifting from them.
        generator = (ROOT / "Tools/release/make_app_icon.py").read_text(encoding="utf-8")
        self.assertIn("case .blob", generator)
        self.assertIn("bar_w, bar_h = size * 0.105, size * 0.185", generator)


class TheWorkingMarkIsTheBotsOwnFace(unittest.TestCase):
    SPINNER = (ROOT / "Sources/OpenBotUI/BotFaceSpinner.swift").read_text(encoding="utf-8")
    PHONE_CHAT = (ROOT / "Apps/HermesMobile/Views/ConversationScreen.swift").read_text(encoding="utf-8")
    MAC_SCROLL = (ROOT / "Apps/HermesMac/Conversation/TranscriptScroll.swift").read_text(encoding="utf-8")

    def test_it_turns_the_face_rather_than_a_wheel(self) -> None:
        self.assertIn("rotation3DEffect(.degrees(degrees)", self.SPINNER)
        self.assertIn("axis: (x: 0, y: 1, z: 0)", self.SPINNER)
        self.assertIn("perspective: 0.42", self.SPINNER)

    def test_it_costs_one_row_and_stops_when_the_turn_does(self) -> None:
        self.assertIn("TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !spins))",
                      self.SPINNER)
        self.assertIn("isWorking && BotFaceMotion.allows", self.SPINNER)

    def test_both_shells_draw_it_before_the_first_token(self) -> None:
        self.assertIn("MobileTypingIndicator(face:", self.PHONE_CHAT)
        self.assertIn("BotFaceSpinner(face: faces[bot.id]", self.MAC_SCROLL)
        self.assertIn("model.isStreaming, model.visibleStreamingText.isEmpty", self.MAC_SCROLL)


class TheFaceGalleryDropsTheInitialsRow(unittest.TestCase):
    def test_there_is_no_initials_option(self) -> None:
        # "Use its initials instead" sat under the shape grid and asked the user to opt out of the
        # thing the screen exists for (requested 2026-11-14).
        self.assertNotIn("Use its initials instead", GALLERY)


if __name__ == "__main__":
    unittest.main()
