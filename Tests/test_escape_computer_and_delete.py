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
GALLERY = (ROOT / "Sources/HermeyUI/BotIconGallery.swift").read_text(encoding="utf-8")


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
        # Both iOS doors — the list's long press and a conversation's Edit — build the sheet through
        # `BotSettingsDoor`, so the delete writer lives there once and cannot be missing from one of them.
        door = (ROOT / "Apps/HermesMobile/Views/BotSettingsDoor.swift").read_text(encoding="utf-8")
        self.assertIn("deleteBot: { try await model.deleteBot(bot.id) })", door)
        self.assertIn("BotSettingsDoor(bot: bot, model: model)", IOS_LIST)
        self.assertIn("BotSettingsDoor(bot: bot, model: model)", IOS_CHAT)
        self.assertNotIn("BotModelSettingsScreen(", IOS_CHAT,
                         "the conversation's door must not be a second copy of the sheet")

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


class TheFaceMovesLikeTheReference(unittest.TestCase):
    """The port's motion vocabulary, and the one switch that decides whether faces move."""

    MOTION = (ROOT / "Sources/HermeyUI/BotAvatarMotion.swift").read_text(encoding="utf-8")
    AVATAR = (ROOT / "Sources/HermeyUI/BotAvatarView.swift").read_text(encoding="utf-8")
    ACTIVITY = (ROOT / "Sources/HermesKit/BotAvatarActivity.swift").read_text(encoding="utf-8")

    def test_each_activity_has_the_reference_cycle(self) -> None:
        for activity, seconds in ((".idle", "1.8"), (".reading", "1.6"), (".writing", "1.35"),
                                  (".thinking", "1.1"), (".computer", "2.4"), (".working", "1.35"),
                                  (".waiting", "1.6")):
            self.assertIn(f"case {activity}: return {seconds}", self.MOTION,
                          f"{activity} lost its cycle length")

    def test_error_rests(self) -> None:
        # The one state that holds still, which is what makes "asleep" readable.
        self.assertIn("case .error:\n            return [BodyFrame(time: 0, pose: .rest)]", self.MOTION)
        self.assertIn("self != .error", self.ACTIVITY)

    def test_the_app_switch_outranks_the_system_and_is_seeded_once(self) -> None:
        # An answer in the app wins; without one the system decides — and the answer is written on
        # first launch so the switch and the faces can never disagree.
        self.assertIn('public static let defaultsKey = "animateBotFaces"', self.MOTION)
        self.assertIn("guard appChoice == nil else { return }", self.MOTION)
        self.assertIn("BotAvatarMotion.seedIfNeeded(reduceMotion: systemReduceMotion)", WORKSPACE)
        appearance = (ROOT / "Apps" / "HermesMac" / "Views" / "AppearanceSettingsTab.swift").read_text(encoding="utf-8")
        self.assertIn("@AppStorage(BotAvatarMotion.defaultsKey) private var animateFaces", appearance)
        self.assertIn('Toggle("Animate bot faces", isOn: $animateFaces)', appearance)

    def test_the_switch_stops_the_motion_in_the_view(self) -> None:
        self.assertIn("@AppStorage(BotAvatarMotion.defaultsKey)", self.AVATAR)
        self.assertIn("animates: animates && appAllowsMotion", self.AVATAR)

    def test_the_timeline_pauses_when_nothing_moves(self) -> None:
        # Thirty frames a second, and only for a face that is allowed to move: a paused
        # `TimelineView` costs nothing, which is what keeps a roster of twenty rows cheap.
        # The beat is per activity now — idle draws at a third of the rate — and a face also stops
        # when its window is not frontmost (Tinker's 42 %-of-a-core report, 2026-11-16).
        self.assertIn("BotAvatarMotion.frameInterval(for: activity)", self.AVATAR)
        self.assertIn("paused: !moves", self.AVATAR)
        self.assertIn("scenePhase == .active", self.AVATAR)
        self.assertIn("public static let frameInterval: Double = 1.0 / 30.0", self.MOTION)
        self.assertIn("activity == .idle ? 1.0 / 10.0 : frameInterval", self.MOTION)

    def test_the_ring_is_drawn_only_while_the_bot_works(self) -> None:
        self.assertNotIn("BotAvatarRing(size:", self.AVATAR)
        self.assertIn("public static let workingRingDuration: Double = 1.2", self.MOTION)


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
    """The wait before the first token wears the bot's face, not a wheel."""

    PHONE_CHAT = (ROOT / "Apps/HermesMobile/Views/ConversationScreen.swift").read_text(encoding="utf-8")
    MAC_SCROLL = (ROOT / "Apps/HermesMac/Conversation/TranscriptScroll.swift").read_text(encoding="utf-8")
    WORKING = (ROOT / "Sources/HermeyUI/WorkingStatus.swift").read_text(encoding="utf-8")

    def test_it_is_the_same_avatar_every_other_surface_draws(self) -> None:
        self.assertIn("public var bot: String?", self.WORKING)
        self.assertIn("public var activity: BotAvatarActivity", self.WORKING)
        self.assertIn("BotAvatarView(identity: bot,", self.WORKING)
        # A caller with no bot still gets the wheel: a room has no single face to draw.
        self.assertIn("SpinningRing(color: Tokens.accent, size: 11, lineWidth: 1.5)", self.WORKING)

    def test_the_row_is_still_the_bots_at_16_pt(self) -> None:
        # The old spinner turned at whatever size it was asked for; the avatar holds still below its
        # own floor, so this row never buys a timeline.
        self.assertIn("size: 16,", self.WORKING)
        self.assertIn("WorkingStatus(bot: bot, activity: activity, color: color)", self.MAC_SCROLL)

    def test_one_row_not_two(self) -> None:
        # The face goes *inside* the working row both shells already draw; the separate "Thinking…"
        # line that was added first is gone (reported 2026-11-14).
        self.assertNotIn('Text("Thinking…")', self.MAC_SCROLL)
        self.assertNotIn("MobileTypingIndicator(face:", self.PHONE_CHAT)
        self.assertIn("WorkingStatus(bot: bot, activity: activity, color: color)", (ROOT / "Apps/HermesMobile/Views/MobileMarkdown.swift").read_text(encoding="utf-8"))


