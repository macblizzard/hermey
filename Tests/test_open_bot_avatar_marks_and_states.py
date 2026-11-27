"""open-bot-avatar 0.5.1 ported into the drawn avatar, guarded from the source text.

Upstream 0.5.0 and 0.3.0 are what this follows (`packages/core/CHANGELOG.md`):

* `Pose` lists its **marks as values** — each entry a mark and how far the body has given way to it —
  and a material draws a mark's parts itself, through one `render`, so glass draws them in glass;
* `state` takes a **definition of a host's own** as well as a name: an `id` and a pose that says what
  differs from rest, easing to and from the built-ins, with two definitions of one id being one state;
* `done` **celebrates inside a cage** of nine ribbons on three crossing hoops, rests, then does it again;
* the eyes **morph** from one shape to the next instead of swapping inside a blink;
* under **reduced motion** the ribbons are left out, the marks hold still and `done` does not turn.

What this file refuses, above all, is the one thing the owner corrected twice and that outranks
upstream: **for our eight built-in states no mark may take the face and no state may shrink the body.**
Upstream's `thinking` and `blocked` *are* marks; ours are not, and the mark machinery is for custom
definitions. The numbers below are quoted from upstream where each one comes from, so a port that
drifts from them is a diff a reader can check.

Upstream sources: `packages/core/src/{marks,effects,eyes,motion,mood,animator}.ts` and
`dom/materials/{material,marks}.ts` of github.com/DominikScholz/open-bot-avatar (MIT).
"""
from __future__ import annotations

import math
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AVATAR = ROOT / "Sources" / "HermeyUI" / "OpenBotAvatar"
STATE = AVATAR / "OpenBotAvatarState.swift"
RENDERER = AVATAR / "OpenBotAvatarRenderer.swift"
PAINT = AVATAR / "OpenBotAvatarMaterialPaint.swift"
MARKS = AVATAR / "OpenBotAvatarMarks.swift"
EYES = AVATAR / "OpenBotAvatarEyes.swift"
RIBBONS = AVATAR / "OpenBotAvatarRibbons.swift"
DEFINITIONS = AVATAR / "OpenBotAvatarStateDefinition.swift"
VIEW = AVATAR / "OpenBotAvatarView.swift"
BOT_AVATAR_VIEW = ROOT / "Sources" / "HermeyUI" / "BotAvatarView.swift"
PET = ROOT / "Apps" / "HermesMac" / "Pets" / "PetView.swift"

STATES = ["idle", "thinking", "reading", "working", "computer", "waiting", "blocked", "done"]


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def code(path: Path) -> str:
    """The file with its comments removed: prose naming a symbol is not the symbol."""
    text = read(path)
    # Keep `///` doc comments out too — a doc comment quoting `pose.marks` must not count as code.
    return "\n".join(line.split("//")[0] for line in text.splitlines())


def branch(label: str) -> str:
    """One state's own branch of the pose, with its comments stripped: a guard reads code."""
    source = read(STATE)
    pose = source[source.index("public func pose("):
                  source.index("    /// A state that starts part way through itself")]
    pose = "\n".join(line.split("//")[0] for line in pose.splitlines())
    return pose.split(f"case .{label}:")[1].split("case .")[0]


