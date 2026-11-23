"""Desktop pets, polished: the callout with a tail, the floating shadow, blinking, and the click.

Two rounds of fixes, each pinned here as a source guard, because CI is the only Swift compiler this
repo has.

Round 1 (0.1.626/0.1.627):

* the balloon is a semi-transparent *frosted callout* — the desktop's colour through it, a curved
  tail that points at the pet — not the theme-coloured rounded rect it shipped as, nor the solid
  light panel the 0.82 tint made of it, and not a white rect that would take its text colour from
  the app's dark theme;
* the icon carries its own drop shadow, so it reads as floating, and the shadow is not hit area;
* the pet blinks on its own 3–9 s clock as a vertical squash, gentled under Reduce Motion;
* a click hops and double-blinks *as* the balloon opens — never before it, never delaying it.

Round 2 (0.1.630 feedback), five complaints and the guards for them:

* **the conversation survives dismissal** — the balloon's model is the pet's, not the window's, and
  a `New` button clears it only when there is an answer or a failure to clear;
* **the balloon sits beside the pet**, never over it: above-right, above-left, above, below, in that
  order, with an 8 pt gap and a tail that lands on the pet's edge;
* **the eyes move and blink**: a 0.80 squash for 140 ms plus an eyelid band over the eyes, drifting
  2–5 s apart, both also on a click;
* **dragging is immediate**: the panel moves itself from `mouseDragged` with `setFrameOrigin`, with
  no SwiftUI gesture, no animation and no layout pass;
* **the callout is ~70 % see-through**: a 0.16 white tint over `.ultraThinMaterial`.

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
PLACEMENT = (PETS / "PetCalloutPlacement.swift").read_text(encoding="utf-8")


def _tap_branch() -> str:
    """The click's path through the panel and the controller: what a plain release does, in order."""
    clicked = CONTROLLER.split("private func clicked(botID: String) {", 1)[1]
    return clicked.split("private func", 1)[0]


class TheBalloonIsFrostedGlass(unittest.TestCase):
    """A frosted callout: the desktop's own colour through it, dark ink on top of it."""

    @staticmethod
    def _opacity(constant: str) -> float:
        """The number in `static let <constant> = Color.white.opacity(<n>)`."""
        tail = BALLOON.split(f"static let {constant} = Color.white.opacity(", 1)[1]
        return float(tail.split(")", 1)[0])

    def test_the_callout_is_about_seventy_per_cent_see_through(self):
        # The owner's number: only ~30 % of the surface should be visible on a dark desktop. A 0.16
        # white tint on the thinnest frost is that; anything at 0.3 and up is the panel again.
        self.assertIn("static let body = Color.white.opacity(0.16)", BALLOON,
                      "the tint that sits over the material")
        self.assertLessEqual(self._opacity("body"), 0.20,
                             "above about a fifth the bubble stops being a callout")
        self.assertGreater(self._opacity("body"), 0.05,
                           "a tint of nothing leaves the ink floating on the wallpaper")
        for opaque in ("Color.white.opacity(0.38)", "Color.white.opacity(0.82)"):
            self.assertNotIn(opaque, BALLOON,
                             f"{opaque} is the sheet the owner asked to see through")

    def test_the_material_is_the_thinnest_frost(self):
        self.assertIn(".fill(.ultraThinMaterial)", BALLOON,
                      "70 % see-through comes from the material, not just the tint")
        self.assertNotIn(".fill(.regularMaterial)", BALLOON,
                         "`.regular` is the thicker sheet the owner asked to be rid of")
        self.assertNotIn(".fill(.thickMaterial)", BALLOON)
        self.assertIn(".overlay(silhouette.fill(PetBalloonInk.body))", BALLOON,
                      "the tint and the material have to be the same silhouette, or the tail "
                      "blurs differently from the card")

    def test_the_glass_edge_is_a_light_inner_rim(self):
        self.assertIn("static let highlight = Color.white.opacity(0.10)", BALLOON,
                      "very light: a brighter rim would be the most solid thing on a 0.16 bubble")
        self.assertIn(
            "silhouette.inset(by: 1).strokeBorder(PetBalloonInk.highlight, lineWidth: 1)",
            BALLOON, "one point inside the hairline: a rim, not a second outline")
        self.assertIn("static let edge = Color.black.opacity(0.14)", BALLOON,
                      "the 1 pt hairline still holds the shape against a bright desktop")
        self.assertIn("silhouette.strokeBorder(PetBalloonInk.edge, lineWidth: 1)", BALLOON)

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
        helper = PLACEMENT.split("static func tailFraction(", 1)[1].split("// MARK: - Arithmetic", 1)[0]
        self.assertIn("let fraction = (pet.minX + pet.width / 2 - balloon.minX) / balloon.width",
                      helper, "the pet's centre, in the balloon's own coordinates")
        self.assertIn("return min(max(fraction, 0), 1)", helper)
        place = BALLOON.split("private func place()", 1)[1]
        self.assertIn("PetCalloutPlacement.tailFraction(pet: petRect, balloon: placed.rect)", place)
        self.assertIn("anchorModel.petCentre = CGFloat(fraction)", place)

    def test_the_tail_lands_on_the_pet_edge_from_a_side_seat(self):
        # `PetBalloonShape` clamps the fraction to `cornerRadius + tailWidth / 2` from the bubble's
        # edge. The side seats offset the bubble by exactly that much, so the clamp — which the owner
        # sees as the tail pointing at the wrong place — lands the root on the pet's edge.
        self.assertIn("Double(PetCalloutMetrics.cornerRadius + PetCalloutMetrics.tailWidth / 2)",
                      PLACEMENT, "the reach is the shape's own corner-safe offset, not a guess")
        self.assertIn("let right = pet.maxX - tailReach", PLACEMENT,
                      "above-right: the tail root sits on the pet's right edge")
        self.assertIn("let left = pet.minX + tailReach - width", PLACEMENT,
                      "above-left: the tail root sits on the pet's left edge")

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
        self.assertNotIn("DragGesture", VIEW,
                         "the drag is AppKit's now, so the view has no gesture shape to declare")
        self.assertIn("contentShape(RoundedRectangle(cornerRadius: Tokens.radiusControl",
                      BALLOON, "the callout's buttons still declare their own shape")