class ABotHasItsOwnNotes(unittest.TestCase):
    """A per-bot note: one file on the host, opened from either shell's bot menu."""

    NOTES = (ROOT / "Sources/HermeyUI/BotNotesSheet.swift").read_text(encoding="utf-8")
    ROUTES = (ROOT / "Bridge/hermes_bridge/bot_notes.py").read_text(encoding="utf-8")
    MAC_PANEL = (MAC / "Workspace" / "MacBotPanel.swift").read_text(encoding="utf-8")
    DRAWER = (ROOT / "Apps/HermesMobile/Views/ConversationDrawer.swift").read_text(encoding="utf-8")

    def test_it_is_a_file_in_the_bots_own_directory(self) -> None:
        # Created with the bot, deleted with the bot: no second list to keep in step.
        self.assertIn('NOTES_NAME = "NOTES.md"', self.ROUTES)
        self.assertIn("directory / NOTES_NAME", self.ROUTES)

    def test_the_route_reads_and_writes_whole_notes(self) -> None:
        self.assertIn('@router.get("/{profile}/notes")', self.ROUTES)
        self.assertIn('@router.put("/{profile}/notes")', self.ROUTES)
        self.assertIn("MAX_NOTES_CHARS = 64_000", self.ROUTES)
        # Written to a scratch file of its own and moved into place: a lost wire must not leave half
        # a note, and two writers must not share one scratch name (`paths.atomic_write_text`).
        self.assertIn("paths.atomic_write_text(path, text)", self.ROUTES)
        # A symlink is refused, not followed or written through.
        self.assertIn("this is a symlink, not a notes file", self.ROUTES)

    def test_both_menus_open_it(self) -> None:
        self.assertIn('row("Notes", icon: "note.text")', self.MAC_PANEL)
        self.assertIn('row("Notes", systemImage: "note.text", run: onNotes)', self.DRAWER)

    def test_the_sheet_reads_on_open_and_saves_the_whole_text(self) -> None:
        self.assertIn(".task { await read() }", self.NOTES)
        self.assertIn("try await save(text)", self.NOTES)
        # "Could not read it" must not look like "nothing written yet".
        self.assertIn("loaded.error", self.NOTES)
        self.assertIn("Stored on the host", self.NOTES)