class APoseCarriesMarksAsValues(unittest.TestCase):
    """`Pose.marks` replaces `Pose.bang` and `Pose.dots`: a mark is a value, not a field of the pose."""

    def test_a_mark_is_an_id_and_a_function_that_lays_its_parts_out(self) -> None:
        marks = code(MARKS)
        self.assertIn("public struct AvatarMark", marks)
        self.assertIn("public let id: String", marks)
        self.assertIn("public let parts: @Sendable (MarkContext) -> [MarkPart]", marks)
        # The part is an outline about its own centre, with a place, a turn and a scale — upstream's
        # `MarkPart` (marks.ts:17-37), including the `round` flag for a ball or an upright capsule.
        self.assertIn("public struct MarkPart", marks)
        for field in ("public var shape: String", "public var path: Path", "public var box: CGRect",
                      "public var x: Double", "public var y: Double", "public var turn: Double",
                      "public var scale: Double", "public var round: Bool"):
            self.assertIn(field, marks)
        # The context a mark is laid out from: a unit, the clock, and whether it holds still.
        self.assertIn("public struct MarkContext", marks)
        for field in ("public var unit: Double", "public var time: Double", "public var still: Bool"):
            self.assertIn(field, marks)

    def test_the_pose_holds_a_list_of_marks_and_no_per_mark_field(self) -> None:
        state = code(STATE)
        self.assertIn("public var marks: [PoseMark] = []", state)
        self.assertIn("public struct PoseMark", MARKS.__str__() and read(MARKS))
        # A mark in a pose: the mark and its weight, in the order of their ids (marks.ts:57).
        self.assertIn("public var mark: AvatarMark", read(MARKS))
        self.assertIn("public var weight: Double", read(MARKS))
        # The old per-mark fields are gone from the pose, and nothing sets them.
        for gone in ("public var bang", "public var dots: [", "pose.bang", "pose.dots"):
            self.assertNotIn(gone, state)

    def test_the_three_dots_and_the_exclamation_mark_are_upstreams(self) -> None:
        marks = read(MARKS)
        # DOTS (marks.ts:91-102): radius 0.1 units, 0.31 apart, a 1.25 s turn with the second and
        # third a beat of 0.17 behind, the hop over the first 0.4, 0.16 up and 12 % larger.
        self.assertIn('static let dots = AvatarMark(id: "dots")', marks)
        for number in ("0.1 * u, step = 0.31 * u", "* 0.17", "1.25", "p < 0.4", "-0.16 * u * hop",
                       "1 + 0.12 * hop"):
            self.assertIn(number, marks, f"dots drifted from marks.ts ({number!r})")
        # BANG (marks.ts:70-88): bar 0.21 × 0.5, stop 0.115, gap 0.1, an alarm every 2.6 s over its
        # first 0.3, a shake of 0.2 at three cycles dying as it lands, 0.09 up, the stop lagging 45 %.
        self.assertIn('static let bang = AvatarMark(id: "bang")', marks)
        for number in ("0.21 * u, barHeight = 0.5 * u", "0.115 * u", "0.1 * u", "2.6", "p < 0.3",
                       "0.2 * sin(2 * .pi * 3 * alarm)", "-0.09 * u * jump", "lift * 0.45"):
            self.assertIn(number, marks, f"bang drifted from marks.ts ({number!r})")

    def test_a_mark_grows_in_as_the_body_gives_way(self) -> None:
        marks = read(MARKS)
        # MARK_FROM 0.45: a mark starts to grow just before the body is gone, so something is always
        # on screen (effects.ts:376-378).
        self.assertIn("static let markFrom = 0.45", marks)
        self.assertIn("smooth((min(1, max(0, weight)) - markFrom) / (1 - markFrom))", marks)
        # The body is gone a little past half way, and the mark is placed from the body's centre.
        self.assertIn("1 - smooth(min(1, max(0, weight)) / 0.55)", marks)
        self.assertIn("placed.x = centre.x + part.x * grow", marks)
        self.assertIn("placed.y = centre.y + part.y * grow", marks)
        self.assertIn("placed.scale = part.scale * grow", marks)

    def test_the_unit_a_mark_is_sized_in_is_upstreams(self) -> None:
        # effects.ts:381 — a share of the body's smaller side, within 34 and 78.
        self.assertIn("min(78, max(34, min(box.width, box.height)))", read(MARKS))