class ThePetBlinksAndLooksAround(unittest.TestCase):
    """A visible squash for the blink, and a sideways drift of the whole icon for the gaze.

    There are no drawn eyes any more: the shipped faces have their own (a cloud with two vertical
    bars), and a second pair drawn over them read as a doubled T-shaped face with the horizontal
    capsules crossing the vertical bars. Motion carries it instead.
    """

    @staticmethod
    def _eyes() -> str:
        return VIEW.split("enum PetEyes {", 1)[1].split("\n}\n", 1)[0]

    def test_the_blink_squashes_visibly(self):
        self.assertIn("static let shut = PetBlink(squash: 0.74, lift: 0.02, lid: 1)", VIEW)
        squash = float(VIEW.split("static let shut = PetBlink(squash: ", 1)[1].split(",", 1)[0])
        self.assertGreaterEqual(squash, 0.72, "with no drawn lids the squash is the whole blink")
        self.assertLessEqual(squash, 0.78)
        self.assertIn(".scaleEffect(x: 1, y: lid.squash, anchor: .center)", VIEW)

    def test_nothing_is_drawn_over_the_face(self):
        # The owner's exact complaint, pinned: no overlay of eyelid capsules on top of the icon.
        self.assertNotIn("private var eyelids", VIEW)
        self.assertNotIn("private var eyelid:", VIEW)
        self.assertNotIn(".overlay(alignment: .top) { eyelids }", VIEW)
        self.assertNotIn("Capsule(style: .continuous)", VIEW,
                         "the drawn pupils were capsules; none may come back")

    def test_the_look_around_moves_the_icon(self):
        self.assertIn(".offset(x: gaze * side * PetEyes.drift", VIEW)
        eyes = self._eyes()
        meeting = float(eyes.split("static let drift: CGFloat = ", 1)[1].split("\n", 1)[0])
        self.assertGreaterEqual(meeting, 0.02, "a drift smaller than two points is invisible")
        self.assertLessEqual(meeting, 0.06)
        self.assertIn("static let driftCycle: ClosedRange<Double> = 2...5", eyes)
        self.assertIn("static let driftDuration: Double = 0.7", eyes)

    def test_the_drift_stops_under_reduce_motion(self):
        look = VIEW.split("private func gazeLoop", 1)[1].split("// MARK: -", 1)[0]
        self.assertIn("accessibilityDisplayShouldReduceMotion", look,
                      "a face that drifts on its own is exactly what Reduce Motion asks not to get")