class BannersArriveWhileTheAppIsShut(unittest.TestCase):
    """The relay: no APNs credential of our own, so Bark carries the banner."""

    PUSH = (ROOT / "Bridge/hermes_bridge/push.py").read_text(encoding="utf-8")
    SETTINGS = (ROOT / "Sources/HermeyUI/PushRelaySettings.swift").read_text(encoding="utf-8")
    PLIST = (ROOT / "project.yml").read_text(encoding="utf-8")

    def test_the_host_pushes_instead_of_the_app(self) -> None:
        # A suspended app cannot poll, so the host does the looking and the relay does the drawing.
        self.assertIn("class ReplyWatcher", self.PUSH)
        self.assertIn('@router.post("/register")', self.PUSH)
        self.assertIn('@router.post("/presence")', self.PUSH)
        self.assertIn('@router.post("/test")', self.PUSH)

    def test_a_banner_opens_the_bot_that_spoke(self) -> None:
        self.assertIn('url=f"hermey://bot/{profile}"', self.PUSH)
        self.assertIn("CFBundleURLSchemes:\n              - hermey", self.PLIST)

    def test_the_bot_on_screen_is_never_announced(self) -> None:
        self.assertIn('if (target.get("preset_bot") == profile', self.PUSH)
        # The phone and the Mac both report it.
        phone = (ROOT / "Apps/HermesMobile/Views/ConversationScreen.swift").read_text(encoding="utf-8")
        self.assertIn("await model.reportPresence(bot: bot.id)", phone)
        self.assertIn("await model.reportPresence(bot: nil)", phone)

    def test_a_restart_does_not_replay_history(self) -> None:
        self.assertIn("if not self._primed:", self.PUSH)
        self.assertIn("push_watch", (ROOT / "Bridge/hermes_bridge/registry.py").read_text(encoding="utf-8"))

    def test_the_banner_carries_the_bot_s_own_face(self) -> None:
        push = (ROOT / "Bridge/hermes_bridge/push.py").read_text(encoding="utf-8")
        icons = (ROOT / "Bridge/hermes_bridge/push_icons.py").read_text(encoding="utf-8")
        exporter = (ROOT / "Sources/HermeyUI/PushIcon.swift").read_text(encoding="utf-8")
        # The app renders the real face (SwiftUI geometry, not a second drawing) and uploads bytes.
        self.assertIn("ImageRenderer", exporter)
        self.assertIn("BotAvatarStill(identity: botID", exporter)
        self.assertIn("icon=icon", push)
        # No render means no image: a URL pointing at nothing inside a notification is worse. A host
        # that was never told its own public name has nothing to hand over either — the base used to
        # be one installation's tailnet name compiled into the source.
        self.assertIn('if not ICON_BASE or not icon_exists(profile):', push)
        self.assertIn('return ""', push)
        # A reply is why the phone buzzed, so it is the notify-me tier.
        self.assertIn('payload["level"] = "timeSensitive"', push)
        # The GET is unauthenticated for the relay app, and serves nothing but a named bot's face.
        self.assertIn("def fetch(profile: str) -> Response:", icons)
        self.assertIn("PNG_MAGIC", icons)

    def test_only_someone_else_s_reply_becomes_a_banner(self) -> None:
        push = (ROOT / "Bridge/hermes_bridge/push.py").read_text(encoding="utf-8")
        proxy = (ROOT / "Bridge/hermes_bridge/proxy.py").read_text(encoding="utf-8")
        app = (ROOT / "Bridge/hermes_bridge/app.py").read_text(encoding="utf-8")
        bot = (ROOT / "Bridge/hermes_bridge/bot_message.py").read_text(encoding="utf-8")
        # The watcher stands down when the prompt was typed on a device...
        self.assertIn('prompt["source"] == "human"', push)
        # ...which is recorded where a human prompt is distinguishable from a bot's, and nowhere else.
        self.assertIn('method == "prompt.submit" and self._on_prompt is not None', proxy)
        self.assertIn('set_push_prompt(profile, "human")', app)
        # A bot-to-bot message is the opposite case: its reply is what a banner is for.
        self.assertIn('set_push_prompt(profile, "program")', bot)

    def test_the_phone_s_own_banner_carries_the_face(self) -> None:
        cache = (ROOT / "Apps/HermesMobile/App/MobileFaceCache.swift").read_text(encoding="utf-8")
        notes = (ROOT / "Apps/HermesMobile/App/ReplyNotifications.swift").read_text(encoding="utf-8")
        shell = (ROOT / "Apps/HermesMobile/HermesMobileApp.swift").read_text(encoding="utf-8")
        # A picture inside the banner is the only way to show a bot here: iOS takes the corner icon
        # from the bundle, and no per-notification call can change it.
        self.assertIn("UNNotificationAttachment", cache)
        self.assertEqual(notes.count("content.attachments = [attachment]"), 2,
                         "both the foreground post and the background sweep")
        # Rendering is main-actor and the sweep is not, so the faces are cached as files at launch.
        self.assertIn("await MobileFaceCache.refresh(faces: faces)", shell)
        # And a banner is wanted with or without a relay.
        self.assertLess(shell.index("await MobileFaceCache.refresh(faces: faces)"),
                        shell.index('string(forKey: PushRelay.urlKey)'))

    def test_reading_a_bot_means_the_app_is_on_screen(self) -> None:
        # A presence claim is what silences a bot, so it has to expire with the app: a phone locked
        # mid-chat once muted that bot for eight hours.
        push = (ROOT / "Bridge/hermes_bridge/push.py").read_text(encoding="utf-8")
        registry = (ROOT / "Bridge/hermes_bridge/registry.py").read_text(encoding="utf-8")
        phone = (ROOT / "Apps/HermesMobile/HermesMobileApp.swift").read_text(encoding="utf-8")
        mac = (ROOT / "Apps/HermesMac/Workspace/WorkspaceRoot.swift").read_text(encoding="utf-8")
        self.assertIn("PRESENCE_SECONDS", push)
        self.assertIn("updated_at", registry.split("def set_push_presence")[1].split("def ")[0])
        self.assertIn("scenePhase", phone)
        self.assertIn("scenePhase", mac)

    def test_one_field_is_the_whole_setup(self) -> None:
        self.assertIn('TextField("http://your-host:8081/your-key"', self.SETTINGS)
        self.assertIn('HermeyButton(isTesting ? "Sending…" : "Send a test"', self.SETTINGS)


