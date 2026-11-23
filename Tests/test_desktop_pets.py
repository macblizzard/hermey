"""Desktop pets: an icon-only window per bot, its idle motion, and the ask/answer balloon.

The design (`docs/DESKTOP-PETS.md`) calls the window the one requirement that decides whether the
feature feels like a pet or like a widget, and says so in four properties that look correct in code
review and wrong on a desktop. Those four are pinned here, with the pass-through hit test, the route
and body of `askBot`, the two `UserDefaults` keys the toggle and the controller must agree about, and
the fact that closing a pet from its own menu switches its setting off.

These are source guards, not behaviour tests: CI is the only Swift compiler, so the assertions are
about what the code says. The arithmetic behind the clamping and the balloon's transitions is covered
by XCTest in `Tests/HermesKitTests`.
"""
from __future__ import annotations

import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PETS = ROOT / "Apps" / "HermesMac" / "Pets"

PANEL = (PETS / "DesktopPetPanel.swift").read_text(encoding="utf-8")
VIEW = (PETS / "PetView.swift").read_text(encoding="utf-8")
BALLOON = (PETS / "PetBalloonView.swift").read_text(encoding="utf-8")
SETTINGS = (PETS / "PetSettings.swift").read_text(encoding="utf-8")
CONTROLLER = (PETS / "DesktopPetController.swift").read_text(encoding="utf-8")

