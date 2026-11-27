"""The faces audit's three fixes, guarded from the source *and* from the numbers.

Three things were wrong with the drawn face, and each is a fact this suite can hold:

* **The desktop pet's face never moved.** `OpenBotAvatarView` gated its clock on `scenePhase ==
  .active`, and the pet hosts its face as the root of a bare `NSHostingView` in a borderless
  `NSPanel` — no scene at all, so the environment held `ScenePhase`'s `.background` default for
  ever. The pose froze at rest while the pet's own hop, blink and gaze loops ran around it. The view
  now takes `gate:`, which says *who* answers "is this on screen", and the pet says `.host` (it
  already folds its panel's occlusion into `animates:`); everything in a real scene keeps the default
  and therefore its old behaviour.
* **A glass body under a mark never shrank.** `BotAvatarGlassRoute.decide` promised that "a body
  under a mark takes `.canvas`" and did not check, and `bodyTransform` — the one transform the
  painted ramp, the shader's box and the mask all read — omitted `OpenBotAvatarMarks.bodyScale`. A
  marked glass bot drew a full-size body with a full-size mark over it.
* **The glass mask froze at the first pose that drew.** The drawer rebuilds its silhouette texture
  only when the key changes, and the key was the body's path — so a celebrating glass bot's body
  never turned or hopped while its eyes and ribbons did. The key is now the body *and* the pose
  dimensions that move the outline, bucketed so a 10 Hz frame does not rebuild tens of millions of
  multiply-adds.

Each class below fails on the code before its fix; the ones that say "measured" mirror a formula
out of the Swift and evaluate it, because the drawing itself cannot run here.
"""
from __future__ import annotations

import math
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UI = ROOT / "Sources" / "HermeyUI"
AVATAR = UI / "OpenBotAvatar"

VIEW = AVATAR / "OpenBotAvatarView.swift"
ROUTE = AVATAR / "OpenBotAvatarGlassRoute.swift"
RENDERER = AVATAR / "OpenBotAvatarRenderer.swift"
STATE = AVATAR / "OpenBotAvatarState.swift"
STATE_DEFINITION = AVATAR / "OpenBotAvatarStateDefinition.swift"
MARKS = AVATAR / "OpenBotAvatarMarks.swift"
BOT_AVATAR_VIEW = UI / "BotAvatarView.swift"
MAC_PET = ROOT / "Apps" / "HermesMac" / "Pets" / "PetView.swift"
PET_CONTROLLER = ROOT / "Apps" / "HermesMac" / "Pets" / "DesktopPetController.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def code(path: Path) -> str:
    """The file with its comments removed: a sentence naming a symbol is not the symbol."""
    return "\n".join(line.split("//")[0] for line in read(path).splitlines())


def declaration(text: str, marker: str) -> str:
    """The brace-balanced body of the first declaration containing `marker`."""
    start = text.index(marker)
    opening = text.index("{", start)
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    raise AssertionError(f"unbalanced braces after {marker!r}")


def swift_round(value: float) -> int:
    """Swift's `Double.rounded()`: half away from zero, not Python's half-to-even."""
    return int(math.floor(value + 0.5)) if value >= 0 else int(math.ceil(value - 0.5))


# MARK: - The pet's face moves


def moves_expression() -> str:
    return re.search(r"let moves = ([^\n]+)", code(VIEW)).group(1)


def on_screen_expression() -> str:
    return re.search(r"let onScreen = ([^\n]+)", code(VIEW)).group(1)


def swift_truth(expression: str, names: dict) -> bool:
    """Evaluate one of the view's boolean lines, with the operators it really uses.

    The expression is read out of the Swift source in `moves_expression` / `on_screen_expression`,
    so a rule that loses a term fails here rather than passing on a copy of itself.
    """
    python = (expression.replace("&&", " and ")
                        .replace("||", " or ")
                        .replace("Double(size) >= animatingFrom", "size >= animating_from")
                        .replace("onScreen", "on_screen")
                        .replace("!", " not "))
    # Swift's enum cases (`.active`, `.background`) are identifiers once the dot is quoted, so the
    # comparison reads as a string equality in Python.
    python = re.sub(r"\.([A-Za-z_]\w*)", r'"\1"', python)
    # …and a value given as the case itself (`.host`) compares equal to the quoted identifier.
    plain = {key: (value[1:] if isinstance(value, str) and value.startswith(".") else value)
             for key, value in names.items()}
    return bool(eval(python, {"__builtins__": {}}, plain))


def body_moves(*, animates: bool, reduce_motion: bool, size: float, animating_from: float,
               gate: str, scene_phase: str) -> bool:
    on_screen = swift_truth(on_screen_expression(), {"gate": gate, "scenePhase": scene_phase})
    return swift_truth(moves_expression(), {"animates": animates, "still": reduce_motion,
                                            "size": size, "animating_from": animating_from,
                                            "on_screen": on_screen})