class TheBodyScaleIsTheOneUpstreamFixTakenIn(unittest.TestCase):
    """When an interrupted change would leave the body gone with no mark showing, the body stays."""

    @staticmethod
    def body_scale(marks) -> float:
        """Upstream's `bodyScale` (effects.ts:406), in Python, so the claim can be counted."""
        def smooth(u: float) -> float:
            x = min(1, max(0, u))
            return x * x * (3 - 2 * x)

        def grown(weight: float) -> float:
            return smooth((min(1, max(0, weight)) - 0.45) / 0.55)

        def left(weight: float) -> float:
            return 1 - smooth(min(1, max(0, weight)) / 0.55)

        scale = left(sum(marks))
        return scale if any(grown(w) > 0 for w in marks) else max(scale, left(0.45))

    def test_the_eight_built_in_states_never_shrink_the_body(self) -> None:
        # The built-in poses carry no mark at all, so the body keeps every bit of its size: this is
        # the owner's correction, and it is what `bodyScale([])` returning 1 means.
        self.assertEqual(self.body_scale([]), 1.0)
        source = read(STATE)
        switch = source[source.index("switch self {"):
                        source.index("        // The material's light rides the pose")]
        switch = "\n".join(line.split("//")[0] for line in switch.splitlines())
        self.assertNotIn("pose.marks", switch, "a built-in state handed its face to a mark")
        self.assertNotIn("bodyScale", switch, "a built-in state shrank its body")

    def test_an_interrupted_change_keeps_a_small_body(self) -> None:
        # Three marks at a third each: none is past MARK_FROM, so none shows, and the body must not
        # have gone. Gone reads as ~0 here; the fix keeps it at the size it is when a mark first shows.
        gone = self.body_scale([0.6])                     # one mark nearly home: the body has gone
        interrupted = self.body_scale([0.3, 0.3, 0.3])    # three, none of them showing yet
        self.assertLess(gone, 0.001)
        self.assertGreater(interrupted, 0.05, "an interrupted change left the frame empty")
        self.assertAlmostEqual(interrupted, 1 - self._smooth(0.45 / 0.55), places=6)

    @staticmethod
    def _smooth(u: float) -> float:
        x = min(1, max(0, u))
        return x * x * (3 - 2 * x)

    def test_the_swift_says_the_same_thing(self) -> None:
        marks = code(MARKS)
        body = marks[marks.index("public static func bodyScale(_ marks: [PoseMark]) -> Double"):]
        body = body[:body.index("\n    }")]
        self.assertIn("marks.contains { grown($0.weight) > 0 }", body)
        self.assertIn("max(scale, left(markFrom))", body)
        # And every reader takes the body's size from that one function: the slice stack's shrink in
        # `draw`, and the frame's one transform (`bodyTransform`), so the painted ramp, the shader's
        # box and the mask all shrink together and none re-derives a scale of its own.
        renderer = code(RENDERER)
        self.assertEqual(renderer.count("OpenBotAvatarMarks.bodyScale(pose.marks)"), 2,
                         "the body's size is read somewhere else, or not at all")
        self.assertNotIn("pose.bodyScale", renderer)


class TheMaterialDrawsTheBodyAndTheMarks(unittest.TestCase):
    """One entry point, exactly as upstream's single `render` (dom/materials/material.ts:33-42)."""

    def test_there_is_one_render_and_the_body_and_a_mark_are_shapes_of_it(self) -> None:
        paint = code(PAINT)
        self.assertIn("enum BotAvatarMaterialRender {", paint)
        self.assertEqual(paint.count("static func render("), 1,
                         "a material grew a second entry point (paintMark is back)")
        for shape in ("case slice(path: Path, transform: CGAffineTransform, evenOdd: Bool)",
                      "case silhouette(Path)",
                      "case mark(path: Path, transform: CGAffineTransform, round: Bool)"):
            self.assertIn(shape, paint)
        # The shapes are drawn in order by the one function.
        body = paint[paint.index("static func render("):]
        body = body[:body.index("\n    }\n}")]
        for drawn in ("layer.fill(path, with: .color(tint),", "OpenBotAvatarMaterialPaint.paint(",
                      "let outline = path.applying(transform)"):
            self.assertIn(drawn, body)

    def test_both_materials_draw_a_mark_part(self) -> None:
        paint = code(PAINT)
        entry = paint[paint.index("static func render("):]
        entry = entry[:entry.index("\n    }\n}")]
        mark = entry[entry.index("case .mark("):]
        self.assertIn("case .flat:", mark)
        self.assertIn("context.fill(outline, with: .color(tint))", mark)
        self.assertIn("case .ramp:", mark)
        self.assertIn("OpenBotAvatarMaterialPaint.paint(spec, light: light, backdrop: backdrop,", mark)
        # So a glass bot's mark goes through the same six layers as its body: the ramp, the rim, the
        # contact band. Nothing in the renderer draws a mark itself.
        renderer = code(RENDERER)
        self.assertIn("static func markShapes(", renderer)
        self.assertNotIn("drawMark(", renderer)
        # The marks are drawn through the material, last, over the face (render.ts `flatFrame`).
        marks_call = renderer.split("BotAvatarMaterialRender.render(markShapes(")
        self.assertEqual(len(marks_call), 2, "the marks are not drawn through the material")
        self.assertGreater(renderer.index("BotAvatarMaterialRender.render(markShapes("),
                           renderer.index("drawEyes("), "the marks are under the face")
        # A part that is a ball or a capsule still says so: the material may draw it from a ready ball.
        self.assertIn("round: part.round)", renderer)