class TheEmptyChatIsAnInvitation(unittest.TestCase):
    CHAT = (ROOT / "Apps/HermesMobile/Views/ConversationScreen.swift").read_text(encoding="utf-8")

    def test_it_fills_the_view_and_sits_in_the_middle(self) -> None:
        # It used to be the first row of a lazy stack: a short block under the pill with a screenful
        # of nothing beneath it, which read as a screen that had failed to load (2026-11-14).
        self.assertIn("private var blankState: some View", self.CHAT)
        self.assertIn(".containerRelativeFrame(.vertical) { height, _ in", self.CHAT)
        self.assertIn("max(0, height - 74 - composerHeight)", self.CHAT)
        self.assertIn("if isBlank, !isOpening {\n                        blankState", self.CHAT)

    def test_it_shows_the_bots_own_face_and_words(self) -> None:
        self.assertIn("BotAvatarView(identity: bot.id,", self.CHAT)
        self.assertIn("size: 72)", self.CHAT)
        self.assertIn("private var subtitle: String", self.CHAT)
        self.assertIn("return description", self.CHAT)

    def test_the_copy_names_the_bot_not_the_host(self) -> None:
        # "the moment Hermes needs one" on a bot called nestor asked the reader who Hermes was.
        transcript = (ROOT / "Apps/HermesMobile/Views/MobileTranscript.swift").read_text(encoding="utf-8")
        self.assertNotIn("Hermes needs one", transcript)


class TheFaceGalleryDropsTheInitialsRow(unittest.TestCase):
    def test_there_is_no_initials_option(self) -> None:
        # "Use its initials instead" sat under the shape grid and asked the user to opt out of the
        # thing the screen exists for (requested 2026-11-14).
        self.assertNotIn("Use its initials instead", GALLERY)


if __name__ == "__main__":
    unittest.main()