class ThePetFaceMoves(unittest.TestCase):
    """A panel-hosted face asks its host, not a scene above it — and still asks the scene by default."""

    def test_the_on_screen_answer_can_come_from_the_host(self) -> None:
        self.assertIn("gate == .host", on_screen_expression())
        self.assertIn("scenePhase == .active", on_screen_expression())

    def test_motion_reads_that_answer(self) -> None:
        self.assertIn("onScreen", moves_expression())

    def test_the_default_gate_is_the_scene_phase(self) -> None:
        # Every surface inside a window scene — the list rows, the chat header, the editor's preview,
        # the Live Activity — keeps exactly the gate it had.
        self.assertIn("gate: OpenBotAvatarMotionGate = .scenePhase", code(VIEW))

    def test_the_pet_passes_the_host_gate_and_its_own_visibility(self) -> None:
        pet = code(MAC_PET)
        self.assertIn("animates: pet.isVisible,", pet)
        self.assertIn("gate: .host,", pet)
        # The gate is the *pet's* face, not the shared shape face: it sits in the same call that
        # draws the generated avatar, and nowhere else in the app says `.host`.
        view = code(BOT_AVATAR_VIEW)
        self.assertNotIn("gate: .host", view,
                         "a scened surface must keep asking scenePhase")

    def test_the_pet_is_the_panel_hosted_one(self) -> None:
        # The premise of the fix, checked where it is: a bare `NSHostingView` in an `NSPanel` — no
        # scene, so `scenePhase` reads `.background` and the old gate could only ever freeze it.
        controller = code(PET_CONTROLLER)
        self.assertIn("let hosting = NSHostingView(rootView: PetView(", controller)
        self.assertIn("panel.contentView = hitView", controller)
        self.assertIn("hitView.addSubview(hosting)", controller)
        # …and the visibility it passes is the panel's own occlusion.
        self.assertIn("NSWindow.didChangeOcclusionStateNotification", controller)
        self.assertIn("pet.model.isVisible = visible", controller)

    def test_the_old_rule_froze_the_pet_and_the_new_one_does_not(self) -> None:
        # Measured on the real expression: `.background` is what a bare hosting view answers, so the
        # pre-fix rule (the same line without `gate`) is false for a pet whose panel is on screen.
        def old_rule(*, animates, reduce_motion, size, animating_from, scene_phase):
            return swift_truth(moves_expression().replace("onScreen", "scene_phase == .active"),
                               {"animates": animates, "still": reduce_motion, "size": size,
                                "animating_from": animating_from, "scene_phase": scene_phase})

        self.assertFalse(old_rule(animates=True, reduce_motion=False, size=96, animating_from=24,
                                  scene_phase=".background"),
                         "the pre-fix rule must be the bug, or this file proves nothing")
        self.assertTrue(body_moves(animates=True, reduce_motion=False, size=96, animating_from=24,
                                   gate=".host", scene_phase=".background"),
                        "a visible pet's face must move")
        # …and the host's own answer still stops it: an occluded panel (animates false) is at rest.
        self.assertFalse(body_moves(animates=False, reduce_motion=False, size=96, animating_from=24,
                                    gate=".host", scene_phase=".background"))
        # Reduce Motion and the size floor still win over the gate.
        self.assertFalse(body_moves(animates=True, reduce_motion=True, size=96, animating_from=24,
                                    gate=".host", scene_phase=".background"))
        self.assertFalse(body_moves(animates=True, reduce_motion=False, size=16, animating_from=24,
                                    gate=".host", scene_phase=".background"))
        # A scened face is unchanged: background scene, no motion.
        self.assertFalse(body_moves(animates=True, reduce_motion=False, size=32, animating_from=24,
                                    gate=".scenePhase", scene_phase=".background"))
        self.assertTrue(body_moves(animates=True, reduce_motion=False, size=32, animating_from=24,
                                   gate=".scenePhase", scene_phase=".active"))


# MARK: - A body under a mark shrinks


def decide_body() -> str:
    source = code(ROUTE)
    start = source.index("func decide(")
    return source[start:source.index("\n    }", start)]


def body_scale_constants() -> tuple[float, float]:
    """`markFrom` and the divisor, read out of the Swift rather than copied."""
    marks = code(MARKS)
    mark_from = float(re.search(r"static let markFrom = ([0-9.]+)", marks).group(1))
    body = marks[marks.index("public static func bodyScale(_ marks: [PoseMark]) -> Double"):]
    body = body[:body.index("\n    }")]
    divisor = float(re.search(r"weight\)\) / ([0-9.]+)\)", body).group(1))
    return mark_from, divisor