class AHostCanDefineAStateOfItsOwn(unittest.TestCase):
    """`state` takes a name or a definition, and both reach the view and the renderer."""

    def test_the_definition_is_an_id_a_pose_and_a_start_age(self) -> None:
        definitions = read(DEFINITIONS)
        self.assertIn("public struct AvatarStateDefinition", definitions)
        for field in ("public let id: String", "public let startAge: Double?",
                      "public let pose: @Sendable (StateContext) -> OpenBotAvatarPose"):
            self.assertIn(field, definitions)
        # What a pose works out from: the clock, the mood, the seed and the calm pose to start from.
        self.assertIn("public struct StateContext", definitions)
        for field in ("public var seed: UInt32", "public var t: Double",
                      "public var stateAge: Double?", "public var live: Double",
                      "public var wave: (Double, Double) -> Double", "public var base: OpenBotAvatarPose",
                      "public var rest: (Double) -> OpenBotAvatarPose"):
            self.assertIn(field, definitions, f"StateContext lost {field!r}")

    def test_a_state_is_a_name_or_a_definition_everywhere_a_state_goes(self) -> None:
        definitions = read(DEFINITIONS)
        self.assertIn("public enum OpenBotAvatarStateChoice: Hashable, Sendable", definitions)
        self.assertIn("case named(OpenBotAvatarState)", definitions)
        self.assertIn("case defined(AvatarStateDefinition)", definitions)
        # The eight names keep their dot shorthand, so a surface that said `.thinking` still can.
        for state in STATES:
            self.assertIn(f"public static let {state} = OpenBotAvatarStateChoice(.{state})", definitions)
        # The view takes the union, and the animator steps it — so a definition is a state on every
        # surface: the list row, the header, the pet and the editor's preview.
        self.assertIn("public var state: OpenBotAvatarStateChoice", read(VIEW))
        self.assertIn("state: OpenBotAvatarStateChoice = .idle", read(VIEW))
        self.assertIn("OpenBotAvatarStateChoice(pet.state)", read(PET))
        self.assertIn("let state = OpenBotAvatarStateChoice(activity: activity)", read(BOT_AVATAR_VIEW))
        self.assertIn("public func step(state: OpenBotAvatarStateChoice,", definitions)

    def test_the_definition_reaches_the_renderer_through_the_pose(self) -> None:
        # The renderer draws whatever pose it is handed, marks and all: there is no second path for a
        # definition, and no place a state's *name* is read while drawing.
        renderer = code(RENDERER)
        for state in STATES:
            self.assertNotIn(f'"{state}"', renderer, f"the renderer reads the state name {state!r}")
            self.assertNotIn(f"case .{state}", renderer)
        self.assertIn("markShapes(pose.marks,", renderer)
        self.assertIn("OpenBotAvatarRibbons.pieces(box: volume.box,", renderer)

    def test_a_definition_eases_to_and_from_the_built_ins(self) -> None:
        definitions = read(DEFINITIONS)
        # 420 ms of smoothstep, upstream's `MOOD_MS` and `moodProgress` (mood.ts:10-20).
        self.assertIn("public static let changeMilliseconds = 420.0", definitions)
        self.assertIn("let x = min(1, max(0, elapsedMilliseconds / changeMilliseconds))", definitions)
        # A change under way is frozen where it got to, so a second change continues from it.
        self.assertIn("static func settled(_ blend: OpenBotAvatarBlend?", definitions)
        self.assertIn("if rest < 0.02 { return [OpenBotAvatarBlend.Step(state: state, mood: mood, age: age)] }", definitions)
        self.assertIn("if chain.count > 3 { chain.removeFirst(chain.count - 3) }", definitions)
        # And a change of mood alone keeps the state's clock, so a turn under way stays one turn.
        self.assertIn("let age = step.state.id == id ? stateAge : step.age", definitions)
        self.assertIn("for step in blend.from {", definitions)
        # The pose is blended channel by channel, the eyes' look and the marks included.
        state = read(STATE)
        blended = state[state.index("public static func blended("):]
        for channel in ("pose.arch = m(a.arch, b.arch)", "pose.slit = m(a.slit, b.slit)",
                        "pose.marks = OpenBotAvatarMarks.blended(a.marks, b.marks, m)"):
            self.assertIn(channel, blended)
        # The ribbons keep the turns the side that shows them had, rather than winding back while they fade.
        self.assertIn("let sweep = a.ribbons > 0 && b.ribbons > 0 ? m(a.sweep, b.sweep)", blended)
        self.assertIn("let cage = a.ribbons > 0 && b.ribbons > 0 ? m(a.cage, b.cage)", blended)

    def test_two_definitions_with_one_id_are_one_state(self) -> None:
        definitions = code(DEFINITIONS)
        equality = definitions[definitions.index("public static func == (left: AvatarStateDefinition"):]
        equality = equality[:equality.index("\n    }")]
        self.assertIn("left.id == right.id", equality)
        # A closure cannot be compared, so nothing else may be: no `pose` in the comparison.
        self.assertNotIn(".pose ==", equality)
        self.assertNotIn("left.pose", equality)
        # The state's identity is its id, wherever one is compared.
        self.assertIn("let sameState = current.state.id == state.id", definitions)
        self.assertIn("public var id: String {", definitions)

    def test_the_definition_keeps_the_resting_pose_it_is_given(self) -> None:
        state = read(STATE)
        # A field a definition gives no usable value for keeps the base's, so a slip cannot empty the
        # frame (motion.ts:517 `laid`).
        laid = state[state.index("public static func laid("):]
        laid = laid[:laid.index("\n    }\n}")]
        self.assertIn("value.isFinite ? value : fallback", laid)
        self.assertIn("pose.marks = OpenBotAvatarMarks.sanitised(given.marks)", laid)
        # And a definition starts from `ctx.base` / `ctx.rest()`, which are the eight's own numbers.
        definitions = read(DEFINITIONS)
        self.assertIn("rest: { pace in", definitions)
        self.assertIn("OpenBotAvatarState.resting(seed: seed, t: t, mood: mood,", definitions)
        self.assertIn("static func resting(seed: UInt32,", read(STATE))


