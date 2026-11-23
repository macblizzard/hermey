"""Desktop pets, polished: the callout with a tail, the floating shadow, blinking, and the click.

Four changes the owner asked for after using 0.1.626/0.1.627, each pinned here as a source guard,
because CI is the only Swift compiler this repo has:

* the balloon is a semi-transparent *frosted callout* — the desktop's colour through it, a curved
  tail that points at the pet — not the theme-coloured rounded rect it shipped as, nor the solid
  light panel the 0.82 tint made of it, and not a white rect that would take its text colour from
  the app's dark theme;
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


class TheBalloonIsFrostedGlass(unittest.TestCase):
    """A frosted callout: the desktop's own colour through it, dark ink on top of it."""

    @staticmethod
    def _opacity(constant: str) -> float:
        """The number in `static let <constant> = Color.white.opacity(<n>)`."""
        tail = BALLOON.split(f"static let {constant} = Color.white.opacity(", 1)[1]
        return float(tail.split(")", 1)[0])

    def test_the_white_tint_is_low_and_the_material_does_the_frosting(self):
        self.assertIn("static let body = Color.white.opacity(0.38)", BALLOON,
                      "the tint that sits over the material")
        self.assertLess(self._opacity("body"), 0.5,
                        "at 0.82 the bubble was a solid light panel on a dark desktop; the "
                        "desktop's colour has to come through")
        self.assertNotIn("Color.white.opacity(0.82)", BALLOON)

    def test_the_material_is_raised_to_regular_and_still_shows_the_wallpaper(self):
        self.assertIn(".fill(.regularMaterial)", BALLOON,
                      "the frost carries the contrast, so the tint can stay thin")
        self.assertNotIn(".fill(.ultraThinMaterial)", BALLOON,
                         "the owner asked for the material's opacity role to go up, not down")
        self.assertIn(".overlay(silhouette.fill(PetBalloonInk.body))", BALLOON,
                      "the tint and the material have to be the same silhouette, or the tail "
                      "blurs differently from the card")

    def test_the_glass_edge_is_a_light_inner_rim(self):
        self.assertIn("static let highlight = Color.white.opacity(0.18)", BALLOON)
        self.assertIn(
            "silhouette.inset(by: 1).strokeBorder(PetBalloonInk.highlight, lineWidth: 1)",
            BALLOON, "one point inside the hairline: a rim, not a second outline")
        self.assertIn("silhouette.strokeBorder(PetBalloonInk.edge, lineWidth: 1)", BALLOON,
                      "the hairline still holds the shape against a bright desktop")

    def test_contrast_never_comes_from_thickening_the_sheet(self):
        # The owner's rule for a very dark wallpaper: a faint layer under the text block, never a
        # more opaque bubble.
        self.assertIn("static let backdropContrast = Color.black.opacity(0.07)", BALLOON)
        self.assertIn(".shadow(color: PetBalloonInk.backdropContrast", BALLOON)
        for opaque in ("Color.white.opacity(0.6", "Color.white.opacity(0.7",
                       "Color.white.opacity(0.8", "Color.white.opacity(0.9",
                       ".fill(Color.white)", ".fill(.background)"):
            self.assertNotIn(opaque, BALLOON,
                             f"{opaque} is the solid panel this bubble is not allowed to be")

    def test_the_old_theme_tinted_fill_is_gone(self):
        self.assertNotIn("Tokens.sheet.opacity(0.72)", BALLOON,
                         "a theme sheet colour over a photo is the 'pasted on' look the owner "
                         "asked to replace")

    def test_the_balloon_forces_a_light_scheme_inside_itself(self):
        self.assertIn(".environment(\\.colorScheme, .light)", BALLOON,
                      "the app's theme is dark; the bubble is a light frost and has to say so")
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
        self.assertIn(".fixedSize(horizontal: false, vertical: true)", BALLOON)