def smoothed(value: float) -> float:
    x = min(1.0, max(0.0, value))
    return x * x * (3 - 2 * x)


def body_scale(weights: list[float]) -> float:
    """`OpenBotAvatarMarks.bodyScale`, in Python, from the Swift's own two numbers."""
    mark_from, divisor = body_scale_constants()

    def grown(weight: float) -> float:
        return smoothed((min(1.0, max(0.0, weight)) - mark_from) / (1 - mark_from))

    def left(weight: float) -> float:
        return 1 - smoothed(min(1.0, max(0.0, weight)) / divisor)

    scale = left(sum(weights))
    return scale if any(grown(weight) > 0 for weight in weights) else max(scale, left(mark_from))


def surface_half_width(points_per_unit: float, scale: float, box_half_width: float = 50) -> float:
    """The drawn half width `BotAvatarGlassSurface.make` computes, for a uniform body scale.

    The uniform is the box's own half width (`model.volume.box` is 100 units across), through the
    frame's points-per-unit and through the transform's shrink — the transform's determinant scales by
    `scale²`, so the square root it takes scales by `scale`, and the four transformed corners' span
    scales with them.
    """
    return box_half_width * points_per_unit * scale


class AGlassBodyUnderAMarkShrinks(unittest.TestCase):
    """The route refuses the shader for a marked pose, and the transform shrinks the body anyway."""

    def test_the_route_refuses_the_shader_for_a_mark(self) -> None:
        body = decide_body()
        self.assertIn("carriesMark: Bool = false", body)
        self.assertIn("guard !carriesMark else { return .canvas }", body)
        # It sits after the material and transparency guards and before the shader is returned.
        self.assertLess(body.index("guard material == .glass"), body.index("guard !carriesMark"))
        self.assertLess(body.index("guard !reduceTransparency"), body.index("guard !carriesMark"))
        self.assertLess(body.index("guard !carriesMark"), body.index("return .metal"))

    def test_the_view_asks_the_state_the_one_question_it_can_answer(self) -> None:
        view = code(VIEW)
        self.assertIn("carriesMark: state.mayCarryMark", view)
        choice = code(STATE_DEFINITION)
        may = declaration(choice, "public var mayCarryMark: Bool")
        # The eight never carry one (their branches are guarded); a host's definition may.
        self.assertIn("case .named: return false", may)
        self.assertIn("case .defined: return true", may)

    def test_the_one_transform_applies_the_shrinks_own_number(self) -> None:
        transform = declaration(code(RENDERER), "static func bodyTransform(")
        self.assertIn("OpenBotAvatarMarks.bodyScale(pose.marks)", transform)
        self.assertIn("scaleAbout(pivot: model.volume.pivot, by: bodyScale)", transform)
        # First in the chain — the body's own coordinates, before its plane, its motion and the view —
        # exactly as the slice stack applies it (`draw`'s `shrink`).
        self.assertLess(transform.index("shrink\n            .concatenating(planeTransform"),
                        transform.index("rootTransform(pose: pose"))

    def test_the_shrink_is_the_one_the_marks_ask_for(self) -> None:
        # Measured, from the Swift's own two constants: no mark keeps the body whole, a mark at a
        # third of its weight keeps just over half, and one that has all but arrived is gone.
        self.assertEqual(body_scale([]), 1.0)
        self.assertAlmostEqual(body_scale([0.30]), 1 - smoothed(0.30 / 0.55), places=9)
        self.assertLess(body_scale([0.30]), 0.5)
        self.assertLess(body_scale([0.62]), 0.001)

    def test_the_drawn_body_is_smaller_by_exactly_that_much(self) -> None:
        # The shader's half width comes from the same transform the painted ramp uses, so a mark at
        # 0.30 of its weight draws a body 42 % as wide — and the pre-fix chain (no shrink) drew it at
        # the full 50 units with the mark over it at full size, which is the reported picture.
        scale = body_scale([0.30])
        full = surface_half_width(1.0, 1.0)
        marked = surface_half_width(1.0, scale)
        self.assertAlmostEqual(marked / full, scale, places=9)
        self.assertLess(marked, 0.5 * full)
        self.assertGreater(marked, 0.0)


# MARK: - The mask follows the pose


def silhouette_key_body() -> str:
    return declaration(code(STATE), "public var silhouetteKey: String")


def bucket_steps() -> dict[str, float]:
    """The fields the key is built from, and each one's bucket, out of the Swift itself."""
    steps = {}
    for field, step in re.findall(r"bucket\((\w+), ([0-9. /]+)\)", silhouette_key_body()):
        steps[field] = eval(step, {"__builtins__": {}})
    return steps