class DoneCelebratesInsideACage(unittest.TestCase):
    """Nine ribbons on three crossing hoops, on upstream's curve and timing."""

    def test_three_ribbons_on_three_hoops(self) -> None:
        ribbons = read(RIBBONS)
        self.assertIn("public static let lanes = 3", ribbons)
        self.assertIn("public static let hoops = 3", ribbons)
        # The cage is three lanes on each of three hoops: nine ribbons, numbered 0…8.
        self.assertIn("for i in 0..<hoopCount {", ribbons)
        self.assertIn("for l in 0..<lanes {", ribbons)
        self.assertIn("ribbon: i * lanes + l", ribbons)
        self.assertEqual(3 * 3, 9)
        # The cage's ring is the largest any of the three hoops needs, so the cage stays round, and
        # its three rolls are a third of a half turn apart (effects.ts:141-144, render.ts `ribbonRims`).
        self.assertIn("hoopRoll + Double(index) * .pi / Double(hoops)", ribbons)
        self.assertIn("(0..<hoops).map { r.at(rollOf($0)) }.max().map { $0 + rimMargin }", ribbons)
        # A celebration is picked by `cage` at or over a half, as upstream's `ribbonPieces` does.
        self.assertIn("let more = cage >= 0.5 ? 1.0 : 0.0", ribbons)
        self.assertIn("pose.cage >= 0.5", read(RENDERER))

    def test_the_hoop_angles_are_upstreams(self) -> None:
        ribbons = read(RIBBONS)
        # effects.ts:159-192 — the tilt out of the screen, the roll in the picture and their jitters,
        # the ring spacing, the arc, the follow and drift, the sizes and the brush.
        for number in ("static let hoopTilt = 0.386", "static let hoopRoll = 0.157",
                       "static let hoopJitter = 0.24", "static let hoopTiltJitter = 0.08",
                       "static let ladder = 38.0", "static let arc: (Double, Double) = (2.2, 3.4)",
                       "static let follow: (Double, Double) = (0.74, 0.94)",
                       "static let drift: (Double, Double) = (0.5, 1.1)", "static let widen = 2.5",
                       "static let brush = 1.7 * 1.98", "static let far = 0.72",
                       "static let rimMargin = 2.0"):
            self.assertIn(number, ribbons, f"a hoop constant drifted ({number!r})")
        # The demo's unit space and the typical body, which make one design unit (effects.ts:59-62).
        self.assertIn("static let design = 228.541", ribbons)
        self.assertIn("static let body = 80.0", ribbons)

    def test_done_turns_a_third_as_often_inside_the_cage(self) -> None:
        done = branch("done")
        self.assertIn("pose.cage = 1", done)
        self.assertIn("pose.yaw += Self.near(sweep / 3)", done)
        self.assertIn("pose.sweep = way * max(0, Self.celebration(since))", done)
        self.assertIn("let way: Double = cycle.truncatingRemainder(dividingBy: 2) != 0 ? -1 : 1", done)
        # Upstream's timing: a 3.87 s turn, a 6.2 s cycle up to a seventh longer per avatar, the
        # ribbons drawn back in over the last half second (motion.ts:215-222).
        self.assertIn("public static let doneTurnSeconds = 3.87", read(STATE))
        self.assertIn("public static let doneCycleSeconds = 6.2", read(STATE))
        self.assertIn("static let doneDrawInSeconds = 0.5", read(STATE))
        self.assertIn("Self.doneCycleSeconds * (1 + 0.15 * Self.noise(seed, 31))", done)
        self.assertIn("Self.doneTurnSeconds - since) / Self.doneDrawInSeconds", done)
        # Nine whole turns by 3.79 s: the curve lands on DONE_SWEEPS, so the cage stops where it began.
        self.assertIn("static let doneSweeps = 9", read(STATE))
        self.assertIn("return Double(doneSweeps) * 2 * .pi", read(STATE))

    def test_the_ribbons_fit_the_frame_and_never_reach_through_the_body(self) -> None:
        """Upstream grows its canvas to the ribbons' reach; our canvas is the frame, so they are fitted.

        The fit is a scale about the hoops' centre — counts, angles, easings and the proportions
        among the ribbons stay upstream's — and it may never put the cage's inner ring inside the
        body. This is the one place the port deliberately differs in geometry, and it is pinned.
        """
        renderer = code(RENDERER)
        self.assertIn("static func ribbonFit(", renderer)
        self.assertIn("let farthest = max(max(rim.cx, 100 - rim.cx), max(rim.cy, 100 - rim.cy))", renderer)
        self.assertIn("let floor = (rim.reach + OpenBotAvatarRibbons.rimMargin) / reach.radius", renderer)
        self.assertIn("return min(1, max(floor, 50 / extent))", renderer)
        # Applied to the ribbon layer, about the hoops' own centre — and to nothing else.
        ribbons = renderer[renderer.index("static func draw(ribbons:"):]
        self.assertIn("layer.transform = scale", ribbons)
        self.assertIn("if fit < 1, let rim {", ribbons)
        eyes = renderer[renderer.index("static func drawEyes("):renderer.index("static func markShapes(")]
        self.assertNotIn("fit", eyes, "the fit reached the eyes")

    def test_ribbons_and_marks_stay_put_while_the_body_moves(self) -> None:
        # Upstream paints both with the root's motion undone (`fixed = invert(root)`), so the cage
        # does not hop with the body. Ours gives them the viewport and the pose's own rim offset.
        renderer = code(RENDERER)
        marks = renderer[renderer.index("BotAvatarMaterialRender.render(markShapes("):]
        self.assertIn("time: time, transform: viewport)", marks)
        self.assertIn("let rim = OpenBotAvatarRibbons.follow(", renderer)
        self.assertIn("lift: pose.lift, sx: pose.sx, sy: pose.sy, box: volume.box)", renderer)

    def test_the_celebration_curve_is_upstreams(self) -> None:
        """Upstream's `celebration` (motion.ts:265), in Python: a wind-up, a run, and a landing."""
        state = read(STATE)
        self.assertIn("static let celebrationEndSeconds = 3.79", state)
        self.assertIn("static let celebrationSpeed = (Double(doneSweeps) * 2 * .pi + 0.5) / 2.4625", state)
        for stop in ("if t < 0.24 { return -0.25 * (1 - cos(.pi * t / 0.24)) }",
                     "if t < 0.54 { return -0.5 + (v * (t - 0.24) * (t - 0.24)) / 0.6 }",
                     "if t < 2.54 { return -0.5 + v * (t - 0.39) }"):
            self.assertIn(stop, state)

        tau = 2 * math.pi
        speed = (9 * tau + 0.5) / 2.4625

        def celebration(t: float) -> float:
            if t <= 0:
                return 0
            if t < 0.24:
                return -0.25 * (1 - math.cos(math.pi * t / 0.24))
            if t < 0.54:
                return -0.5 + speed * (t - 0.24) ** 2 / 0.6
            if t < 2.54:
                return -0.5 + speed * (t - 0.39)
            if t < 3.79:
                landed = 1 - (1 - (t - 2.54) / 1.25) ** 4
                return -0.5 + speed * 2.15 + 1.25 * speed * landed / 4
            return 9 * tau

        # The wind-up goes the other way first, and the turn lands on exactly nine turns.
        self.assertLess(celebration(0.24), 0)
        self.assertAlmostEqual(celebration(3.79), 9 * tau, places=9)
        self.assertAlmostEqual(celebration(6.0), 9 * tau, places=9)
        # Monotonic once it sets off, so the cage never jitters back.
        marks = [celebration(0.6 + i * 0.1) for i in range(31)]
        self.assertEqual(marks, sorted(marks))