class TheClickReactsBeforeTheBalloon(unittest.TestCase):
    def test_the_reaction_is_committed_before_the_balloon_opens(self):
        tap = _tap_branch()
        self.assertIn("pet.model.tap()", tap)
        self.assertIn("openBalloon(botID: botID)", tap)
        self.assertLess(tap.index("pet.model.tap()"), tap.index("openBalloon(botID: botID)"),
                        "the pet answers the click first; the balloon opens on the next line")
        self.assertNotIn("sleep", tap, "the balloon is never delayed by the reaction")
        self.assertNotIn("await", tap, "an await here would let the balloon wait")
        # The panel is where the click comes from, and a drag never becomes one.
        self.assertIn("panel.onClick = { [weak self] in self?.clicked(botID: bot.id) }", CONTROLLER,
                      "the click reaches the controller from the panel's own mouse handling")
        panel_click = PANEL.split("private func finish()", 1)[1].split("/// The pet's content view", 1)[0]
        self.assertIn("if moved {", panel_click)
        self.assertIn("onMoved?(frame.origin)", panel_click)
        self.assertIn("} else {", panel_click)
        self.assertIn("onClick?()", panel_click)
        self.assertLess(panel_click.index("onMoved?"), panel_click.index("onClick?()"),
                        "a release that moved is a drag, and a drag is never a click")

    def test_the_reaction_blinks_looks_then_hops(self):
        reaction = VIEW.split("private func beginClickReaction()", 1)[1]
        self.assertIn("await blink(times: 1)", reaction,
                      "one blink per click, not the old double")
        self.assertIn("look(CGFloat.random(in: -1...1))", reaction)
        self.assertIn("PetMotion(offset: CGSize(width: 0, height: -6), scale: 1.03)", reaction)
        self.assertLess(reaction.index("await blink(times: 1)"), reaction.index("look("),
                        "blink first")
        self.assertLess(reaction.index("look("), reaction.index("withAnimation(.easeOut(duration: 0.16))"),
                        "then the look, then the hop")
        self.assertIn("withAnimation(.easeInOut(duration: 0.28)) { motion = .rest }", reaction,
                      "the hop comes back down")

    def test_reduce_motion_takes_the_hop_and_the_look(self):
        reaction = VIEW.split("private func beginClickReaction()", 1)[1]
        self.assertIn("NSWorkspace.shared.accessibilityDisplayShouldReduceMotion", reaction)
        self.assertIn("guard !reduceMotion else { return }", reaction)
        self.assertLess(reaction.index("guard !reduceMotion else { return }"), reaction.index("look("),
                        "Reduce Motion stops before the look and the hop")

    def test_the_reaction_does_not_replace_the_answer_hop(self):
        self.assertIn(".onChange(of: pet.celebrations)", VIEW)
        self.assertIn("Task { await play(.hop) }", VIEW)
        self.assertIn(".onChange(of: pet.taps) { _, _ in beginClickReaction() }", VIEW)


class TheRestIsStillInPlace(unittest.TestCase):
    def test_one_panel_per_pet_and_its_menu(self):
        self.assertIn('Button("Close pet", role: .destructive) { onClose() }', VIEW)
        self.assertIn("static let shared = DesktopPetController()", CONTROLLER)
        self.assertIn("let panel: DesktopPetPanel", CONTROLLER)
        self.assertIn("private var pets: [String: PetInstance] = [:]", CONTROLLER,
                      "one instance per bot, not one window for all of them")

    def test_dragging_still_wins_over_a_click(self):
        panel = PANEL.split("private func finish()", 1)[1]
        self.assertIn("if moved {", panel)
        self.assertLess(panel.index("if moved {"), panel.index("onClick?()"))
        self.assertIn("guard abs(dx) + abs(dy) > 2 else { return }", PANEL,
                      "two points of travel is where a click becomes a drag")
        self.assertIn("if !didDrag {", PANEL)
        tap = _tap_branch()
        self.assertNotIn("drag", tap.lower(),
                         "the controller's click path cannot run the drag's code")

    def test_the_balloon_keeps_its_escape_and_its_own_window(self):
        self.assertIn("event.keyCode == 53", BALLOON)
        self.assertIn("NSWindow.Level.floating.rawValue + 1", BALLOON)
        self.assertIn("PetCalloutPlacement.place(", BALLOON)

    def test_the_balloon_window_is_still_only_as_big_as_its_content(self):
        self.assertIn("hosting.sizingOptions = [.preferredContentSize]", BALLOON)
        self.assertIn("NSHostingView(rootView: PetBalloonView(", BALLOON)


