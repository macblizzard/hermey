"""Desktop pets, polished: the callout with a tail, the floating shadow, blinking, and the click.

Four changes the owner asked for after using 0.1.626/0.1.627, each pinned here as a source guard,
because CI is the only Swift compiler this repo has:

* the balloon is a semi-transparent *white callout* with a tail that points at the pet — not the
  theme-coloured rounded rect it shipped as, and not a white rect that would take its text colour
  from the app's dark theme;
* the icon carries its own drop shadow, so it reads as floating, and the shadow is not hit area;
* the pet blinks on its own 3–9 s clock as a vertical squash, gentled under Reduce Motion;
* a click hops and double-blinks *as* the balloon opens — never before it, never delaying it.

The hit test is asserted here too: a shadow, a tail and a blink must not move the boundary between
"the pet" and "the desktop", which is `PetIconMask` and nothing else.

`Tests/test_desktop_pets.py` still owns the window, the settings and the ask route; nothing in this
file repeats those.
"""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PETS = ROOT / "Apps" / "HermesMac" / "Pets"

PANEL = (PETS / "DesktopPetPanel.swift").read_text(encoding="utf-8")
VIEW = (PETS / "PetView.swift").read_text(encoding="utf-8")
BALLOON = (PETS / "PetBalloonView.swift").read_text(encoding="utf-8")
CONTROLLER = (PETS / "DesktopPetController.swift").read_text(encoding="utf-8")


def _tap_branch() -> str:
    """The body of `onEnded`'s else arm: what a plain click does, in order."""
    ended = VIEW.split(".onEnded { value in", 1)[1]
    return ended.split("isDragging = false", 1)[0]


class TheBalloonIsAWhiteCallout(unittest.TestCase):
    """Semi-transparent white over the desktop, with the wallpaper showing through it."""

    def test_the_sheet_is_white_at_eighty_two_per_cent(self):
        self.assertIn("static let body = Color.white.opacity(0.82)", BALLOON,
                      "the bubble is off-white, not the theme's sheet colour")

    def test_the_wallpaper_shows_through(self):
        self.assertIn(".fill(.ultraThinMaterial)", BALLOON,
                      "the material blurs what is behind the window; the white sits on top of it")
        self.assertIn(".overlay(silhouette.fill(PetBalloonInk.body))", BALLOON,
                      "the white and the material have to be the same silhouette, or the tail "
                      "blurs differently from the card")

    def test_the_old_theme_tinted_fill_is_gone(self):
        self.assertNotIn("Tokens.sheet.opacity(0.72)", BALLOON,
                         "a theme sheet colour over a photo is the 'pasted on' look the owner "
                         "asked to replace")

    def test_the_balloon_forces_a_light_scheme_inside_itself(self):
        self.assertIn(".environment(\\.colorScheme, .light)", BALLOON,
                      "the app's theme is dark; the bubble is white paper and has to say so")
        self.assertIn("appearance = NSAppearance(named: .aqua)", BALLOON,
                      "the field's insertion point and scrollers are drawn by AppKit for the "
                      "window's appearance, not by SwiftUI")

    def test_the_text_is_pinned_ink_rather_than_theme_colour(self):
        # `Tokens` follows ThemeRuntime, not `colorScheme`, so a dark theme would put near-white
        # text on white paper: the reason the balloon has its own palette.
        self.assertIn("enum PetBalloonInk", BALLOON)
        for banned in ("foregroundStyle(Tokens.textPrimary)",
                       "foregroundStyle(Tokens.textSecondary)",
                       "foregroundStyle(Tokens.textMuted)"):
            self.assertNotIn(banned, BALLOON, f"the balloon still reads {banned} for its text")
        for ink in ("PetBalloonInk.primary", "PetBalloonInk.muted", "PetBalloonInk.danger"):
            self.assertIn(ink, BALLOON)

    def test_the_field_thinking_and_answers_are_untouched(self):
        self.assertIn(".disabled(!model.state.acceptsInput)", BALLOON)
        self.assertIn('Text("Thinking…")', BALLOON)
        self.assertIn("SpinningRing(color: PetBalloonInk.muted", BALLOON)
        self.assertIn('CalloutButton("Retry") { model.retry() }', BALLOON)
        self.assertIn('CalloutButton(copied ? "Copied" : "Copy")', BALLOON)
        self.assertIn("setString(text, forType: .string)", BALLOON, "Copy still copies")
        self.assertIn(".frame(maxHeight: 240)", BALLOON)