class TheEyesMorph(unittest.TestCase):
    """A look is numbers that blend, so a change moves the eyes instead of cutting."""

    def test_an_eye_is_an_outline_of_forty_points_about_its_own_centre(self) -> None:
        eyes = read(EYES)
        self.assertIn("static let steps = 40", eyes)
        # eyes.ts:25-27 — the slit is 1.9 long, 0.5 thick and tipped 0.2, as shares of the eye's width.
        self.assertIn("static let slitLength = 1.9", eyes)
        self.assertIn("static let slitThickness = 0.5", eyes)
        self.assertIn("static let slitTip = 0.2", eyes)
        # The arc's own fractions are the validator's HAPPY_ARC (validate.ts:24).
        for number in ("public static let halfWidth = 0.72", "public static let base = 0.10",
                       "public static let peak = 0.42", "public static let stroke = 0.60"):
            self.assertIn(number, eyes)
        # The three shapes, mixed by the look, point by point.
        outline = eyes[eyes.index("public static func outline("):]
        outline = outline[:outline.index("\n    }")]
        self.assertIn("(1 - a - s, pill(cx: spot.x, cy: spot.y + spot.shift, w: spot.w, h: spot.open))", outline)
        self.assertIn("(a, arc(spot))", outline)
        self.assertIn("(s, slit(spot))", outline)
        self.assertIn("out[index].x += point.x * weight", outline)

    def test_the_plain_pill_and_the_plain_arc_are_drawn_as_before(self) -> None:
        eyes = read(EYES)
        # `plainLook` (eyes.ts:113): exactly the arc, or exactly the pill, keeps its old drawing.
        self.assertIn("if look.arc >= 1 { return .arc }", eyes)
        self.assertIn("return look.arc <= 0 && look.slit <= 0 ? .pill : nil", eyes)
        renderer = read(RENDERER)
        self.assertIn("let plain = OpenBotAvatarEyes.plain(look)", renderer)
        self.assertIn("layer.stroke(OpenBotAvatarEyes.arcPath(spot), with: .color(ink),", renderer)
        # Every look in between is one filled outline — where the morphing lives.
        self.assertIn("layer.fill(OpenBotAvatarEyes.eyePath(look, spot: spot), with: .color(ink))", renderer)
        # And every built-in state is exactly one of the two plain shapes: the mood owns the arc,
        # nothing sets the slit, so there is nothing to morph in the eight.
        for state in STATES:
            self.assertNotIn("pose.slit", branch(state))
        self.assertIn("pose.arch = 1", branch("idle"))
        self.assertIn("if mood == .happy { pose.arch = 1 }", branch("done"))


