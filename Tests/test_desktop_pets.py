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

import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PETS = ROOT / "Apps" / "HermesMac" / "Pets"

PANEL = (PETS / "DesktopPetPanel.swift").read_text(encoding="utf-8")
COMPOSER = (ROOT / "Apps" / "HermesMac" / "Conversation" / "MacComposerBar.swift").read_text(encoding="utf-8")
VIEW = (PETS / "PetView.swift").read_text(encoding="utf-8")
BALLOON = (PETS / "PetBalloonView.swift").read_text(encoding="utf-8")
SETTINGS = (PETS / "PetSettings.swift").read_text(encoding="utf-8")
CONTROLLER = (PETS / "DesktopPetController.swift").read_text(encoding="utf-8")
BADGE = (PETS / "PetBadge.swift").read_text(encoding="utf-8")
PRESENCE = (PETS / "PetWindowPresence.swift").read_text(encoding="utf-8")

SHEET = (ROOT / "Apps" / "HermesMac" / "Views" / "MacBotSettingsSheet.swift").read_text(encoding="utf-8")
WORKSPACE = (ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceRoot.swift").read_text(encoding="utf-8")

KIT = ROOT / "Sources" / "HermesKit"
PLACEMENT = (KIT / "PetPlacement.swift").read_text(encoding="utf-8")
MODEL = (ROOT / "Sources" / "HermesAppKit" / "AppModel.swift").read_text(encoding="utf-8")
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
        # The rule itself lives in `hasTarget`, because the controller's window-server pass-through
        # has to ask the same question: two answers would be two different pets.
        self.assertIn("hasTarget(at: iconPoint)", block)
        self.assertIn("return nil", block)
        self.assertLess(block.index("return nil"), block.index("return super.hitTest"),
                        "the nil has to come before the delegation, or the view is always hit")
        target = PANEL.split("func hasTarget(at iconPoint: CGPoint) -> Bool {", 1)[1].split("\n    }", 1)[0]
        self.assertIn("iconMask.hasInk(at: iconPoint)", target,
                      "the icon's own alpha is still the boundary against the desktop")
        self.assertIn("return false", target, "no mask, no pet")

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
        # The gaze rides in the same offset as the move: `offset(x: gaze …, y: motion.offset.height)`.
        for modifier in (".offset(x: gaze * side * PetEyes.drift, y: motion.offset.height)",
                         ".rotationEffect(", ".scaleEffect("):
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

    def test_the_balloon_is_a_separate_window_beside_the_pet(self):
        self.assertIn("NSWindow.Level.floating.rawValue + 1", BALLOON)
        self.assertIn("PetCalloutPlacement.place(", BALLOON)
        self.assertIn("let placed = PetCalloutPlacement.place(", BALLOON)
        self.assertIn("pet: petRect", BALLOON,
                      "the placement is given the pet's frame, not a centre point: that frame is "
                      "the thing the bubble must not cover")
        self.assertIn("PetCalloutMetrics.answerHeight(of: answer)", BALLOON,
                      "the answer's height is measured before the bubble settles on its size")
        self.assertIn("hosting.sizingOptions = [.preferredContentSize]", BALLOON,
                      "the window is still only as big as the view that fills it")
        self.assertIn("setString(text, forType: .string)", BALLOON)
        self.assertIn("event.keyCode == 53", BALLOON, "Escape dismisses even with the field focused")

    def test_an_answer_makes_the_pet_hop(self):
        self.assertIn("model.onAnswer = { [weak pet] in pet?.model.celebrate() }", CONTROLLER)
        self.assertIn(".onChange(of: pet.celebrations)", VIEW)
        self.assertIn("accessibilityDisplayShouldReduceMotion else { return }", VIEW,
                      "Reduce Motion takes the hop away; it does not resize it")


class AReplyWhileHeIsAwayHopsAndWaits(unittest.TestCase):
    """Minimise the window, ask a bot something, and its pet hops and wears a dot.

    The owner chose exactly this, and not an auto-popping balloon: the hop is the attention, the dot
    is the fact, and the reply arrives when *he* clicks the pet. So the guards here are about
    restraint as much as about behaviour — one source of truth for the count (`AppModel`), one hop
    path (`play(.hop)`), one clearing rule (`markBotRead`), and nothing that opens itself.
    """

    @staticmethod
    def _refresh() -> str:
        """`refreshUnread`: the whole decision, from the model's counts to the pet's hop."""
        return CONTROLLER.split("private func refreshUnread() {", 1)[1].split("private static func", 1)[0]

    @staticmethod
    def _unread_section() -> str:
        return CONTROLLER.split("// MARK: - Unread", 1)[1].split("// MARK: - Screens", 1)[0]

    def test_the_badge_reads_the_apps_own_counters(self):
        refresh = self._refresh()
        self.assertIn("let model = store.model", refresh)
        self.assertIn("Self.unreadCount(botID: botID, in: model)", refresh,
                      "the pet's badge is the model's number, read where it is decided")
        unread = CONTROLLER.split("private static func unreadCount", 1)[1].split("\n    }", 1)[0]
        self.assertIn("model.unreadCounts[botID] ?? 0", unread)
        self.assertIn("model.unreadBots.contains(botID) ? 1 : 0", unread,
                      "a bot marked unread without a count still has one turn waiting")
        # One subscription, on the model's own publisher — no second notification system.
        self.assertIn("store.model.objectWillChange", CONTROLLER)
        self.assertEqual(1, CONTROLLER.count(".sink {"), "one watch, not one per pet")
        self.assertNotIn("private var unread: Int", CONTROLLER,
                         "the controller must not keep a count of its own")

    def test_the_badge_is_the_models_number_shown(self):
        self.assertIn("@Published private(set) var unread = 0", VIEW)
        self.assertIn("PetUnreadBadge(count: pet.unread)", VIEW)
        self.assertIn("if pet.unread > 0 {", VIEW, "zero draws nothing at all")
        # The dot: accent fill, a white hairline, the count only above one.
        self.assertIn("Circle().fill(Tokens.accent)", BADGE)
        self.assertIn("Circle().strokeBorder(Color.white.opacity(0.92), lineWidth: 1)", BADGE,
                      "the hairline is what keeps the accent readable on a light wallpaper")
        self.assertIn("if count > 1 {", BADGE, "one waiting turn is a dot, not a '1'")
        self.assertNotIn("Tokens.text", BADGE, "the text is pinned white, not a theme ink")

    @staticmethod
    def _constant(pattern: str, text: str) -> float:
        """The number in a `static let … = <n>` line, from whichever file declares it."""
        match = re.search(pattern, text)
        assert match is not None, f"no constant matching {pattern!r}"
        return float(match.group(1))

    def test_the_badge_fits_inside_the_icons_own_box(self):
        icon = self._constant(r"static let iconSide: Double = ([\d.]+)", PLACEMENT)
        side = self._constant(r"static let side: CGFloat = ([\d.]+)", BADGE)
        inset = self._constant(r"static let inset: CGFloat = ([\d.]+)", BADGE)
        self.assertGreaterEqual(icon - side - inset, 0,
                                "the dot has to sit inside the icon's square, or the window grows")
        self.assertLessEqual(side, icon / 4, "a badge on a pet, not a second face")
        self.assertGreaterEqual(inset, 1, "a dot flush against the corner reads as a crop")
        self.assertIn("CGRect(x: iconSide - side - inset, y: inset, width: side, height: side)",
                      BADGE)

    def test_the_badge_is_part_of_the_pet_you_can_click(self):
        target = PANEL.split("func hasTarget(at iconPoint: CGPoint) -> Bool {", 1)[1].split("\n    }", 1)[0]
        self.assertIn("if hasBadge, PetBadge.contains(iconPoint, iconSide: iconMask.side)",
                      target, "the dot sits on a corner the icon's own ink often leaves empty")
        self.assertIn("iconMask.hasInk(at: iconPoint)", target)
        self.assertIn("var hasBadge = false", PANEL)
        self.assertIn("pet.hitView.hasBadge = count > 0", CONTROLLER,
                      "the hit view has to be told, or the dot is drawn but passes clicks through")
        self.assertIn("pet.hitView.hasTarget(at: local)", CONTROLLER,
                      "the window-server pass-through asks the same shape the view answers")
        self.assertNotIn("iconMask?.hasInk(at: local)", CONTROLLER,
                         "a second, ink-only answer there would make the dot click-through")

    def test_a_dot_is_hit_as_a_circle_not_as_its_box(self):
        contains = BADGE.split("static func contains(", 1)[1].split("\n    }", 1)[0]
        self.assertIn("dx * dx + dy * dy <= radius * radius", contains,
                      "the corners of an 18 pt square over a blob are not pet")
        self.assertIn("let radius = side / 2", contains)

    def test_the_hop_needs_a_window_he_cannot_see(self):
        refresh = self._refresh()
        self.assertIn("let away = PetWindowPresence.isAway()", refresh)
        self.assertIn("setUnread(count, hopWhenAway: away)", refresh,
                      "the count and the window's state travel together; one cannot apply without "
                      "the other")
        self.assertIn("if NSApp.isHidden { return true }", PRESENCE, "⌘H is hidden, not minimised")
        self.assertIn("return !workspace.contains { !$0.isMiniaturized && $0.isVisible }", PRESENCE,
                      "a minimised window stops being visible, and is asked both ways anyway")
        self.assertIn("$0.canBecomeMain && !($0 is NSPanel)", PRESENCE,
                      "a pet panel can never be mistaken for the window it reports on")
        self.assertIn("guard !workspace.isEmpty else { return true }", PRESENCE)

    def test_no_hop_when_he_is_looking(self):
        # The gate is on the model, not the view: a visible window means no `notices` bump at all.
        setter = VIEW.split("func setUnread(_ count: Int, hopWhenAway: Bool) -> Bool {", 1)[1].split("\n    }", 1)[0]
        self.assertIn("let grew = count > unread", setter, "a stale republish is not a new reply")
        self.assertIn("guard grew, hopWhenAway else { return false }", setter)
        self.assertLess(setter.index("guard grew, hopWhenAway"),
                        setter.index("notices += 1"),
                        "nothing hops before both facts are true")

    def test_the_hop_is_the_pets_existing_hop(self):
        self.assertIn("@Published private(set) var notices = 0", VIEW)
        hop = VIEW.split(".onChange(of: pet.notices)", 1)[1].split(".onChange(of: pet.taps)", 1)[0]
        self.assertIn("Task { await play(.hop) }", hop,
                      "the same move an answer gets; a second animation would be a second pet")
        self.assertIn("accessibilityDisplayShouldReduceMotion else { return }", hop,
                      "Reduce Motion takes the hop away, as it does for an answer")
        self.assertNotIn("withAnimation", hop, "the hop's curve belongs to `play`")
        self.assertIn('ClientLog.note("pet \\(botID): hopped', CONTROLLER)
        self.assertIn("count) waiting with the window away", CONTROLLER,
                      "the log says why it hopped")

    def test_the_balloon_opening_clears_the_badge(self):
        open_balloon = CONTROLLER.split("private func openBalloon(botID: String) {", 1)[1]
        self.assertIn("clearUnread(for: botID)", open_balloon)
        self.assertLess(open_balloon.index("clearUnread(for: botID)"),
                        open_balloon.index("if let existing = pet.balloon"),
                        "the clear must come before the re-present early return")
        clear = CONTROLLER.split("private func clearUnread(for botID: String) {", 1)[1].split("\n    }", 1)[0]
        self.assertIn("store?.model.markBotRead(botID)", clear,
                      "the app's rule, not a copy of it")
        self.assertIn("pets[botID]?.hitView.hasBadge = false", clear)
        self.assertIn("setUnread(0, hopWhenAway: false)", clear,
                      "clearing is never a hop")

    def test_the_app_clears_through_one_door(self):
        door = MODEL.split("public func markBotRead(_ botID: String) {", 1)[1].split("\n    }", 1)[0]
        self.assertEqual("clearUnread(botID)", door.strip(),
                         "the smallest possible door onto the rule that already exists")
        self.assertIn("private func clearUnread(_ botID: String)", MODEL,
                      "which stays private: the pet is not a second owner of the badge")

    def test_the_apps_own_clear_reaches_the_pet(self):
        # The badge is a projection: the publish that clears the bot list's dot is the one that
        # takes the pet's away, with nothing to go stale in between.
        self.assertIn("store.model.objectWillChange", CONTROLLER)
        self.assertIn(".debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)", CONTROLLER,
                      "an answer streams a delta at a time; the count is read once it settles")
        self.assertIn("Task { @MainActor in self?.refreshUnread() }", CONTROLLER,
                      "objectWillChange is sent before the mutation, so the read waits a turn")
        self.assertIn("guard watchedModel != identity else { return }", CONTROLLER,
                      "a re-pair replaces the model, and a stale watch would go quiet")
        self.assertIn("unreadWatch = nil", CONTROLLER, "and quitting drops it")

    def test_an_open_balloon_is_not_announced_to_itself(self):
        refresh = self._refresh()
        self.assertIn("let count = pet.balloon == nil ? Self.unreadCount(botID: botID, in: model) : 0",
                      refresh,
                      "the bubble he is reading is not a reply he needs telling about — the pet's "
                      "own ask lands as a message in the app's own count")

    def test_the_balloon_never_opens_itself(self):
        self.assertEqual(1, CONTROLLER.count("openBalloon(botID: botID)"),
                         "one call site: the click")
        click = CONTROLLER.split("private func clicked(botID: String) {", 1)[1].split("private func", 1)[0]
        self.assertIn("openBalloon(botID: botID)", click)
        unread = self._unread_section()
        self.assertNotIn("openBalloon", unread, "the unread path never presents a window")
        self.assertNotIn("present()", unread)
        self.assertNotIn("pet.model.tap()", unread, "nor fakes a click to get one")

    def test_nothing_else_notifies(self):
        # The app already has banners, sound and the Dock tile, and this adds none of them.
        for text, name in ((CONTROLLER, "the controller"), (VIEW, "the view"),
                           (BADGE, "the badge"), (PRESENCE, "the presence check")):
            for banned in ("NSSound", "UNUserNotificationCenter", "ReplyNotifier",
                           "dockTile", "updateBadge", "requestUserAttention",
                           "NSApplication.requestUserAttention", "appearance = "):
                self.assertNotIn(banned, text, f"{name} reached for {banned}")

    def test_the_badge_rides_the_icon_and_never_resizes_the_window(self):
        overlay = VIEW.split(".overlay(alignment: .topTrailing)", 1)[1].split(".brightness(", 1)[0]
        self.assertIn("PetUnreadBadge(count: pet.unread)", overlay)
        self.assertIn(".allowsHitTesting(false)", BADGE,
                      "the pet's menu and its click come from the panel and the base view")
        # Drawn before the transforms, so the hop carries the dot with it.
        body = VIEW.split("var body: some View {", 1)[1]
        self.assertLess(body.index(".overlay(alignment: .topTrailing)"), body.index(".scaleEffect(motion.scale)"),
                        "an overlay applied after the move would stay put while the pet hops")


class NothingElseWasTouched(unittest.TestCase):
    """macOS only: no iOS app, no cards — and the host only where the `ask` route must route it.

    The pet used to be invisible to `hermeyd/` entirely. Fast pet asks changed that by one
    constant: the balloon's sender is now a routing key in `bot_message.rs`, and the test below
    pins that to being the whole of it.
    """

    def test_new_files_are_all_in_the_mac_target(self):
        for name in ("DesktopPetPanel.swift", "PetView.swift", "PetBalloonView.swift",
                     "PetSettings.swift", "DesktopPetController.swift",
                     "PetCalloutPlacement.swift", "PetBadge.swift", "PetWindowPresence.swift"):
            path = PETS / name
            self.assertTrue(path.is_file(), f"{name} is missing")
            self.assertEqual(PETS, path.parent)
        self.assertEqual([], sorted(p.name for p in PETS.iterdir() if p.suffix != ".swift"),
                         "everything in Pets/ is a Mac source file")
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        self.assertIn("- path: Apps/HermesMac", project,
                      "the folder glob picks up a new file in Pets/ without a project edit")

    def test_the_ios_app_knows_nothing_about_pets(self):
        mobile = ROOT / "Apps" / "HermesMobile"
        for path in mobile.rglob("*.swift"):
            text = path.read_text(encoding="utf-8", errors="ignore")
            for word in ("DesktopPet", "PetSettings", "PetBalloon", "PetGeometry"):
                self.assertNotIn(word, text, f"{path.relative_to(ROOT)} mentions {word}")

    def test_the_host_names_the_pet_only_as_the_ask_sender(self):
        """The pet's whole footprint in the service is one routing key in the `ask` route.

        It used to be none at all. Fast pet asks answer a balloon question in the bot's own bounded
        session instead of the endless conversation, which means `bot_message.rs` has to recognise
        `from: "desktop-pet"` — and that recognition has to be the entire leak. The balloon, the
        geometry, the settings and the ask *call* all stay in the Mac target.
        """
        named = []
        for path in (ROOT / "hermeyd" / "src").rglob("*.rs"):
            text = path.read_text(encoding="utf-8", errors="ignore")
            for word in ("desktop-pet", "desktop_pet"):
                if word in text:
                    named.append((str(path.relative_to(ROOT)), word))
        self.assertEqual(
            [("hermeyd/src/bot_message.rs", "desktop-pet")],
            [entry for entry in named if entry[1] == "desktop-pet"],
            "the pet may be named only by the route that has to route it",
        )
        self.assertEqual([], [entry for entry in named if entry[1] == "desktop_pet"],
                         "the host keeps one spelling of the sender, the one the app sends")
        message = (ROOT / "hermeyd" / "src" / "bot_message.rs").read_text(encoding="utf-8")
        self.assertIn("pet: sender == PET_SENDER", message,
                      "the sender decides the route, not a field a caller could add")

    def test_the_cards_renderer_was_not_changed(self):
        cards = ROOT / "Sources" / "HermesCards"
        for path in cards.rglob("*.swift"):
            text = path.read_text(encoding="utf-8", errors="ignore")
            self.assertNotIn("PetGeometry", text)

    def test_the_diff_touches_nothing_outside_the_mac_target(self):
        changed = _changed_files()
        if changed is None:
            self.skipTest("no git base to compare against")
        # Branch-scoped by nature: the question is "did *the pet* leak out of the Mac app?", so it
        # only has an opinion on a branch that carries pet work. A branch with nothing to do with it
        # (reaction sync, say) edits `hermeyd/` and `Sources/HermesKit/` for its own reasons, and
        # failing here would be a guard against work this file knows nothing about.
        if not any(path.startswith("Apps/HermesMac/Pets/") for path in changed):
            self.skipTest("this branch does not carry the desktop pet")
        # The pet itself is macOS-only, but a branch may carry work on the host's `ask` path: the
        # role it waits for, the session id it polls, the profiles directory it opens, the timestamp
        # it anchors on — and, since fast pet asks, the one `pet_sessions` row the balloon's own
        # bounded session hangs off. Those are the only host files allowed here; anything else
        # appearing under `hermeyd/` means the pet leaked into the service.
        host_ask_fix = {
            "hermeyd/src/bot_message.rs",
            "hermeyd/src/store.rs",
            "hermeyd/Cargo.toml",
            "hermeyd/Cargo.lock",
        }
        # The pet also draws a bot's own avatar now, and that feature is deliberately both apps plus
        # the host's validator — so those paths are named here rather than the guard being dropped.
        # Anything else under the phone app or `hermeyd/` is still the pet leaking.
        avatar_feature = {
            # host: validate a definition, store it on the face the pet already reads
            "hermeyd/src/bot_avatar.rs",
            "hermeyd/src/bridge_routes.rs",
            "hermeyd/src/main.rs",
            # phone: the same editor, on the same avatar document
            "Apps/HermesMobile/App/AppEnvironment.swift",
            "Apps/HermesMobile/HermesMobileApp.swift",  # the root injects the avatar library
            "Apps/HermesMobile/Views/BotIconPicker.swift",
            "Apps/HermesMobile/Views/BotListScreen.swift",
            "Apps/HermesMobile/Views/BotModelSettingsScreen.swift",
            "Apps/HermesMobile/Views/BotSettingsDoor.swift",
            "Apps/HermesMobile/Views/ConversationScreen.swift",
            "Apps/HermesMobile/Views/LiveActivityCoordinator.swift",
        }
        allowed = host_ask_fix | avatar_feature
        offending = sorted(
            path for path in changed
            if path.startswith("Sources/HermesCards/")
            or (
                path.startswith("Apps/HermesMobile/") or path.startswith("hermeyd/")
            ) and path not in allowed
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


class TheComposerNamesTheBot(unittest.TestCase):
    """The Mac's empty composer says "Message Cody", the same words the phone shows."""

    def test_the_placeholder_names_the_selected_bot(self):
        self.assertIn('placeholder: "Message \\(composerTitle)"', COMPOSER)
        self.assertNotIn('placeholder: ""', COMPOSER,
                         "an empty placeholder was the complaint: nothing told you who you were writing to")

    def test_the_title_falls_back_to_the_host(self):
        self.assertIn("model.selectedBot?.displayName ?? model.hostName", COMPOSER)