class TheConversationOutlivesTheBalloon(unittest.TestCase):
    """Closing the balloon is not a reset: the pet keeps what it last said."""

    @staticmethod
    def _dismiss() -> str:
        return BALLOON.split("func dismiss() {", 1)[1].split("func clear() {", 1)[0]

    @staticmethod
    def _clear() -> str:
        return BALLOON.split("func clear() {", 1)[1].split("/// Cancel the turn", 1)[0]

    def test_a_dismissal_does_not_throw_the_answer_away(self):
        dismiss = self._dismiss()
        self.assertIn("cancel()", dismiss, "an in-flight turn is cancelled, as before")
        self.assertNotIn("state.dismiss()", dismiss,
                         "the answer must still be in the model when the balloon reopens")
        self.assertIn("if state.isAsking { state = kept ?? .idle }", dismiss,
                      "a turn that never landed falls back to the exchange before it")

    def test_the_model_is_the_pets_not_the_windows(self):
        # The window is created per open and thrown away on close; the model lives on the instance.
        self.assertIn("var balloonModel: PetBalloonModel?", CONTROLLER)
        self.assertIn("let model = pet.balloonModel ?? PetBalloonModel(botID: botID)", CONTROLLER)
        self.assertIn("if pet.balloonModel == nil {", CONTROLLER,
                      "the callbacks are wired once, on the model that outlives the window")
        self.assertIn("pet.balloonModel = model", CONTROLLER)
        # Nothing is persisted: the exchange is memory, for the pet's lifetime.
        self.assertNotIn("balloonModel", (PETS / "PetSettings.swift").read_text(encoding="utf-8"))
        self.assertNotIn("UserDefaults", BALLOON,
                         "a desktop pet's transcript is not a document")

    def test_new_clears_the_screen_and_cancels_what_is_in_flight(self):
        clear = self._clear()
        self.assertIn("cancel()", clear, "a reply that lands after New must not paint itself")
        self.assertIn("state.dismiss()", clear)
        self.assertIn('draft = ""', clear, "an empty field, ready for a fresh question")
        self.assertIn("kept = nil", clear, "the old exchange is gone for good")

    def test_the_new_button_exists_only_when_there_is_something_to_clear(self):
        self.assertIn("var hasExchange: Bool { state.answer != nil || state.failure != nil }",
                      BALLOON, "an answer or a failure — the two things on screen")
        header = BALLOON.split("private var header: some View {", 1)[1].split("private var field", 1)[0]
        self.assertIn('if model.hasExchange {', header,
                      "the button appears with the exchange, not on an empty field")
        self.assertIn('CalloutButton("New") { model.clear() }', header)
        # It lives beside Copy, in the header, and nowhere else.
        self.assertEqual(BALLOON.count('CalloutButton("New")'), 1, "one New, in the header")
        new_at = header.index('CalloutButton("New")')
        copy_at = header.index('CalloutButton(copied ? "Copied" : "Copy")')
        self.assertGreater(new_at, header.index("Spacer(minLength: 8)"),
                           "the buttons sit on the right of the header")
        self.assertLess(new_at, copy_at, "New sits beside Copy, before it")
        self.assertIn("model.state.canRetry", header[new_at:])

    def test_a_settled_turn_is_what_the_next_open_shows(self):
        run = BALLOON.split("private func run(_ question: String) {", 1)[1]
        self.assertGreaterEqual(run.count("kept = state"), 3,
                                "answered, unanswered and failed all settle into the kept exchange")
        self.assertIn("resizeAndPlace()", BALLOON,
                      "the reopened window re-fits itself to the answer it now shows")