def silhouette_key(**fields) -> str:
    """`OpenBotAvatarPose.silhouetteKey`, mirrored, with the Swift's own buckets."""
    steps = bucket_steps()
    defaults = {"yaw": 0.0, "pitch": 0.0, "roll": 0.0, "lift": 0.0, "sx": 1.0, "sy": 1.0,
                "scale": 1.0}
    joined = {**defaults, **fields}
    parts = []
    for field in ("yaw", "pitch", "roll", "lift", "sx", "sy", "scale"):
        parts.append(str(swift_round(joined[field] / steps[field])))
    return " ".join(parts)


class TheGlassMaskFollowsThePose(unittest.TestCase):
    """The silhouette's texture is rebuilt when the silhouette moves — and not when it blinks."""

    def test_the_key_names_the_dimensions_that_move_the_outline(self) -> None:
        steps = bucket_steps()
        self.assertEqual(sorted(steps), ["lift", "pitch", "roll", "scale", "sx", "sy", "yaw"],
                         sorted(steps))
        # A celebration's turn and hop, a working sway and squash, and the shrink under a mark.
        body = silhouette_key_body()
        self.assertIn("OpenBotAvatarMarks.bodyScale(marks)", body)

    def test_the_key_leaves_out_what_never_moves_the_edge(self) -> None:
        body = silhouette_key_body()
        for absent in ("blink", "gazeX", "gazeY", "arch", "squint", "slit", "tilt",
                       "ribbons", "cage", "sweep", "mood", "light"):
            self.assertNotIn(absent, body, f"`{absent}` would rebuild the mask for a frame")

    def test_the_key_is_the_body_and_the_pose(self) -> None:
        view = code(VIEW)
        metal = view.split("case .metal:")[1]
        self.assertIn('maskKey: model.bodyKey + "|" + pose.silhouetteKey)', metal)
        # The shape-key fix that stopped a preset sticking is still in front of it.
        self.assertIn("public var bodyKey: String { definition.body.path }", code(RENDERER))

    def test_the_steps_are_sub_pixel_at_the_sizes_the_material_draws_at(self) -> None:
        # A bucket step is a mask rebuild, so it has to be small enough to be invisible and large
        # enough not to fire every frame. One definition unit is `side / 100` points: at 96 pt (the
        # pet) half a unit is 0.48 pt — under a pixel at 2x — and 1/32 rad of turn is 1.8°.
        steps = bucket_steps()
        self.assertEqual(steps["yaw"], 1 / 32)
        self.assertEqual(steps["pitch"], 1 / 32)
        self.assertEqual(steps["roll"], 0.5)
        self.assertEqual(steps["lift"], 0.5)
        self.assertEqual(steps["sx"], 0.01)
        self.assertEqual(steps["sy"], 0.01)
        self.assertEqual(steps["scale"], 0.02)
        points_per_unit = 96 / 100
        self.assertLess(steps["lift"] * points_per_unit, 1.0, "a lift step of a pixel or more")
        self.assertLess(steps["yaw"] * 57.2958, 2.0, "a turn step of more than 2°")

    def test_the_old_key_froze_the_body_and_the_new_one_turns_it(self) -> None:
        # `done`'s body turns ±π over its sweep (`near(sweep / 3)`, the ribbons going round three
        # times) and hops 2.2 units. Under the old key — the body's path and nothing else — every
        # frame of that celebrates with one frozen silhouette; under the new one, it turns.
        sweep = math.pi
        frames = []
        for step in range(0, 21):
            progress = step / 20
            sweep_now = -sweep + 2 * sweep * progress
            frames.append(dict(yaw=sweep_now / 3, lift=-2.2 * math.sin(math.pi * progress)))
        old_keys = {"the body's path"}          # what the key was: identical on every frame
        new_keys = {silhouette_key(**frame) for frame in frames}
        self.assertEqual(len(old_keys), 1)
        self.assertGreater(len(new_keys), 3, "the mask would still be frozen through a celebration")
        # …and it is bounded: a bucket per ~1.8° of the turn, not one per frame.
        self.assertLessEqual(len(new_keys), len(frames) * 2)
        self.assertNotEqual(silhouette_key(yaw=math.pi / 3), silhouette_key(yaw=-math.pi / 3))

    def test_a_blink_or_a_glance_keeps_the_mask(self) -> None:
        # The other half of the rule: the key is not the whole pose. A frame that only blinks, looks
        # elsewhere or wears the happy arc draws the same edge.
        steady = silhouette_key(yaw=0.1, lift=-0.4)
        for extra in ({"blink": 1.0}, {"gazeX": 0.9}, {"gazeY": -0.9}, {"arch": 1.0},
                      {"squint": 0.4}):
            self.assertEqual(silhouette_key(yaw=0.1, lift=-0.4), steady, extra)
            self.assertEqual(silhouette_key(yaw=0.1, lift=-0.4, **extra), steady, extra)


if __name__ == "__main__":
    unittest.main()