class TheTailPointsAtThePet(unittest.TestCase):
    """A triangle, part of the card's own outline, aimed at the icon under it."""

    def test_the_shape_is_one_closed_outline(self):
        tail = BALLOON.split("struct PetBalloonShape", 1)[1].split("// MARK: - The balloon", 1)[0]
        self.assertIn("func path(in rect: CGRect) -> Path", tail)
        self.assertEqual(tail.count("closeSubpath()"), 1, "one subpath, one winding")
        self.assertEqual(tail.count("path.move(to:"), 1)
        self.assertNotIn("addPath(", tail, "a second subpath could cut a hole in the body")
        self.assertIn("InsettableShape", BALLOON, "`strokeBorder` needs the inset, not a centred "
                                                  "stroke that would hang off the edge")

    def test_the_tail_hangs_below_the_card_and_narrows_to_a_point(self):
        tail = BALLOON.split("func path(in rect: CGRect) -> Path", 1)[1]
        self.assertIn("let bottom = box.maxY - tail", tail,
                      "everything below the card's bottom edge is the point")
        self.assertIn("path.addLine(to: CGPoint(x: centre, y: box.maxY))", tail,
                      "the point is the lowest thing in the view, which is toward the pet")
        self.assertIn("var tailHeight: CGFloat = PetCalloutMetrics.tailHeight", BALLOON)
        self.assertIn("static let tailHeight: CGFloat = 9", BALLOON)
        self.assertIn("static let tailWidth: CGFloat = 18", BALLOON)

    def test_the_content_leaves_room_for_the_point(self):
        self.assertIn(".padding(.bottom, PetCalloutMetrics.tailHeight)", BALLOON,
                      "text must not run into the tail")

    def test_the_tail_follows_the_pet_not_the_middle_of_the_bubble(self):
        self.assertIn("final class PetBalloonAnchor: ObservableObject", BALLOON)
        self.assertIn("PetBalloonShape(tailCentre: anchor.petCentre)", BALLOON)
        place = BALLOON.split("private func place()", 1)[1]
        self.assertIn("let fraction = (anchorFrame.midX - rect.x) / rect.width", place,
                      "the pet's centre, in the balloon's own coordinates")
        self.assertIn("anchorModel.petCentre = min(max(fraction, 0), 1)", place)

    def test_the_tail_is_kept_clear_of_the_rounded_corners(self):
        tail = BALLOON.split("func path(in rect: CGRect) -> Path", 1)[1]
        self.assertIn("let centre = min(max(box.minX + box.width * tailCentre", tail)
        self.assertIn("box.minX + radius + half", tail)
        self.assertIn("box.maxX - radius - half", tail)


class ThePetFloats(unittest.TestCase):
    def test_the_icon_carries_its_own_shadow(self):
        self.assertIn(".shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 6)", VIEW)

    def test_the_shadow_is_drawn_inside_the_clear_window(self):
        # A window shadow follows the window's rectangle; the panel must keep declining one, or the
        # pet gets a grey square around a blob.
        self.assertIn("hasShadow = false", PANEL)
        self.assertIn("isOpaque = false", PANEL)
        self.assertIn("backgroundColor = .clear", PANEL)

    def test_the_shadow_is_not_hit_area(self):
        # The mask decides, and it knows nothing about anything drawn outside the ink.
        hit = PANEL.split("override func hitTest", 1)[1].split("override func acceptsFirstMouse", 1)[0]
        self.assertIn("guard let iconMask", hit)
        self.assertIn("iconMask.hasInk(at: iconPoint)", hit)
        self.assertNotIn("shadow", hit.lower(),
                         "the hit test cannot know the shadow exists")
        self.assertIn("pet.hitView.iconMask?.hasInk(at: local) == true", CONTROLLER,
                      "the window-level pass-through still asks the alpha mask")
        self.assertIn("contentShape(Circle())", VIEW,
                      "the gesture's own shape stays the icon's circle, not the shadow's reach")