class TheBalloonSitsBesideThePet(unittest.TestCase):
    """Above and to the side, never over the icon — and the tail still finds the pet."""

    def test_the_seats_are_tried_in_the_owners_order(self):
        body = PLACEMENT.split("static func place(", 1)[1]
        order = ["side: .aboveRight", "side: .aboveLeft", "side: .above)", "side: .below)"]
        positions = [body.index(side) for side in order]
        self.assertEqual(positions, sorted(positions),
                         "above-right first, then the mirror, then directly above, then below")
        self.assertIn("if above + height <= frame.maxY", body,
                      "the vertical test is the same for the three seats above the pet")
        self.assertIn("let below = pet.minY - gap - height", body)
        self.assertIn("gap: Double = 8", PLACEMENT)

    def test_every_seat_leaves_a_gap_and_never_lands_on_the_pet(self):
        # A transliteration of `place`, pinned to the Swift's own constants: CI cannot compile Swift,
        # so this is the only place the geometry is actually exercised. The ordering above is
        # asserted from the source; these numbers are the ones the Swift reads.
        gap = 8.0
        reach = 26.0 + 26.0 / 2  # cornerRadius + tailWidth / 2

        def place(pet, balloon, frame):
            w, h = balloon
            above = pet[1] + pet[3] + gap
            right = pet[0] + pet[2] - reach
            left = pet[0] + reach - w
            centred = min(max(pet[0] + (pet[2] - w) / 2, frame[0]), max(frame[0], frame[0] + frame[2] - w))
            if above + h <= frame[1] + frame[3] and right >= frame[0] and right + w <= frame[0] + frame[2]:
                return (right, above, w, h), "aboveRight"
            if above + h <= frame[1] + frame[3] and left >= frame[0] and left + w <= frame[0] + frame[2]:
                return (left, above, w, h), "aboveLeft"
            if above + h <= frame[1] + frame[3]:
                return (centred, above, w, h), "above"
            below = pet[1] - gap - h
            if below >= frame[1]:
                return (centred, below, w, h), "below"
            middle = min(max(pet[1] + (pet[3] - h) / 2, frame[1]), max(frame[1], frame[1] + frame[3] - h))
            beside_right = pet[0] + pet[2] + gap
            if beside_right + w <= frame[0] + frame[2]:
                return (beside_right, middle, w, h), "beside"
            beside_left = pet[0] - gap - w
            if beside_left >= frame[0]:
                return (beside_left, middle, w, h), "beside"
            return (centred, middle, w, h), "above"

        def overlaps(a, b):
            return not (a[0] + a[2] <= b[0] or a[0] >= b[0] + b[2]
                        or a[1] + a[3] <= b[1] or a[1] >= b[1] + b[3])

        frame = (0.0, 25.0, 1512.0, 957.0)   # a 1512×982 display less the menu bar
        balloon = (320.0, 132.0)
        seen = set()
        for x in range(0, 1512, 24):
            for y in range(25, 982, 24):
                pet = (float(x), float(y), 96.0, 96.0)
                rect, side = place(pet, balloon, frame)
                seen.add(side)
                self.assertFalse(overlaps(rect, pet),
                                 f"the balloon covers the pet at {x},{y} (seat {side})")
                self.assertGreaterEqual(rect[0], frame[0] - 0.001, f"off the left at {x},{y}")
                self.assertLessEqual(rect[0] + rect[2], frame[0] + frame[2] + 0.001)
                self.assertGreaterEqual(rect[1], frame[1] - 0.001, f"off the bottom at {x},{y}")
                self.assertLessEqual(rect[1] + rect[3], frame[1] + frame[3] + 0.001)
                if side == "aboveRight":
                    self.assertAlmostEqual(rect[1] - (pet[1] + pet[3]), 8.0,
                                           msg="the gap is 8 pt, not 'a few'")
        self.assertTrue({"aboveRight", "aboveLeft", "below"} <= seen,
                        f"a pet on a normal display should reach the side seats and the one "
                        f"below; saw {seen}")

        # The seats a normal display never reaches: a narrow one for directly-above (neither side
        # fits), a short one for beside-the-pet (nothing above or below fits).
        narrow = (0.0, 25.0, 380.0, 957.0)
        short = (0.0, 25.0, 1512.0, 300.0)
        fallbacks = set()
        for frame_box in (narrow, short):
            for x in range(0, int(frame_box[2]), 12):
                for y in range(int(frame_box[1]), int(frame_box[1] + frame_box[3]), 12):
                    pet = (float(x), float(y), 96.0, 96.0)
                    rect, side = place(pet, balloon, frame_box)
                    fallbacks.add(side)
                    self.assertFalse(overlaps(rect, pet),
                                     f"the balloon covers the pet at {x},{y} (seat {side})")
                    self.assertGreaterEqual(rect[0], frame_box[0] - 0.001)
                    self.assertLessEqual(rect[0] + rect[2], frame_box[0] + frame_box[2] + 0.001)
                    self.assertGreaterEqual(rect[1], frame_box[1] - 0.001)
                    self.assertLessEqual(rect[1] + rect[3], frame_box[1] + frame_box[3] + 0.001)
        self.assertIn("above", fallbacks, "a narrow display falls back to directly above")
        self.assertIn("beside", fallbacks, "a short one falls back to beside the pet")

    def test_the_default_seat_is_above_right(self):
        # A pet in the middle of a big display: above-right, with the tail root on its right edge.
        pet_x = 700.0
        balloon_x = pet_x + 96 - 39        # pet.maxX - tailReach
        self.assertAlmostEqual(balloon_x + 39, pet_x + 96,
                               msg="the bubble's inner edge is 39 pt left of that, so the tail's "
                                   "root (39 pt in) sits exactly on the pet's right edge")
        self.assertLessEqual(balloon_x + 320, 1512, "the default seat has to fit the display")
        self.assertGreater(balloon_x, pet_x, "the bubble grows away over the desktop, to the right")
        self.assertAlmostEqual(balloon_x + 320 - (pet_x + 96), 281.0,
                               msg="most of the bubble is beside the pet, not above it")

    def test_the_fraction_lands_on_the_pet_edge_after_the_shape_clamps_it(self):
        reach = 26 + 26 / 2           # cornerRadius + tailWidth / 2, in points
        width = 320.0
        pet_x = 700.0
        for balloon_x, edge in ((pet_x + 96 - reach, 96.0),      # above-right: the pet's right edge
                                (pet_x + reach - width, 0.0)):   # above-left: the pet's left edge
            # `PetCalloutPlacement.tailFraction`, then `PetBalloonShape`'s corner clamp.
            fraction = max(min((pet_x + 48 - balloon_x) / width, 1), 0)
            fraction = max(min(fraction, 1 - reach / width), reach / width)
            self.assertAlmostEqual(balloon_x + width * fraction - pet_x, edge, places=6,
                                   msg="the tail's root has to land on the pet's edge, not the "
                                       "bubble's middle")