class TheAnswerGrowsToACapAndThenScrolls(unittest.TestCase):
    """A two-line reply makes a small bubble; a thirty-line reply stops at 240 pt and scrolls.

    The bubble is sized by `fittingSize` on the hosting view, so anything flexible measures as
    nothing — which is what hid the answer once already. Both branches therefore have a definite
    height: the text's own, or the cap, written down.
    """

    @staticmethod
    def _answer_body() -> str:
        """`answerBody`, from its signature to the text it shares."""
        return (BALLOON.split("private func answerBody(_ answer: String) -> some View {", 1)[1]
                       .split("/// The answer's words", 1)[0])

    @staticmethod
    def _answer_text() -> str:
        """`answerText`: the one rendering both branches draw."""
        return (BALLOON.split("private func answerText(_ answer: String) -> some View {", 1)[1]
                       .split("private var header", 1)[0])

    def test_the_cap_is_240_points_beside_the_tail(self):
        metrics = BALLOON.split("enum PetCalloutMetrics {", 1)[1].split("\n}", 1)[0]
        self.assertIn("static let answerCap: CGFloat = 240", metrics,
                      "one number, in the metrics enum, so the guard can hold it")
        self.assertIn("static let tailHeight: CGFloat = 13", metrics)
        self.assertIn("static let tailWidth: CGFloat = 26", metrics)

    def test_the_answer_is_measured_at_the_width_it_is_drawn_at(self):
        self.assertIn("static var answerWidth: CGFloat { PetBalloonView.width - contentInset * 2 }",
                      BALLOON, "320 pt less the bubble's own padding, not a guessed column count")
        self.assertIn("static let contentInset: CGFloat = 14", BALLOON)
        self.assertIn(".padding(PetCalloutMetrics.contentInset)", BALLOON,
                      "the measured width and the laid-out width have to be the same padding")

    def test_the_height_is_measured_with_the_face_and_size_it_is_drawn_in(self):
        self.assertIn("static func answerHeight(of answer: String) -> CGFloat", BALLOON)
        self.assertIn(
            "NSFont.systemFont(ofSize: TypeScale.pointSize(Tokens.textSM), weight: .regular)",
            BALLOON,
            "the same face TypeScale.font(.system) resolves to, at the same hinted size — so a "
            "⌘+/⌘- step is measured too")
        self.assertIn("NSAttributedString(", BALLOON)
        self.assertIn("with: NSSize(width: answerWidth, height: .greatestFiniteMagnitude)", BALLOON)
        self.assertIn(".usesLineFragmentOrigin", BALLOON)
        self.assertIn("return ceil(bounds.height)", BALLOON,
                      "a fractional height compared against an integer cap must not round down")

    def test_nothing_estimates_the_height_from_the_length_of_the_string(self):
        for guess in ("charactersPerLine", "charsPerLine", "estimatedLines", "count / 4",
                      "lineLimit(40)"):
            self.assertNotIn(guess, BALLOON,
                             "the cap is decided by measuring the text, not by dividing its length")

    def test_the_branch_is_the_measured_height_against_the_cap(self):
        body = self._answer_body()
        self.assertIn(
            "if PetCalloutMetrics.answerHeight(of: answer) > PetCalloutMetrics.answerCap {", body,
            "at or under the cap it draws exactly as before; only over it does it scroll")

    def test_the_scroll_view_has_an_explicit_fixed_height_of_the_cap(self):
        body = self._answer_body()
        self.assertIn("ScrollView(.vertical, showsIndicators: true)", body,
                      "a long answer gets a scroller the owner can see")
        scroll_branch = body.split("} else {", 1)[0]
        self.assertIn(".frame(height: PetCalloutMetrics.answerCap)", scroll_branch,
                      "the height is the cap in points, never a flexible one")
        self.assertNotIn("maxHeight", scroll_branch,
                         "a flexible height is exactly what collapsed the answer to zero")
        self.assertNotIn("minHeight", scroll_branch)
        self.assertNotIn("Spacer", scroll_branch)

    def test_it_is_the_only_scroll_view_in_the_balloon(self):
        self.assertEqual(BALLOON.count("ScrollView("), 1,
                         "the scroll branch and the plain branch are the only two renderings; a "
                         "second, unfixed scroll view would be the old bug again")

    def test_both_branches_draw_the_same_selectable_text(self):
        body = self._answer_body()
        self.assertEqual(body.count("answerText(answer)"), 2,
                         "one rendering, two sizes — short and long answers read the same")
        text = self._answer_text()
        self.assertIn(".textSelection(.enabled)", text, "the answer is selectable in both branches")
        self.assertIn(".fixedSize(horizontal: false, vertical: true)", text,
                      "under the cap it is the self-sizing Text it always was")
        self.assertIn(".multilineTextAlignment(.leading)", text)

    def test_copy_still_copies_the_whole_answer(self):
        # The scroll branch shows a window onto the string; Copy is not limited by it.
        self.assertIn("setString(text, forType: .string)", BALLOON)
        self.assertIn('CalloutButton(copied ? "Copied" : "Copy")', BALLOON)