class ReducedMotionStillCalmsTheNewPieces(unittest.TestCase):
    def test_no_ribbons_are_drawn_from_a_still_pose(self) -> None:
        # A working bot's band is zeroed under reduced motion, and `ribbonPieces` draws nothing below
        # a presence of 0.01 (effects.ts:241).
        self.assertIn("pose.ribbons = reducedMotion ? 0 : min(1", branch("working"))
        self.assertIn("if k <= 0.01 { return [] }", read(RIBBONS))
        # The presence gate is the pose's; it is applied inside the passes that draw a ribbon.
        self.assertIn("let ribbons = showsRibbons && pose.ribbons > 0.01", read(RENDERER))

    def test_done_does_not_turn(self) -> None:
        done = branch("done")
        # Past its celebration, so `since` is 3.87 and the block is skipped: it rests.
        self.assertIn("let age = !reducedMotion ? max(0, stateAge ?? t) : Self.doneTurnSeconds", done)

    def test_a_mark_holds_still(self) -> None:
        # `still` is handed to the marks, so their clock is 0 and nothing hops (effects.ts:392).
        marks = read(MARKS)
        self.assertIn("time: still ? 0 : time + OpenBotAvatarState.noise(seed, 9) * 10", marks)
        self.assertIn("let p = context.still ? 1 :", marks)     # the exclamation mark's alarm
        self.assertIn("let p = context.still ? 0 :", marks)     # the dots' hop
        self.assertIn("let jump = context.still ? 0 : sin(.pi * alarm)", marks)
        # And the view tells the renderer, and the renderer tells the marks.
        self.assertIn("still: !moves,", read(VIEW))
        self.assertIn("still: Bool = false,", read(RENDERER))
        self.assertIn("still: still,", read(RENDERER))
        self.assertIn("time: time, transform: viewport)", read(RENDERER))


class TheGlassFaceIsStillOptIn(unittest.TestCase):
    """Nothing above changed how a material is chosen, or which one a caller gets by saying nothing."""

    def test_the_default_is_still_solid_and_the_table_is_four(self) -> None:
        self.assertIn("material: BotAvatarMaterial = .solid", read(RENDERER))
        material = read(AVATAR / "BotAvatarMaterial.swift")
        self.assertIn("static let all: [BotAvatarMaterialSpec] = [.solid, .glass, .matte, .metal]", material)
        # Glass keeps its six layers; the marks go through the same ones, not a shorter list.
        paint = read(PAINT)
        self.assertIn("case .ramp(let lightness, let mid, let darkness, let step):", paint)
        self.assertIn("if plan.rim, let rim = spec.rim {", paint)