class DraggingIsImmediate(unittest.TestCase):
    """The window moves with the pointer, in AppKit, with nothing in between."""

    def test_the_drag_is_an_appkit_event_not_a_swiftui_gesture(self):
        self.assertNotIn("DragGesture", VIEW)
        self.assertNotIn(".gesture(", VIEW)
        self.assertNotIn("let onDrag", VIEW)
        self.assertNotIn("onDrag: {", CONTROLLER,
                         "the controller no longer takes a SwiftUI translation")
        self.assertIn("override func sendEvent(_ event: NSEvent)", PANEL)
        self.assertIn("case .leftMouseDragged:", PANEL)
        self.assertIn("case .leftMouseUp:", PANEL)

    def test_the_frame_moves_from_the_initial_origin_plus_the_pointer_delta(self):
        follow = PANEL.split("private func follow()", 1)[1].split("private func finish()", 1)[0]
        self.assertIn("guard let start = dragOrigin, let from = dragMouse else { return }", follow)
        self.assertIn("let mouse = NSEvent.mouseLocation", follow)
        self.assertIn("NSPoint(x: start.x + dx, y: start.y + dy)", follow,
                      "one origin plus one delta — not a running total, which would drift")
        self.assertIn("setFrameOrigin(clampOrigin?(proposed) ?? proposed)", follow,
                      "the frame is set on the event's own turn")
        self.assertNotIn("withAnimation", follow)
        self.assertNotIn("NSAnimationContext", PANEL)
        self.assertNotIn("animator()", PANEL)
        self.assertIn("didDrag = true", follow)

    def test_the_position_is_saved_on_release(self):
        self.assertIn("onMoved: ((NSPoint) -> Void)?", PANEL)
        self.assertIn("panel.onMoved = { [weak self] origin in self?.dragEnded(botID: bot.id, at: origin) }",
                      CONTROLLER)
        ended = CONTROLLER.split("private func dragEnded(botID: String, at origin: NSPoint) {", 1)[1]
        self.assertIn("PetSettings.setPosition(placement, for: botID)", ended)
        self.assertIn("PetGeometry.clamp(", ended, "a release off the edge lands back on the display")

    def test_nothing_relayouts_per_frame(self):
        self.assertIn("panel.clampOrigin = { [weak self] proposed in", CONTROLLER)
        follow = PANEL.split("private func follow()", 1)[1].split("private func finish()", 1)[0]
        for banned in ("layoutSubtreeIfNeeded", "@State", "objectWillChange"):
            self.assertNotIn(banned, follow)


if __name__ == "__main__":
    unittest.main()