class TheTailPointsAtThePet(unittest.TestCase):
    """A curved tail, part of the card's own outline, aimed at the icon under it."""

    @staticmethod
    def _flat(text: str) -> str:
        """The Swift source with its wrapping collapsed, so a multi-line call reads as one line."""
        return " ".join(text.split())

    @staticmethod
    def _path() -> str:
        return BALLOON.split("func path(in rect: CGRect) -> Path", 1)[1]

    @staticmethod
    def _tail_path() -> str:
        """The path from the bottom edge into the tail and back: the only curved part that matters."""
        path = TheTailPointsAtThePet._path()
        # Past the travel along the bottom edge, up to the return to the bottom-left corner.
        start = path.index("path.addLine(to: CGPoint(x: rootRight, y: bottom))")
        start = path.index("\n", start)
        end = path.index("path.addLine(to: CGPoint(x: box.minX + radius, y: bottom))")
        return TheTailPointsAtThePet._flat(path[start:end])

    def test_the_shape_is_one_closed_outline(self):
        tail = BALLOON.split("struct PetBalloonShape", 1)[1].split("// MARK: - The balloon", 1)[0]
        self.assertIn("func path(in rect: CGRect) -> Path", tail)
        self.assertEqual(tail.count("closeSubpath()"), 1, "one subpath, one winding")
        self.assertEqual(tail.count("path.move(to:"), 1)
        self.assertNotIn("addPath(", tail, "a second subpath could cut a hole in the body")
        self.assertIn("InsettableShape", BALLOON, "`strokeBorder` needs the inset, not a centred "
                                                  "stroke that would hang off the edge")

    def test_the_tail_is_a_pair_of_quad_curves_leaving_the_bottom_edge(self):
        tail = self._tail_path()
        self.assertEqual(tail.count("addQuadCurve"), 3,
                         "two curves for the sides and one small arc for the tip")
        self.assertNotIn("addLine", tail,
                         "a straight line is the triangle the owner asked to replace")
        # Each side's control point sits on the card's bottom edge, so the curve leaves the body
        # horizontally instead of in a notch.
        self.assertIn("control: CGPoint(x: rootRight - half * PetCalloutMetrics.tailFlare, "
                      "y: bottom)", tail)
        self.assertIn("control: CGPoint(x: rootLeft + half * PetCalloutMetrics.tailFlare, "
                      "y: bottom)", tail)

    def test_the_tip_is_rounded_rather_than_a_sharp_point(self):
        tail = self._tail_path()
        self.assertIn("control: CGPoint(x: centre, y: box.maxY)", tail,
                      "the point is still the lowest ink, which is toward the pet")
        self.assertIn("static let tailTipRadius: CGFloat = 2.4", BALLOON)
        self.assertIn("let tipRadius = min(PetCalloutMetrics.tailTipRadius, half * 0.4)", BALLOON,
                      "the arc has to stay smaller than the tail's own half-width")
        self.assertNotIn("path.addLine(to: CGPoint(x: centre, y: box.maxY))", BALLOON,
                         "the old sharp point is gone")

    def test_the_tail_root_is_26_wide_and_13_long(self):
        metrics = BALLOON.split("enum PetCalloutMetrics {", 1)[1].split("\n}", 1)[0]
        self.assertIn("static let tailHeight: CGFloat = 13", metrics)
        self.assertIn("static let tailWidth: CGFloat = 26", metrics)
        self.assertIn("let rootRight = centre + half", BALLOON)
        self.assertIn("let rootLeft = centre - half", BALLOON)
        self.assertIn("var tailHeight: CGFloat = PetCalloutMetrics.tailHeight", BALLOON)
        self.assertIn("var tailWidth: CGFloat = PetCalloutMetrics.tailWidth", BALLOON)

    def test_the_corner_is_a_bubble_not_a_card(self):
        metrics = BALLOON.split("enum PetCalloutMetrics {", 1)[1].split("\n}", 1)[0]
        self.assertIn("static let cornerRadius: CGFloat = 26", metrics)
        radius = int(metrics.split("static let cornerRadius: CGFloat = ", 1)[1].split("\n", 1)[0])
        self.assertGreaterEqual(radius, 24, "16 read as a rounded rectangle")
        self.assertLessEqual(radius, 28)
        self.assertIn("var cornerRadius: CGFloat = PetCalloutMetrics.cornerRadius", BALLOON)

    def test_the_content_leaves_room_for_the_tail(self):
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
        tail = self._path()
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