SHEET = (ROOT / "Apps" / "HermesMac" / "Views" / "MacBotSettingsSheet.swift").read_text(encoding="utf-8")
WORKSPACE = (ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceRoot.swift").read_text(encoding="utf-8")

KIT = ROOT / "Sources" / "HermesKit"
BOT_ASK = (KIT / "BotAsk.swift").read_text(encoding="utf-8")
POINTER = (KIT / "EndlessSessionPointer.swift").read_text(encoding="utf-8")
GATEWAY = (KIT / "GatewayClient.swift").read_text(encoding="utf-8")
ACTOR = (KIT / "GatewayClientActor.swift").read_text(encoding="utf-8")
STATE = (KIT / "PetBalloonState.swift").read_text(encoding="utf-8")


class TheWindowIsOnlyAnIcon(unittest.TestCase):
    """Where the feature is won: a window with no frame, no fill and no shadow."""

    def test_style_mask_is_borderless_and_nonactivating(self):
        self.assertIn("styleMask: [.borderless, .nonactivatingPanel]", PANEL,
                      "a titled window is a widget with a title bar; a borderless one is furniture")

    def test_the_window_draws_no_fill_and_no_shadow(self):
        for line in ("isOpaque = false", "backgroundColor = .clear", "hasShadow = false"):
            self.assertIn(line, PANEL,
                          f"{line} is what keeps the desktop visible around the icon")

    def test_titlebar_appears_transparent(self):
        self.assertIn("titlebarAppearsTransparent = true", PANEL)

    def test_it_floats_on_every_space_and_over_full_screen_apps(self):
        self.assertIn("level = .floating", PANEL)
        self.assertIn("collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]", PANEL)

    def test_a_pet_never_takes_the_keyboard(self):
        self.assertIn("override var canBecomeKey: Bool { false }", PANEL)
        self.assertIn("override var canBecomeMain: Bool { false }", PANEL)

    def test_nothing_behind_the_icon_is_drawn(self):
        # A material, a hairline or a rounded plate behind the picture would be exactly the widget
        # feel the design rules out. The balloon is a separate window and may draw its own bubble.
        for text, name in ((PANEL, "DesktopPetPanel.swift"), (VIEW, "PetView.swift")):
            for banned in ("NSVisualEffectView", ".ultraThinMaterial", ".regularMaterial",
                           "NSBox", "windowBackgroundColor"):
                self.assertNotIn(banned, text, f"{name} draws {banned} behind the icon")

    def test_the_icon_is_the_bots_own_face(self):
        self.assertIn("BotAvatarStill(identity: pet.botID, color: pet.face, size: side)", VIEW)
        self.assertIn("PetGeometry.iconSide", VIEW)

    def test_the_window_is_the_icon_plus_a_clear_motion_ring(self):
        placement = (KIT / "PetPlacement.swift").read_text(encoding="utf-8")
        self.assertIn("static let iconSide: Double = 96", placement)
        self.assertIn("static let motionMargin: Double = 12", placement,
                      "a hop has to have somewhere to go, or the window clips its own icon")
        self.assertIn("static func windowSide(icon: Double) -> Double", placement)
        self.assertIn("DesktopPetPanel(side: windowSide)", CONTROLLER,
                      "the panel is created at the icon's size plus that ring, not a guessed one")


class TheTransparentPartsAreNotClickable(unittest.TestCase):
    """`hitTest` declines a hit where the icon has no alpha — otherwise a 96 pt square eats clicks."""

    def test_the_content_view_overrides_hit_test(self):
        self.assertIn("override func hitTest(_ point: NSPoint) -> NSView?", PANEL)

    def test_the_hit_is_declined_where_the_icon_has_no_ink(self):
        block = PANEL.split("override func hitTest", 1)[1].split("override func acceptsFirstMouse", 1)[0]
        self.assertIn("guard let iconMask", block)
        self.assertIn("hasInk(at: iconPoint)", block)
        self.assertIn("return nil", block)
        self.assertLess(block.index("return nil"), block.index("return super.hitTest"),
                        "the nil has to come before the delegation, or the view is always hit")

    def test_the_mask_is_the_drawn_shape_or_the_photos_alpha(self):
        self.assertIn("resolved.shape.path(inSide: side)", VIEW,
                      "the body is the only opaque ink, so its path is the alpha")
        self.assertIn("alphaComponent", VIEW,
                      "a photo face answers from its own pixels")

    def test_the_click_really_passes_through_at_the_window_level(self):
        # A borderless transparent window still receives the click on macOS; declining the hit only
        # stops a view. The controller makes it real by ignoring mouse events over empty space.
        self.assertIn("ignoresMouseEvents", CONTROLLER)
        self.assertIn("NSEvent.mouseLocation", CONTROLLER)
        self.assertIn("ignoresMouseEvents = true", PANEL,
                      "a pet starts click-through so its first frame cannot eat a click")


class TheIdleMotionIsCheapAndKinder(unittest.TestCase):
    def test_the_moves_are_transform_only(self):
        for modifier in (".offset(motion.offset)", ".rotationEffect(", ".scaleEffect("):
            self.assertIn(modifier, VIEW)
        self.assertIn("BotAvatarStill", VIEW,
                      "no second animation asset: the same face, moved")

    def test_the_interval_is_eight_to_thirty_seconds(self):
        self.assertIn("Double.random(in: 8...30)", VIEW)

    def test_reduce_motion_is_read_from_the_system(self):
        self.assertIn("NSWorkspace.shared.accessibilityDisplayShouldReduceMotion", VIEW)
        self.assertIn("guard !reduceMotion else { return .bob }", VIEW,
                      "under Reduce Motion only the smallest move survives — never a hop")

    def test_an_occluded_panel_stops_animating(self):
        self.assertIn("occlusionState", CONTROLLER)
        self.assertIn(".task(id: pet.isVisible)", VIEW)
        self.assertIn("pet.model.isVisible", CONTROLLER)


class TheRouteIsTheDocumentedOne(unittest.TestCase):
    def test_the_ask_route_is_built_from_the_documented_parts(self):
        self.assertIn('appendingPathComponent("v1")', BOT_ASK)
        self.assertIn('appendingPathComponent("bots")', BOT_ASK)
        self.assertIn('appendingPathComponent("ask")', BOT_ASK)

    def test_the_body_is_question_from_timeout(self):
        for key in ('"question": question', '"from": from', '"timeout": timeout'):
            self.assertIn(key, BOT_ASK)

    def test_the_pet_signs_its_questions(self):
        self.assertIn('fromDesktopPet = "desktop-pet"', BOT_ASK)
        self.assertIn("from: BotAsk.fromDesktopPet", CONTROLLER,
                      "the host's transcript has to show where the question came from")

    def test_the_pointer_posts_it_with_a_ticket(self):
        # The bridge implementation, not the protocol's default (which has the same signature and
        # simply says "unreachable").
        block = POINTER.split("/// `POST /v1/bots/{profile}/ask` — the pet's whole conversation model.", 1)[1]
        self.assertIn('request.httpMethod = "POST"', block)
        self.assertIn("BotAsk.url(base: endpoint.baseURL, profile: profile)", block)
        self.assertIn("request.httpBody = try BotAsk.body(", block)
        self.assertIn('forHTTPHeaderField: "Authorization"', block)

    def test_the_protocol_and_the_actor_carry_it(self):
        self.assertIn("func askBot(profile: String, question: String, from: String, timeout: Double)"
                      " async throws -> BotAnswer", GATEWAY)
        self.assertIn("func askBot(profile: String, question: String, from: String,", ACTOR)
        self.assertIn("sessionPointer.ask(profile: profile", ACTOR)

    def test_a_timeout_is_an_answer_not_an_error(self):
        self.assertIn("case unanswered(question: String)", STATE)
        self.assertIn('unansweredText = "Sent — it hasn\'t answered yet."', STATE)

    def test_the_hosts_refusal_is_shown_unchanged(self):
        self.assertIn("case host(String)", BOT_ASK)
        self.assertIn("case .host(let detail): return detail.isEmpty"
                      " ? \"The host refused the question.\" : detail", BOT_ASK)

    def test_an_unreachable_host_has_its_own_sentence(self):
        self.assertIn('unreachableText = "Can\'t reach the host right now."', STATE)


class OneSwitchOneSetting(unittest.TestCase):
    """The toggle, the controller and the pet's own menu write and read the same two keys."""

    def test_the_keys_are_built_in_exactly_one_place(self):
        self.assertIn('static let enabledPrefix = "pets.enabled."', SETTINGS)
        self.assertIn('static let positionPrefix = "pets.position."', SETTINGS)
        self.assertIn("static func enabledKey(for botID: String) -> String", SETTINGS)
        self.assertIn("static func positionKey(for botID: String) -> String", SETTINGS)

    def test_no_other_file_spells_the_keys_itself(self):
        for text, name in ((SHEET, "MacBotSettingsSheet.swift"),
                           (CONTROLLER, "DesktopPetController.swift"),
                           (VIEW, "PetView.swift")):
            self.assertNotIn('"pets.enabled.', text, f"{name} writes its own copy of the switch")
            self.assertNotIn('"pets.position.', text, f"{name} writes its own copy of the position")

    def test_the_sheet_uses_the_settings_type(self):
        self.assertIn("PetSettings.isEnabled(bot.id)", SHEET)
        self.assertIn("DesktopPetController.shared.setEnabled(enabled, for: bot)", SHEET)
        self.assertIn('Toggle(isOn: Binding(get: { petEnabled },', SHEET)
        self.assertIn('Text("Show \\(bot.displayName) on the desktop")', SHEET)

    def test_bring_it_here_centres_the_pet(self):
        self.assertIn('HermeyButton("Bring it here"', SHEET)
        self.assertIn("DesktopPetController.shared.bringHere(bot)", SHEET)
        self.assertIn("PetGeometry.centre(in: rect(screen.visibleFrame)", CONTROLLER)

    def test_the_controller_reads_the_switch_the_toggle_writes(self):
        self.assertIn("PetSettings.isEnabled(botID)", CONTROLLER)
        self.assertIn("PetSettings.setEnabled(enabled, for: bot.id)", CONTROLLER)

    def test_closing_from_the_pets_own_menu_writes_false(self):
        menu = VIEW.split(".contextMenu", 1)[1]
        self.assertIn('Button("Close pet", role: .destructive) { onClose() }', menu)
        self.assertIn('close(botID, reason: "closed from its own menu", writesSetting: true',
                      CONTROLLER)
        self.assertIn("if writesSetting { PetSettings.setEnabled(false, for: botID) }", CONTROLLER)
        self.assertIn("if forgetPosition { PetSettings.setPosition(nil, for: botID) }",
                      CONTROLLER, "a closed pet comes back centred, not where it was dragged")

    def test_the_sheet_follows_a_pet_closed_elsewhere(self):
        self.assertIn("static let changedNotification", SETTINGS)
        self.assertIn("PetSettings.changedNotification", SHEET)

    def test_positions_are_clamped_on_launch_and_on_screen_changes(self):
        self.assertIn("PetGeometry.clamp(saved, side: side, to: rect(target.visibleFrame))",
                      CONTROLLER)
        self.assertIn("NSApplication.didChangeScreenParametersNotification", CONTROLLER)

    def test_a_pet_whose_bot_vanished_is_closed_and_forgotten(self):
        self.assertIn("let gone = !present.contains(botID)", CONTROLLER)
        self.assertIn('"bot removed"', CONTROLLER)
        self.assertIn("forgetPosition: gone", CONTROLLER)


class WiredExactlyOnce(unittest.TestCase):
    def test_the_controller_is_attached_from_one_place(self):
        self.assertIn("DesktopPetController.shared.attach(store: store)", WORKSPACE)
        self.assertEqual(WORKSPACE.count("DesktopPetController.shared.attach"), 1,
                         "attaching twice would double every pet")

    def test_attach_is_idempotent_and_quit_closes_cleanly(self):
        self.assertIn("guard self.store !== store else { return }", CONTROLLER)
        self.assertIn("NSApplication.willTerminateNotification", CONTROLLER)
        self.assertIn('close(botID, reason: "app quit", writesSetting: false, forgetPosition: false)',
                      CONTROLLER)

    def test_the_log_says_what_happened(self):
        for line in ('"pet shown: ', '"pet closed: ', "question sent", "answer arrived",
                     "no answer by the timeout"):
            self.assertIn(line, CONTROLLER + BALLOON, f"the log never mentions {line}")
        self.assertIn('category: "pets"', CONTROLLER)
        self.assertIn('category: "pets"', BALLOON)

    def test_one_question_at_a_time(self):
        self.assertIn(".disabled(!model.state.acceptsInput)", BALLOON)
        self.assertIn("guard !trimmed.isEmpty, !isAsking else { return false }", STATE)

    def test_the_balloon_is_a_separate_window_above_the_pet(self):
        self.assertIn("NSWindow.Level.floating.rawValue + 1", BALLOON)
        self.assertIn("PetGeometry.above(", BALLOON)
        self.assertIn(".frame(maxHeight: 240)", BALLOON, "a long answer scrolls; the pet never grows")
        self.assertIn("setString(text, forType: .string)", BALLOON)
        self.assertIn("event.keyCode == 53", BALLOON, "Escape dismisses even with the field focused")

    def test_an_answer_makes_the_pet_hop(self):
        self.assertIn("model.onAnswer = { [weak pet] in pet?.model.celebrate() }", CONTROLLER)
        self.assertIn(".onChange(of: pet.celebrations)", VIEW)
        self.assertIn("accessibilityDisplayShouldReduceMotion else { return }", VIEW,
                      "Reduce Motion takes the hop away; it does not resize it")


class NothingElseWasTouched(unittest.TestCase):
    """macOS only: no iOS app, no host, no cards."""

    def test_new_files_are_all_in_the_mac_target(self):
        for name in ("DesktopPetPanel.swift", "PetView.swift", "PetBalloonView.swift",
                     "PetSettings.swift", "DesktopPetController.swift"):
            path = PETS / name
            self.assertTrue(path.is_file(), f"{name} is missing")
            self.assertEqual(PETS, path.parent)
        self.assertEqual([], sorted(p.name for p in PETS.iterdir() if p.suffix != ".swift"),
                         "everything in Pets/ is a Mac source file")

    def test_the_ios_app_knows_nothing_about_pets(self):
        mobile = ROOT / "Apps" / "HermesMobile"
        for path in mobile.rglob("*.swift"):
            text = path.read_text(encoding="utf-8", errors="ignore")
            for word in ("DesktopPet", "PetSettings", "PetBalloon", "PetGeometry"):
                self.assertNotIn(word, text, f"{path.relative_to(ROOT)} mentions {word}")

    def test_the_host_was_not_changed(self):
        for path in (ROOT / "hermeyd" / "src").rglob("*.rs"):
            text = path.read_text(encoding="utf-8", errors="ignore")
            self.assertNotIn("desktop-pet", text)
            self.assertNotIn("desktop_pet", text)

    def test_the_cards_renderer_was_not_changed(self):
        cards = ROOT / "Sources" / "HermesCards"
        for path in cards.rglob("*.swift"):
            text = path.read_text(encoding="utf-8", errors="ignore")
            self.assertNotIn("PetGeometry", text)

    def test_the_diff_touches_nothing_outside_the_mac_target(self):
        changed = _changed_files()
        if changed is None:
            self.skipTest("no git base to compare against")
        offending = sorted(
            path for path in changed
            if path.startswith(("Apps/HermesMobile/", "hermeyd/", "Sources/HermesCards/"))
        )
        self.assertEqual([], offending, "the desktop pet is a macOS feature")


def _changed_files() -> list[str] | None:
    """Every path this branch adds or edits, against `origin/main`; None when git cannot say."""
    try:
        base = subprocess.check_output(
            ["git", "merge-base", "HEAD", "origin/main"], cwd=ROOT, text=True,
            stderr=subprocess.DEVNULL).strip()
        if not base:
            return None
        diff = subprocess.check_output(
            ["git", "diff", "--name-only", base, "HEAD"], cwd=ROOT, text=True).splitlines()
        status = subprocess.check_output(
            ["git", "status", "--porcelain"], cwd=ROOT, text=True).splitlines()
    except (OSError, subprocess.CalledProcessError):
        return None
    untracked = [line[3:].strip() for line in status if line.startswith("??")]
    return [line for line in diff if line.strip()] + [line for line in untracked if line.strip()]


class ProjectFilePicksThemUp(unittest.TestCase):
    def test_the_mac_target_is_a_folder_glob(self):
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        self.assertIn("- path: Apps/HermesMac", project)
        self.assertNotIn("Pets", project,
                         "the glob already includes Pets/; registering it by hand means a new file "
                         "can be added and never compiled")

    def test_no_entitlement_or_permission_request_was_added(self):
        self.assertNotIn("NSScreenCaptureUsageDescription", PANEL + VIEW + CONTROLLER)
        self.assertNotIn("AXIsProcessTrusted", PANEL + VIEW + CONTROLLER)
        self.assertNotIn("CGRequestScreenCaptureAccess", PANEL + VIEW + CONTROLLER)


if __name__ == "__main__":
    unittest.main()