class ThePetBlinks(unittest.TestCase):
    def test_the_blink_is_a_vertical_squash_and_a_lift(self):
        self.assertIn("static let shut = PetBlink(squash: 0.90, lift: 0.06)", VIEW)
        self.assertIn(".scaleEffect(x: 1, y: lid.squash, anchor: .center)", VIEW)
        self.assertIn(".brightness(lid.lift)", VIEW)
        self.assertNotIn(".rotationEffect(.degrees(lid", VIEW, "a blink is not a tilt")

    def test_the_timer_is_three_to_nine_seconds_and_per_pet(self):
        self.assertIn("Double.random(in: 3...9)", VIEW)
        self.assertIn(".task(id: pet.isVisible) { await blinkLoop() }", VIEW,
                      "the blink runs on the panel's visibility, like the idle loop")
        loop = VIEW.split("private func blinkLoop()", 1)[1].split("private func blink(times:", 1)[0]
        self.assertIn("pet.isVisible", loop, "an occluded pet must not keep a timer alive")
        self.assertIn("Task.isCancelled", loop)

    def test_the_blink_is_one_hundred_and_ten_milliseconds(self):
        self.assertIn("static let duration: Double = 0.11", VIEW)
        blink = VIEW.split("private func blink(times:", 1)[1].split("// MARK: - The click", 1)[0]
        self.assertEqual(blink.count(".easeInOut(duration: PetBlink.duration)"), 2,
                         "down and back, at the same speed")

    def test_reduce_motion_gentles_the_blink(self):
        self.assertIn("static let gentle = PetBlink(squash: 0.97, lift: 0)", VIEW)
        blink = VIEW.split("private func blink(times:", 1)[1].split("// MARK: - The click", 1)[0]
        self.assertIn("NSWorkspace.shared.accessibilityDisplayShouldReduceMotion", blink)
        self.assertIn("let shut = reduceMotion ? PetBlink.gentle : PetBlink.shut", blink,
                      "Reduce Motion keeps the blink, at half the depth and with no lift")


class TheClickReactsBeforeTheBalloon(unittest.TestCase):
    def test_the_reaction_starts_in_the_click_handlers_own_turn(self):
        tap = _tap_branch()
        self.assertIn("beginClickReaction()", tap)
        self.assertIn("onOpen()", tap)
        self.assertLess(tap.index("beginClickReaction()"), tap.index("onOpen()"),
                        "the hop is committed first; the balloon opens on the next line")
        between = tap[tap.index("beginClickReaction()"):tap.index("onOpen()")]
        self.assertNotIn("sleep", between, "the balloon is never delayed by the reaction")
        self.assertNotIn("await", between, "an await here would let the balloon wait")

    def test_the_reaction_is_a_small_hop_and_a_double_blink(self):
        reaction = VIEW.split("private func beginClickReaction()", 1)[1]
        self.assertIn("PetMotion(offset: CGSize(width: 0, height: -6), scale: 1.03)", reaction)
        self.assertIn("await blink(times: reduceMotion ? 1 : 2)", reaction)
        self.assertLess(reaction.index("withAnimation(.easeOut(duration: 0.16))"),
                        reaction.index("await blink(times:"),
                        "the hop is the first thing on the next frame")
        self.assertIn("withAnimation(.easeInOut(duration: 0.28)) { motion = .rest }", reaction,
                      "the hop comes back down after the blinks")

    def test_reduce_motion_takes_the_hop_and_the_second_blink(self):
        reaction = VIEW.split("private func beginClickReaction()", 1)[1]
        self.assertIn("if !reduceMotion {", reaction)
        self.assertIn("NSWorkspace.shared.accessibilityDisplayShouldReduceMotion", reaction)

    def test_the_reaction_does_not_replace_the_answer_hop(self):
        self.assertIn(".onChange(of: pet.celebrations)", VIEW)
        self.assertIn("Task { await play(.hop) }", VIEW)


class TheRestIsStillInPlace(unittest.TestCase):
    def test_one_panel_per_pet_and_its_menu(self):
        self.assertIn('Button("Close pet", role: .destructive) { onClose() }', VIEW)
        self.assertIn("static let shared = DesktopPetController()", CONTROLLER)
        self.assertIn("let panel: DesktopPetPanel", CONTROLLER)
        self.assertIn("private var pets: [String: PetInstance] = [:]", CONTROLLER,
                      "one instance per bot, not one window for all of them")

    def test_dragging_still_wins_over_a_click(self):
        tap = _tap_branch()
        self.assertIn("if isDragging {", tap)
        self.assertLess(tap.index("if isDragging {"), tap.index("beginClickReaction()"),
                        "a drag must never fire the reaction or the balloon")

    def test_the_balloon_keeps_its_escape_and_its_own_window(self):
        self.assertIn("event.keyCode == 53", BALLOON)
        self.assertIn("NSWindow.Level.floating.rawValue + 1", BALLOON)
        self.assertIn("PetGeometry.above(", BALLOON)

    def test_the_balloon_window_is_still_only_as_big_as_its_content(self):
        self.assertIn("hosting.sizingOptions = [.preferredContentSize]", BALLOON)
        self.assertIn("NSHostingView(rootView: PetBalloonView(", BALLOON)


if __name__ == "__main__":
    unittest.main()
