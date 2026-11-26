"""The generated-avatar feature, guarded from the source text.

`OpenBotAvatar` is SwiftUI and the storage is Rust, so neither can be exercised from this suite
directly. What *can* be checked — and is, below — is every fact a port can silently get wrong:

* the definition's field set is the upstream contract's, exactly, and unknown fields are refused;
* the validator implements the contract's rules (version, slug, name, box, eye scale and spacing,
  eyes inside the body) rather than a subset;
* the presets really are valid definitions — this file re-implements the validator's arithmetic and
  runs every shipped path through it, so a preset that drifts below the safe area or puts its eyes
  outside the body fails here;
* all eight states exist and each one takes its own branch of the pose model, with the motion each
  state is known by — and no state that resizes the body, hides its eyes or replaces them;
* the host stores a definition, returns it unchanged, and refuses a bad one with the validator's
  reason (the Rust tests do this for real; this checks the route still calls the validator and the
  400, so a refactor cannot quietly drop it);
* both apps' settings offer the Avatar tab, and a bot without a definition still draws its picture.

Upstream contract: `docs/avatar-contract.md` and `packages/core/src/{types,validate,path}.ts` of
github.com/DominikScholz/open-bot-avatar (MIT).
"""
from __future__ import annotations

import math
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UI = ROOT / "Sources" / "HermeyUI"
AVATAR = UI / "OpenBotAvatar"
DEFINITION = AVATAR / "BotAvatarDefinition.swift"
GEOMETRY = AVATAR / "OpenBotAvatarGeometry.swift"
VOLUME = AVATAR / "OpenBotAvatarVolume.swift"
STATE = AVATAR / "OpenBotAvatarState.swift"
RENDERER = AVATAR / "OpenBotAvatarRenderer.swift"
VIEW = AVATAR / "OpenBotAvatarView.swift"
PRESETS = AVATAR / "OpenBotAvatarPresets.swift"
EDITOR = AVATAR / "OpenBotAvatarEditor.swift"
MARKS = AVATAR / "OpenBotAvatarMarks.swift"
EYES = AVATAR / "OpenBotAvatarEyes.swift"
RIBBONS = AVATAR / "OpenBotAvatarRibbons.swift"
DEFINITIONS = AVATAR / "OpenBotAvatarStateDefinition.swift"
BOT_AVATAR_VIEW = UI / "BotAvatarView.swift"

MAC_SETTINGS = ROOT / "Apps" / "HermesMac" / "Views" / "MacBotSettingsSheet.swift"
IOS_SETTINGS = ROOT / "Apps" / "HermesMobile" / "Views" / "BotModelSettingsScreen.swift"
MAC_ROW = ROOT / "Apps" / "HermesMac" / "Sidebar" / "SidebarBotList.swift"
MAC_HEADER = ROOT / "Apps" / "HermesMac" / "Conversation" / "ConversationHeader.swift"
IOS_ROW = ROOT / "Apps" / "HermesMobile" / "Views" / "BotListScreen.swift"
IOS_HEADER = ROOT / "Apps" / "HermesMobile" / "Views" / "ConversationScreen.swift"
MAC_PET = ROOT / "Apps" / "HermesMac" / "Pets" / "PetView.swift"
MAC_STORE = ROOT / "Apps" / "HermesMac" / "Workspace" / "WorkspaceStore.swift"
IOS_ENV = ROOT / "Apps" / "HermesMobile" / "App" / "AppEnvironment.swift"

RUST_AVATAR = ROOT / "hermeyd" / "src" / "bot_avatar.rs"
RUST_ROUTES = ROOT / "hermeyd" / "src" / "bridge_routes.rs"

TOP_KEYS = ["version", "id", "name", "body", "eyes"]
EYE_KEYS = ["x", "y", "spacing", "scale"]
STATES = ["idle", "thinking", "reading", "working", "computer", "waiting", "blocked", "done"]

EYE_W, EYE_H = 4.0, 11.0
BODY_MIN, BODY_MAX = 6.0, 94.0
EYE_MARGIN = 1.2


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


# --------------------------------------------------------------------------- arithmetic
#
# The validator, in Python. Small on purpose: the presets are absolute M/L/H/V/C/Q/Z paths, and the
# eye question the contract asks is "does this stadium fit inside the filled outline".

NUM = re.compile(r"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?")


def flatten(path: str, steps: int = 14) -> list[list[tuple[float, float]]]:
    tokens = re.findall(r"[MmLlHhVvCcSsQqTtAaZz]|" + NUM.pattern, path)
    polygons: list[list[tuple[float, float]]] = []
    current: list[tuple[float, float]] = []
    point = (0.0, 0.0)
    start = (0.0, 0.0)
    command = ""
    index = 0

    def take(count: int) -> list[float]:
        nonlocal index
        values = []
        for _ in range(count):
            while index < len(tokens) and not NUM.fullmatch(tokens[index]):
                index += 1
            values.append(float(tokens[index]))
            index += 1
        return values

    while index < len(tokens):
        token = tokens[index]
        if re.fullmatch(r"[A-Za-z]", token):
            command = token
            index += 1
            if command.upper() == "Z":
                if len(current) >= 3:
                    polygons.append(current)
                current = []
                point = start
                continue
            continue
        relative = command.islower()
        upper = command.upper()
        if upper in ("M", "L"):
            x, y = take(2)
            target = (point[0] + x, point[1] + y) if relative else (x, y)
            if upper == "M":
                if len(current) >= 3:
                    polygons.append(current)
                current = [target]
                start = target
                command = "l" if relative else "L"
            else:
                current.append(target)
            point = target
        elif upper == "H":
            (x,) = take(1)
            target = (point[0] + x, point[1]) if relative else (x, point[1])
            current.append(target)
            point = target
        elif upper == "V":
            (y,) = take(1)
            target = (point[0], point[1] + y) if relative else (point[0], y)
            current.append(target)
            point = target
        elif upper == "C":
            values = take(6)
            c1 = (values[0], values[1])
            c2 = (values[2], values[3])
            end = (values[4], values[5])
            if relative:
                c1 = (c1[0] + point[0], c1[1] + point[1])
                c2 = (c2[0] + point[0], c2[1] + point[1])
                end = (end[0] + point[0], end[1] + point[1])
            for step in range(1, steps + 1):
                t = step / steps
                m = 1 - t
                current.append((
                    m ** 3 * point[0] + 3 * m * m * t * c1[0] + 3 * m * t * t * c2[0] + t ** 3 * end[0],
                    m ** 3 * point[1] + 3 * m * m * t * c1[1] + 3 * m * t * t * c2[1] + t ** 3 * end[1],
                ))
            point = end
        elif upper == "Q":
            values = take(4)
            control = (values[0], values[1])
            end = (values[2], values[3])
            if relative:
                control = (control[0] + point[0], control[1] + point[1])
                end = (end[0] + point[0], end[1] + point[1])
            for step in range(1, steps + 1):
                t = step / steps
                m = 1 - t
                current.append((
                    m * m * point[0] + 2 * m * t * control[0] + t * t * end[0],
                    m * m * point[1] + 2 * m * t * control[1] + t * t * end[1],
                ))
            point = end
        else:
            index += 1
    if len(current) >= 3:
        polygons.append(current)
    return polygons


def contains(polygons, p) -> bool:
    winding = 0
    for polygon in polygons:
        previous = polygon[-1]
        for vertex in polygon:
            if previous[1] <= p[1]:
                if vertex[1] > p[1] and cross(previous, vertex, p) > 0:
                    winding += 1
            elif vertex[1] <= p[1] and cross(previous, vertex, p) < 0:
                winding -= 1
            previous = vertex
    return winding != 0


def cross(a, b, p) -> float:
    return (b[0] - a[0]) * (p[1] - a[1]) - (p[0] - a[0]) * (b[1] - a[1])


def eye_outline(cx: float, cy: float, scale: float, margin: float):
    half_w = EYE_W * scale / 2 + margin
    half_h = EYE_H * scale / 2 + margin
    straight = max(0.0, half_h - half_w)
    points = []
    for k in range(16):
        angle = k / 16 * math.tau
        points.append((cx + math.cos(angle) * half_w,
                       cy + math.sin(angle) * half_w + (1 if math.sin(angle) >= 0 else -1) * straight))
    for fraction in (-0.5, 0, 0.5):
        points.append((cx - half_w, cy + fraction * straight))
        points.append((cx + half_w, cy + fraction * straight))
    return points


def definition_errors(path: str, eyes) -> list[str]:
    errors = []
    polygons = flatten(path)
    if not polygons:
        return ["body.path: nothing to draw"]
    xs = [p[0] for polygon in polygons for p in polygon]
    ys = [p[1] for polygon in polygons for p in polygon]
    min_x, max_x, min_y, max_y = min(xs), max(xs), min(ys), max(ys)
    if min_x < BODY_MIN:
        errors.append(f"left edge x={min_x}")
    if min_y < BODY_MIN:
        errors.append(f"top edge y={min_y}")
    if max_x > BODY_MAX:
        errors.append(f"right edge x={max_x}")
    if max_y > BODY_MAX:
        errors.append(f"bottom edge y={max_y}")
    if max(max_x - min_x, max_y - min_y) < 40 or min(max_x - min_x, max_y - min_y) < 14:
        errors.append("body is too small")
    area = 0.0
    for polygon in polygons:
        total = 0.0
        previous = polygon[-1]
        for vertex in polygon:
            total += previous[0] * vertex[1] - vertex[0] * previous[1]
            previous = vertex
        area += total / 2
    if abs(area) < 600:
        errors.append("body fill area too thin")
    x, y, spacing, scale = eyes
    if not 0.6 <= scale <= 1.8:
        errors.append("eyes.scale out of range")
    if not (EYE_W * scale * 1.75 <= spacing <= 40):
        errors.append("eyes.spacing out of range")
    for cx, cy in ((x - spacing / 2, y), (x + spacing / 2, y)):
        for point in eye_outline(cx, cy, scale, EYE_MARGIN):
            if not contains(polygons, point):
                errors.append("eyes must sit inside the body")
                return errors
    return errors


def preset_values() -> list[tuple[str, str, tuple[float, float, float, float]]]:
    """Every `BotAvatarDefinition(...)` literal in the presets file, read out of the Swift."""
    source = read(PRESETS)
    found = []
    for match in re.finditer(
        r'public static let (\w+) = BotAvatarDefinition\(\s*id: "([\w-]+)",\s*name: "([^"]+)",'
        r'\s*body: \.init\(path: "([^"]+)"\),\s*eyes: \.init\(x: ([\d.]+), y: ([\d.]+), spacing: ([\d.]+), scale: ([\d.]+)\)\)',
        source,
    ):
        found.append((match.group(2), match.group(4),
                      (float(match.group(5)), float(match.group(6)),
                       float(match.group(7)), float(match.group(8)))))
    return found


class TheDefinitionIsTheContracts(unittest.TestCase):
    """A definition copied from upstream's editor must import unchanged — and nothing else may."""

    def test_the_field_set_is_upstreams_exactly(self) -> None:
        source = read(DEFINITION)
        key_list = re.search(r"topLevelKeys = \[([^\]]+)\]", source)
        self.assertIsNotNone(key_list, "BotAvatarDefinition no longer declares its field set")
        keys = [k.strip().strip('"') for k in key_list.group(1).split(",")]
        self.assertEqual(keys, TOP_KEYS)
        eye_list = re.search(r"eyeKeys = \[([^\]]+)\]", source)
        self.assertIsNotNone(eye_list)
        self.assertEqual([k.strip().strip('"') for k in eye_list.group(1).split(",")], EYE_KEYS)

    def test_unknown_fields_are_refused_not_dropped(self) -> None:
        source = read(DEFINITION)
        self.assertIn("rejectUnknown", source)
        self.assertIn("unknown field", source)
        # The body and the eyes are strict too, not just the top level.
        self.assertGreaterEqual(source.count("rejectUnknown"), 2)
        self.assertIn('first != "path"', source.replace('$0 != "path"', 'first != "path"'))

    def test_the_model_is_codable_in_both_directions(self) -> None:
        source = read(DEFINITION)
        for field in ("version", "id", "name", "body", "eyes"):
            self.assertIn(f'forKey: AnyKey("{field}")', source)
        self.assertIn("init(from decoder: Decoder)", source)
        self.assertIn("func encode(to encoder: Encoder)", source)

    def test_the_contract_documents_are_quoted_where_the_rules_come_from(self) -> None:
        # A port that does not name its source is a port nobody can check against the next version.
        self.assertIn("open-bot-avatar", read(DEFINITION))
        self.assertIn("MIT", read(GEOMETRY))


class TheValidatorKeepsTheContractsRules(unittest.TestCase):
    def test_every_rule_is_present(self) -> None:
        source = read(DEFINITION)
        for rule in [
            "version must be 1",
            "id must be a lowercase slug",
            "name must be 1-40 printable characters",
            "eyes.scale",
            "eyes.spacing",
            "eyes.x and eyes.y must be inside the 0 0 100 100 box",
            "body.path leaves the safe area",
            "body is too small",
            "eyes must sit inside the body",
        ]:
            self.assertIn(rule, source, f"the validator has lost its {rule!r} rule")

    def test_the_bounds_match_upstream(self) -> None:
        source = read(DEFINITION)
        self.assertIn("bodyMin = 6", source)
        self.assertIn("bodyMax = 94", source)
        geometry = read(GEOMETRY)
        self.assertIn("eyeMargin = 1.2", geometry)
        self.assertIn("eyeWidth = 4", geometry)
        self.assertIn("eyeHeight = 11", geometry)
        self.assertIn("eyes.scale < 0.6 || eyes.scale > 1.8", source)

    def test_a_definition_outside_the_box_is_refused(self) -> None:
        eyes = (50, 46, 15, 1)
        outside = definition_errors("M2 20 H80 V80 H20 Z", eyes)
        self.assertEqual(len(outside), 1, outside)
        self.assertTrue(outside[0].startswith("left edge x=2"), outside)
        self.assertEqual(definition_errors("M20 20 H80 V80 H20 Z", eyes), [])

    def test_the_eyes_must_be_inside(self) -> None:
        self.assertTrue(definition_errors("M20 20 H80 V80 H20 Z", (88, 46, 15, 1)))
        self.assertTrue(definition_errors("M20 20 H80 V80 H20 Z", (50, 46, 60, 1)))


class ThePresetsAreValidDefinitions(unittest.TestCase):
    def test_at_least_twelve_presets(self) -> None:
        presets = preset_values()
        self.assertGreaterEqual(len(presets), 12,
                                "the Avatar tab starts from at least a dozen silhouettes")
        ids = [preset[0] for preset in presets]
        self.assertEqual(len(ids), len(set(ids)), "two presets share an id")
        self.assertEqual(len({preset[1] for preset in presets}), len(presets), "two presets share a path")
        # …and the table is what the editor and the Random button read.
        self.assertIn("public static let all: [BotAvatarDefinition]", read(PRESETS))
        source = read(PRESETS)
        listed = source.split("public static let all: [BotAvatarDefinition] = [")[1].split("]")[0]
        self.assertEqual(len([name for name in listed.replace("\n", " ").split(",") if name.strip()]),
                         len(presets), "a preset is declared but never offered")

    def test_every_preset_passes_the_validator(self) -> None:
        for preset_id, path, eyes in preset_values():
            with self.subTest(preset=preset_id):
                self.assertEqual(definition_errors(path, eyes), [],
                                 f"preset {preset_id} does not satisfy the contract")

    def test_the_presets_are_soft_rounded_shapes_not_slivers(self) -> None:
        for preset_id, path, _ in preset_values():
            polygons = flatten(path)
            xs = [p[0] for polygon in polygons for p in polygon]
            ys = [p[1] for polygon in polygons for p in polygon]
            self.assertLessEqual(max(xs), 94, preset_id)
            self.assertGreaterEqual(min(xs), 6, preset_id)
            self.assertLessEqual(max(ys), 94, preset_id)
            self.assertGreaterEqual(min(ys), 6, preset_id)

    def test_the_presets_are_validated_when_loaded(self) -> None:
        source = read(PRESETS)
        self.assertIn("try all.map { try $0.validated() }", source)


class TheStatesEachDrawThemselves(unittest.TestCase):
    def test_the_eight_states_exist(self) -> None:
        source = read(STATE)
        declared = re.findall(r"^    case (\w+)$", source, re.MULTILINE)
        self.assertEqual(declared[:8], STATES)

    def test_each_state_takes_its_own_branch(self) -> None:
        source = read(STATE)
        pose = source[source.index("public func pose("):source.index("    /// A state that starts part way through itself")]
        branches = re.split(r"\n        case \.", pose)[1:]
        self.assertEqual(len(branches), 8, "the pose switch no longer has eight branches")
        labels = re.findall(r"\n        case \.(\w+):", pose)
        self.assertEqual(labels, STATES)
        # Every branch does something, and no two branches draw the same pose.
        signatures = set()
        for label, branch in zip(labels, branches):
            body = branch.split("\n        case ")[0]
            touched = set(re.findall(r"pose\.(\w+)", body))
            self.assertTrue(touched, f"{label} draws nothing")
            signatures.add(tuple(sorted(touched)))
        self.assertEqual(len(signatures), 8, "two states share one drawing")

    def test_the_motion_each_state_is_known_by_is_where_the_contract_says(self) -> None:
        source = read(STATE)
        pose = source[source.index("public func pose("):source.index("    /// A state that starts part way through itself")]
        for label, marker in [
            ("thinking", "pose.gazeY = -0.8"),
            ("blocked", "pose.lift = reducedMotion ? 0 : -1.15 * (1 - cos(2 * .pi * t / 2.9))"),
            ("waiting", "pose.roll = 7 + 1.2 * wave(6.4, 2)"),
            ("working", "pose.sweep = 2 * .pi * turn"),
            ("done", "pose.yaw += Self.near(sweep / 3)"),
            ("reading", "pose.tilt = 0.2"),
            ("computer", "pose.gazeX = 0.55"),
        ]:
            branch = pose.split(f"case .{label}:")[1].split("case .")[0]
            self.assertIn(marker, branch, f"{label} no longer draws itself")

    def test_the_renderer_draws_one_shape_per_eye(self) -> None:
        source = read(RENDERER)
        # The eye's look is resolved once, as one of three drawings: the plain pill, the plain arc,
        # or the filled outline that morphs from one to the other (upstream's `eyes.ts`). One shape
        # per eye, never a shape and its replacement — and the exclamation mark is gone with its
        # plumbing.
        self.assertIn("let plain = OpenBotAvatarEyes.plain(look)", source)
        self.assertIn("switch plain {", source)
        self.assertIn("layer.fill(OpenBotAvatarEyes.eyePath(look, spot: spot), with: .color(ink))", source)
        # The renderer draws whatever pose it is given and never branches on a state's name.
        for gone in ("case .bang:", "case .thinking", "drawMark("):
            self.assertNotIn(gone, source, f"the renderer still reads {gone!r}")


class OnePairOfEyesInEveryState(unittest.TestCase):
    """One body at the one size, one pair of eyes, in every state: no mark, no shrink."""

    def renderer_draw(self) -> str:
        return read(RENDERER).split("public static func draw(")[1].split("// MARK: - View maths")[0]

    def eyes(self) -> str:
        return read(RENDERER).split("static func drawEyes(")[1].split("// MARK: - Ribbons")[0]

    def pose(self) -> str:
        source = read(STATE)
        return source[source.index("public func pose("):source.index("    /// A state that starts part way through itself")]

    def test_the_eyes_are_drawn_once_and_nothing_can_gate_them(self) -> None:
        draw = self.renderer_draw()
        self.assertEqual(draw.count("drawEyes("), 1,
                         "the eyes must be drawn once per frame, or a state shows two pairs")
        # The one condition over the eyes is the body's own presence while it gives way to a mark —
        # and a built-in state never carries a mark, so for all eight `bodyScale` is 1 and the eyes
        # are drawn exactly as they always were, once, after the body.
        self.assertIn("if bodyScale > 0.001 {\n            drawEyes(", draw,
                      "the eyes are drawn inside a condition that is not the give-way")
        self.assertEqual(draw.count("if bodyScale > 0.001 {\n            drawEyes("), 1,
                         "a second gate over the face appeared")
        self.assertIn("let bodyScale = OpenBotAvatarMarks.bodyScale(pose.marks)", draw)
        # Nothing after the eyes but the ribbons that pass in front and the marks, both of which are
        # empty for a built-in state.
        tail = draw.split("drawEyes(")[1]
        self.assertNotIn("switch spec.fill", tail, "the body is drawn again over the face")

    def test_no_state_can_resize_the_body_or_take_its_face(self) -> None:
        state = read(STATE)
        switch = state[state.index("switch self {"):state.index("        // The material's light rides the pose")]
        # Since 0.5.0 the pose *does* carry the channels a mark needs — `marks`, and the slit the
        # reference's waiting bot once had — because a definition of a host's own may use them. What
        # must stay true is that no built-in branch touches either: the eight draw one body at one
        # size with one pair of eyes.
        for channel in ("pose.marks", "pose.slit", "bodyScale", "markScale"):
            self.assertNotIn(channel, switch, f"a built-in state sets {channel!r}")
        self.assertIn("public var marks: [PoseMark] = []", state)
        self.assertIn("public var sx: Double = 1", state)
        self.assertIn("public var sy: Double = 1", state)

    def test_the_eyes_take_the_bodys_own_motion_and_nothing_else(self) -> None:
        eyes = self.eyes()
        # One chain: the eye's own plane, then the body's motion, then the view — and inside it the
        # body's give-way to a mark, so an eye is always drawn on the body it belongs to, at whatever
        # size that body is. `shrink` is the identity unless a custom pose carries a mark.
        self.assertIn("layer.transform = shrink\n                .concatenating(transform)\n"
                      "                .concatenating(root)\n"
                      "                .concatenating(viewport)", eyes)
        # Nothing else may scale an eye: no second size of its own.
        for gone in ("bodyScale", "pose.bodyScale"):
            self.assertNotIn(gone, eyes, f"the eyes still take a {gone!r}")

    def test_every_other_overlay_is_on_the_eyes_own_plane(self) -> None:
        eyes = self.eyes()
        # The happy arc and the neutral pill are one exclusive chain: one shape per eye, never a
        # shape and its replacement — and now exactly two shapes, not three.
        chain = eyes.split("if let plain {")[1]
        self.assertIn("} else {", chain)
        self.assertNotIn("else if", chain, "a third eye shape came back")
        self.assertEqual(eyes.count("if let plain {"), 1,
                         "the eye's shape is chosen once, not drawn twice")
        # The catchlight is drawn inside the eye it belongs to, in the same loop over the same pair.
        self.assertIn("if catchlight, plain != nil {", chain)
        # The pieces of ribbon that pass behind the body are drawn before it, so they cannot cross
        # the face; the pieces in front are drawn after the eyes, over the top of the hoop.
        draw = self.renderer_draw()
        self.assertLess(draw.index("draw(ribbons: ribbons.filter { !$0.front }"),
                        draw.index("switch spec.fill"),
                        "ribbons must be drawn behind the body")
        self.assertIn("draw(ribbons: ribbons.filter { $0.front }", draw.split("drawEyes(")[1],
                      "the pieces in front of the body are not drawn over it")
        self.assertNotIn("draw(ribbons:", eyes)

    def test_a_blink_cannot_leave_a_ghost_pair(self) -> None:
        eyes = self.eyes()
        self.assertIn("let centers = OpenBotAvatarGeometry.eyeCenters(eyes)", eyes)
        self.assertEqual(eyes.count("for (index, center) in centers.enumerated()"), 1,
                         "one drawn shape per eye, from the definition's own pair")
        # A closed eye is a flat pill, not nothing: a blink must never look like a missing eye.
        self.assertIn("let open = max(height * max(0.09, (1 - pose.blink) * (1 - pose.squint * 0.4)), width * 0.55)", eyes)

    def test_the_eye_override_still_reaches_every_state(self) -> None:
        pose = self.pose()
        self.assertIn("if let eyeOverride {", pose)
        # Applied after the state's own branch, so no state — marked or not — can skip it.
        self.assertLess(pose.index("switch self {"), pose.index("if let eyeOverride {"))
        for channel in ("pose.blink = eyeOverride.blink",
                        "pose.gazeX = eyeOverride.gazeX",
                        "pose.gazeY = eyeOverride.gazeY",
                        "pose.squint = eyeOverride.squint"):
            self.assertIn(channel, pose)
        # A marked state still carries its own eye channels; the gate is in the renderer, not here,
        # so the override is never the thing that decides whether eyes exist.
        thinking = pose.split("case .thinking:")[1].split("case .reading:")[0]
        self.assertIn("pose.blink", thinking)


class AThinkingBotIsIdleSizedAndWearsIdlesEyes(unittest.TestCase):
    """The report: thinking drew at 42 % and had no eyes, so in a row of bots one was small and
    faceless. Thinking is now idle's body and idle's eyes, distinguished by what it does with them.
    """

    def code(self, text: str) -> str:
        """The source with its comments stripped: a guard must read the code, not the prose."""
        return "\n".join(line.split("//")[0] for line in text.splitlines())

    def pose(self) -> str:
        source = read(STATE)
        return source[source.index("public func pose("):source.index("    /// A state that starts part way through itself")]

    def branch(self, label: str) -> str:
        return self.code(self.pose().split(f"case .{label}:")[1].split("case .")[0])

    def renderer_draw(self) -> str:
        return read(RENDERER).split("public static func draw(")[1].split("// MARK: - View maths")[0]

    def eyes(self) -> str:
        return read(RENDERER).split("static func drawEyes(")[1].split("// MARK: - Ribbons")[0]

    def test_thinking_is_drawn_at_the_resting_scale(self) -> None:
        thinking = self.branch("thinking")
        # 0.42 was the shrink; the channel itself is gone now, so no state can resize at all.
        self.assertNotIn("pose.bodyScale", thinking, "thinking is drawn smaller than idle again")
        self.assertNotIn("bodyScale", self.code(read(STATE)),
                         "the pose grew a body scale again")
        # No squash or stretch either: the pulse it keeps is a lift, which moves the body without
        # resizing it, and every state breathes on the same resting envelope.
        for channel in ("pose.sx =", "pose.sy ="):
            self.assertNotIn(channel, thinking, f"thinking squashes its body ({channel})")
        self.assertIn("rest(1)", thinking)
        self.assertIn("rest(1)", self.branch("idle"))

    def test_thinking_draws_eyes_instead_of_suppressing_them(self) -> None:
        thinking = self.branch("thinking")
        self.assertNotIn("pose.mark", thinking, "thinking hands its face to a mark again")
        # Nothing gates the face any more: there is no mark to weigh it against, the eyes are
        # drawn unconditionally, and nothing in the renderer branches on a state name.
        draw = self.renderer_draw()
        self.assertNotIn("givesWay", draw)
        renderer = read(RENDERER)
        self.assertNotIn("case .thinking", renderer, "the renderer must not special-case a state")
        self.assertEqual(draw.count("drawEyes("), 1,
                         "the eyes are drawn once per frame, whichever state asked")

    def test_thinking_wears_idles_eyes_exactly(self) -> None:
        thinking = self.branch("thinking")
        # `squint` and `arch` are the channels that reshape an eye; a state that sets neither
        # draws exactly the pair idle draws — same pill, same size, same place. (`slit`, a third
        # shape, is gone: no state replaces an eye's shape now.)
        for channel in ("pose.squint", "pose.slit", "pose.arch"):
            self.assertNotIn(channel, thinking, f"thinking reshapes its eyes ({channel})")
        eyes = self.eyes()
        self.assertIn("let eyes = model.definition.eyes", eyes)
        self.assertIn("let centers = OpenBotAvatarGeometry.eyeCenters(eyes)", eyes)
        # It still looks: a gaze and a slower blink move the same eyes rather than replacing them.
        self.assertIn("pose.gazeX = 0.55", thinking)
        self.assertIn("pose.gazeY = -0.8", thinking)
        self.assertIn("Self.blink(seed: seed, time: t * 0.7)", thinking)
        self.assertIn("pose.roll = -5", thinking)

    def test_no_mark_can_be_drawn_over_a_face_that_has_eyes(self) -> None:
        # The mark that sat over thinking's eyes went first; the one that sat over blocked's whole
        # body went with it — and it stayed gone when 0.5.0 brought the mark machinery back for
        # definitions of a host's own. No built-in state marks itself, so the mark list the renderer
        # draws from is empty for all eight, and the face is never weighted against a mark.
        self.assertNotIn("pose.marks", self.pose(), "a state handed its face to a mark again")
        self.assertNotIn("pose.slit", self.pose(), "a state replaced an eye's shape again")
        renderer = self.code(read(RENDERER))
        # The renderer's marks come from the pose — there is no per-mark field, and no state's name.
        self.assertIn("markShapes(pose.marks,", renderer)
        for gone in ("case .bang", "case .dots", "OpenBotAvatarMark.bang", "markScale"):
            self.assertNotIn(gone, renderer, f"the renderer still reads {gone!r}")

    def test_a_blink_from_the_shared_motion_reaches_thinking(self) -> None:
        pose = self.pose()
        override = pose.split("if let eyeOverride {")[1]
        self.assertIn("pose.blink = eyeOverride.blink", override)
        self.assertIn("pose.squint = eyeOverride.squint", override)
        # Applied after the state's branch, and no branch returns early, so thinking obeys it.
        self.assertGreater(pose.index("if let eyeOverride {"), pose.index("switch self {"))
        self.assertEqual(self.code(pose).count("return"), 1,
                         "a state that returns early would skip the override")

    def test_the_states_this_fix_does_not_touch_are_drawn_exactly_as_they_were(self) -> None:
        # Pinned: the resting pace each untouched state breathes on, and every squash it adds.
        for label, pace in [("idle", "rest(1)"), ("reading", "rest(1.1)"),
                            ("working", "rest(1.3)"), ("computer", "rest(1.2)")]:
            self.assertIn(pace, self.branch(label), f"{label} changed its resting pose")
        working = self.branch("working")
        self.assertIn("pose.sy = 0.99 - 0.008 * beat", working)
        self.assertIn("pose.sx = 1.005 + 0.005 * beat", working)
        # Working narrows its eyes at its work: a shape the mood does not own, and not a shrink.
        self.assertIn("pose.squint = 0.25", working)
        # Idle keeps its happy hop; and no untouched state may shrink, because the channel is gone.
        for label in STATES:
            self.assertNotIn("pose.bodyScale", self.branch(label), label)


class WaitingBlockedAndDoneAreIdleSizedWithTheirOwnLook(unittest.TestCase):
    """The report after thinking's: waiting flattened its eyes to slits, blocked gave its body and
    its face up to an exclamation mark at 32 %, and done *set* its eyes' neutral shape. All three
    now draw idle's body at idle's size with idle's eyes, and say what they are in motion only.

    The four channels a state has left are gaze, blink rate, lean and the shape of its breathe and
    pulse; the eye's shape belongs to the mood (`arch`) and to the shared frame (`squint`).
    """

    def code(self, text: str) -> str:
        """The source with its comments stripped: a guard must read the code, not the prose."""
        return "\n".join(line.split("//")[0] for line in text.splitlines())

    def pose(self) -> str:
        source = read(STATE)
        return source[source.index("public func pose("):source.index("    /// A state that starts part way through itself")]

    def branch(self, label: str) -> str:
        return self.code(self.pose().split(f"case .{label}:")[1].split("case .")[0])

    def test_no_state_in_the_switch_resizes_the_body_or_sets_a_mark(self) -> None:
        switch = self.code(self.pose().split("switch self {")[1])
        # `pose.marks` covers `pose.mark`: a built-in state may not name a mark at all, nor a scale.
        # (`done` sets `pose.cage`, which is ribbons on hoops, not a mark.)
        for channel in ("bodyScale", "markScale", "pose.marks", "pose.slit"):
            self.assertNotIn(channel, switch, f"a state sets {channel!r} again")
        # The one give-way in the codebase is the pose's marks and nothing else: there is no second
        # resting scale a state could name, and no mark type in the state file's own vocabulary.
        state = self.code(read(STATE))
        self.assertIsNone(re.search(r"\bOpenBotAvatarMark\b", state),
                          "a per-mark field came back to the pose")
        self.assertIn("public static func bodyScale(_ marks: [PoseMark]) -> Double", read(MARKS))

    def test_waiting_keeps_idles_eyes_and_waits_with_its_look(self) -> None:
        waiting = self.branch("waiting")
        for channel in ("pose.squint", "pose.slit", "pose.arch"):
            self.assertNotIn(channel, waiting, f"waiting reshapes its eyes ({channel})")
        self.assertIn("rest(0.9)", waiting)                             # a slower, deeper breath
        self.assertIn("pose.roll = 7 + 1.2 * wave(6.4, 2)", waiting)    # the lean, held aside
        self.assertIn("pose.gazeX = 0.5 + 0.15 * wave(8.2)", waiting)   # eyes on what it waits for
        self.assertIn("pose.gazeY = 0.1", waiting)
        self.assertIn("Self.blink(seed: seed, time: t * 0.6)", waiting)  # a slower blink than idle
        # Idle's eyes wander and come back to the centre; waiting's are held to one side and stay.
        self.assertNotIn("Self.wander", waiting)
        self.assertIn("Self.wander", self.branch("idle"))

    def test_blocked_keeps_idles_eyes_and_says_it_in_the_body(self) -> None:
        blocked = self.branch("blocked")
        for channel in ("pose.squint", "pose.slit", "pose.arch"):
            self.assertNotIn(channel, blocked, f"blocked reshapes its eyes ({channel})")
        # No squash of its own: it breathes on the same envelope as everyone, just slower.
        for channel in ("pose.sx =", "pose.sy ="):
            self.assertNotIn(channel, blocked, f"blocked squashes its body ({channel})")
        self.assertIn("rest(0.6)", blocked)          # the slowest, stillest breathe in the set
        self.assertIn("pose.gazeX = 0", blocked)     # looks straight back at you
        self.assertIn("pose.gazeY = 0", blocked)
        self.assertIn("pose.blink = 0", blocked)     # and does not blink
        self.assertIn("pose.lift = reducedMotion ? 0 : -1.15 * (1 - cos(2 * .pi * t / 2.9))", blocked,
                      "blocked lost the deep slow pulse that is its notice")
        # Deep, not just long: deeper than idle's, thinking's or working's breathe.
        for shallower in ("-0.45 * (1 - cos(2 * .pi * t / (3.4 * pace)))", "-0.5 * (1 - cos(2 * .pi * t / 5.2))"):
            self.assertIn(shallower, self.pose())
        self.assertNotIn("1.2 * sin(.pi * p)", blocked)

    def test_blocked_notice_is_motion_and_the_light_table_is_untouched(self) -> None:
        # A solid face has no rim to show, so blocked's notice cannot be a brighter rim: it is the
        # body pulse, and the reference's light row stays where it is (0.50/0.15, tint −15 %).
        table = read(AVATAR / "OpenBotAvatarMaterialPaint.swift")
        table = table.split("var glassPulse: GlassPulse {")[1].split("func light(")[0]
        blocked = table.split("case .blocked:")[1].split("case .done:")[0]
        self.assertIn("GlassPulse(rim: 0.50, halo: 0.15, desaturate: 0.15)", blocked,
                      "blocked's light was made loud instead of its body")

    def test_done_keeps_its_hold_and_stops_setting_the_neutral_arch(self) -> None:
        done = self.branch("done")
        self.assertIn("rest(1.25)", done)                   # idle's body, a slower breath
        # 0.5.0's celebration, timed from the state's age: a turn of 3.87 s inside the cage, a rest,
        # and after 6.2 s (up to a seventh longer, per avatar) again, the other way round. A surface
        # that gives no age runs the cycle on the clock, which is what a row and the pet always did.
        self.assertIn("let age = !reducedMotion ? max(0, stateAge ?? t) : Self.doneTurnSeconds", done)
        self.assertIn("let length = Self.doneCycleSeconds * (1 + 0.15 * Self.noise(seed, 31))", done)
        self.assertIn("if since < Self.doneTurnSeconds {", done, "done lost the window it turns in")
        self.assertIn("pose.yaw += Self.near(sweep / 3)", done, "the body turns a third as often")
        self.assertIn("pose.cage = 1", done, "done lost its cage")
        self.assertIn("pose.sweep = way * max(0, Self.celebration(since))", done)
        self.assertIn("let way: Double = cycle.truncatingRemainder(dividingBy: 2) != 0 ? -1 : 1", done)
        # The mood owns the eye's shape: a happy bot arcs, a neutral one leaves the pill alone.
        self.assertIn("if mood == .happy { pose.arch = 1 }", done)
        self.assertNotIn("pose.arch = mood", done, "done sets the neutral eye shape again")
        # The hold before idle is `BotAvatarActivity`'s clock, guarded by
        # `test_bot_states.DoneIsHeldThenFallsToIdle`; this fix deliberately does not touch it.

    def test_the_three_do_not_move_alike(self) -> None:
        channels = {label: tuple(sorted(set(re.findall(r"pose\.(\w+)", self.branch(label)))))
                    for label in ("waiting", "blocked", "done")}
        self.assertEqual(len(set(channels.values())), 3,
                         "two of waiting/blocked/done now move the same channels")
        # And the one direction that tells blocked from waiting at a glance: blocked is looking at
        # you, waiting is looking at something else.
        self.assertIn("pose.gazeX = 0", self.branch("blocked"))
        waiting_gaze = re.search(r"pose\.gazeX = (-?[\d.]+)", self.branch("waiting"))
        assert waiting_gaze is not None
        self.assertNotEqual(float(waiting_gaze.group(1)), 0, "waiting stares at you like blocked")


class AnIdleBotHoversAndOnlyAnIdleBot(unittest.TestCase):
    """The ask: a gentle float while a bot is idle — noticeable in a 24 pt row and at 200 pt, never a
    bob — on the clock the pose already has, phased per avatar, gone under Reduce Motion, and absent
    from the other seven states.

    The drawing is SwiftUI, so what a guard can hold from the source is this: the float is one more
    term of the pose (one sine on the pose's own `time`, no timer, no display link, no layer of its
    own), its numbers are in the band the ask named and cannot carry the body out of the validated
    box, Reduce Motion returns exactly nothing, and the seven states that are not idle still draw the
    lifts they drew before it existed.
    """

    def code(self, text: str) -> str:
        """The source with its comments stripped: a guard must read the code, not the prose."""
        return "\n".join(line.split("//")[0] for line in text.splitlines())

    def pose(self) -> str:
        source = read(STATE)
        return source[source.index("public func pose("):source.index("    /// A state that starts part way through itself")]

    def branch(self, label: str) -> str:
        return self.code(self.pose().split(f"case .{label}:")[1].split("case .")[0])

    def hover(self) -> str:
        source = read(STATE)
        return self.code(source[source.index("static func hover("):].split("// MARK:")[0])

    def number(self, name: str) -> float:
        found = re.search(rf"static let {name} = ([\d.]+)", self.code(read(STATE)))
        assert found is not None, f"{name} is gone"
        return float(found.group(1))

    def test_the_hover_lives_in_one_place(self) -> None:
        # One amplitude, one period, one function — the whole feature, named, in one block.
        state = self.code(read(STATE))
        for declaration in (r"static let hoverAmplitude\b", r"static let hoverPeriodSeconds\b",
                            r"static func hover\("):
            self.assertEqual(len(re.findall(declaration, state)), 1, f"{declaration} is declared twice")
        # And nowhere else: no surface, no renderer and no definition file grows a hover of its own.
        for path in (RENDERER, VIEW, DEFINITIONS):
            with self.subTest(file=path.name):
                self.assertNotIn("hoverAmplitude", read(path))
                self.assertNotIn("hoverPeriodSeconds", read(path))
                self.assertNotIn("static func hover(", read(path))

    def test_only_idle_floats(self) -> None:
        idle = self.branch("idle")
        # It rides `lift`, the channel every state already draws its height on, so the renderer needs
        # nothing new to draw it: positive `hover` is up, and `lift` is negative-up.
        self.assertIn("pose.lift -= Self.hover(seed: seed, time: t, reducedMotion: reducedMotion)", idle)
        # Exactly one call in the whole pose: a second one would be a second float to keep in step.
        self.assertEqual(self.code(self.pose()).count("Self.hover("), 1)
        for label in STATES:
            if label == "idle":
                continue
            self.assertNotIn("hover", self.branch(label), f"{label} hovers too")
        # A happy idle hops instead: the hover is the neutral idle's, not a second motion under the hop.
        self.assertIn("pose.lift -= Self.hover(", idle.split("if mood == .happy {")[1])

    def test_the_hover_rides_the_poses_own_clock(self) -> None:
        # The phase comes from the pose's own time (`t`, already shifted per seed) — nothing here
        # starts a clock, a queue, a task or a per-avatar animation object.
        self.assertIn("time: t", self.branch("idle"))
        self.assertIn("let turn = time / hoverPeriodSeconds + noise(seed, 3001)", self.hover())
        state = self.code(read(STATE)) + self.code(read(RENDERER))
        for forbidden in ("Timer", "CADisplayLink", "DispatchQueue", "withAnimation", "Task {",
                          "TimelineView", ".animation(", "asyncAfter"):
            self.assertNotIn(forbidden, state, f"the avatar started its own clock: {forbidden!r}")

    def test_reduce_motion_draws_todays_pose(self) -> None:
        # The gate is inside the one function, so no call site can forget it…
        self.assertIn("guard !reducedMotion else { return 0 }", self.hover())
        # …and the pose's flag reaches it.
        self.assertIn("reducedMotion: reducedMotion", self.branch("idle"))
        # Reduce Motion is also what a paused, offscreen or too-small avatar passes (a 20 pt row in a
        # list, a window in the background), so those paths do no extra work: the timeline is paused
        # and the pose is the still one.
        view = read(VIEW)
        self.assertIn("paused: !moves", view)
        self.assertIn("reducedMotion: !moves", view)
        self.assertIn("Double(size) >= animatingFrom", view)

    def test_the_other_seven_states_draw_the_lifts_they_drew(self) -> None:
        # Pinned as they were before the hover: the four states with a lift of their own…
        for label, line in [
            ("thinking", "pose.lift = reducedMotion ? 0 : -0.5 * (1 - cos(2 * .pi * t / 5.2))"),
            ("working", "pose.lift += -0.3 * (0.5 + 0.5 * beat) * live"),
            ("blocked", "pose.lift = reducedMotion ? 0 : -1.15 * (1 - cos(2 * .pi * t / 2.9))"),
            ("done", "pose.lift -= 2.2 * swell"),
        ]:
            self.assertIn(line, self.branch(label), f"{label}'s lift changed")
        # …and the three that take their height from `rest` alone, which still take it from `rest` alone.
        for label, pace in (("reading", "rest(1.1)"), ("computer", "rest(1.2)"), ("waiting", "rest(0.9)")):
            branch = self.branch(label)
            self.assertIn(pace, branch, f"{label} changed its breath")
            self.assertNotIn("pose.lift", branch, f"{label} grew a lift of its own")
        # Idle owns exactly two writes to `lift`: its hop's and the hover's, one term more than today.
        self.assertEqual(len(re.findall(r"pose\.lift", self.branch("idle"))), 2)

    def test_the_numbers_are_in_the_band_and_stay_in_frame(self) -> None:
        amplitude = self.number("hoverAmplitude")       # units: hundredths of the avatar's side
        period = self.number("hoverPeriodSeconds")
        self.assertGreaterEqual(amplitude, 1.5, "a hover this small cannot be seen at 24 pt")
        self.assertLessEqual(amplitude, 2.5, "a hover this large is a hop")
        self.assertGreaterEqual(period, 3.5, "faster than this reads as a bob")
        self.assertLessEqual(period, 5.0, "slower than this stalls")
        # Percent of the side, not points: the excursion at 24/48/200 pt is the same fraction of the
        # body, so it is as visible on a row's avatar as on the pet.
        for side in (24, 48, 200):
            self.assertGreater(amplitude / 100 * side, 0.3, f"invisible at {side} pt")
        # The body is validated inside 6…94 of the 0…100 box, so ± this amplitude cannot reach the
        # frame's edge — the float trades height only.
        self.assertLessEqual(amplitude, BODY_MIN)
        self.assertLessEqual(amplitude, 100 - BODY_MAX)
        # No size change at all: a body that grew and shrank is a breath, and the breath is `rest`'s.
        # The hover's own line names no scale, and idle's only size write is still the happy hop's.
        for channel in ("pose.sx", "pose.sy", "pose.scale"):
            self.assertNotIn(channel, self.hover(), f"the hover changes {channel}")
        self.assertEqual(len(re.findall(r"pose\.sx", self.branch("idle"))), 0)
        self.assertEqual(len(re.findall(r"pose\.sy", self.branch("idle"))), 1)

    def test_the_renderer_adds_no_layer_for_it(self) -> None:
        renderer = self.code(read(RENDERER))
        self.assertNotIn("hover", renderer, "the renderer learned about the hover")
        # The float rides the transform a frame already takes: the body's root moves by `pose.lift`,
        # and the ribbons' rim follows that same lift. Two readers, both older than the float.
        self.assertIn("CGAffineTransform(translationX: 0, y: CGFloat(pose.lift))", renderer)
        self.assertEqual(renderer.count("pose.lift"), 2)


class TheVolumeIsInferredAndProjected(unittest.TestCase):
    """The point of the port: depth from a silhouette, not a flat fill."""

    def test_the_volume_is_built_from_cross_sections(self) -> None:
        source = read(VOLUME)
        self.assertIn("OpenBotAvatarGeometry.field", source)
        self.assertIn("OpenBotAvatarGeometry.contours", source)
        self.assertIn("surfaceHeight", source)
        self.assertIn("insetDistance", source)
        self.assertIn("eyePlanes", source)
        # The stack is centred on z = 0 in both directions, which is what makes it a volume.
        self.assertIn("for z in [level, -level]", source)

    def test_the_projection_is_the_contracts_matrix(self) -> None:
        source = read(RENDERER)
        self.assertIn("static func planeTransform", source)
        self.assertIn("basis.sinYaw * basis.sinPitch", source)
        self.assertIn("basis.cosPitch", source)

    def test_no_frame_allocation_claim_is_kept(self) -> None:
        # The model is cached by definition, so a frame transforms paths rather than building them.
        source = read(RENDERER)
        self.assertIn("static var cache: [String: OpenBotAvatarModel]", source)
        self.assertIn("cacheLimit", source)
        view = read(VIEW)
        self.assertIn("frameInterval = 0.1", view)


class TheHostStoresAndRefuses(unittest.TestCase):
    def test_the_route_validates_and_answers_400(self) -> None:
        source = read(RUST_ROUTES)
        self.assertIn("crate::bot_avatar::validate(definition)", source)
        self.assertIn("StatusCode::BAD_REQUEST", source)
        self.assertIn("invalid avatar definition:", source)
        self.assertIn('entry["definition"] = spec.to_json()', source)

    def test_the_document_keeps_the_face_beside_the_avatar(self) -> None:
        source = read(RUST_ROUTES)
        self.assertIn('entry["avatar"]', source)
        self.assertIn('entry["color"]', source)
        # An old client that only sends `avatar` must not delete the avatar it cannot see.
        self.assertIn('body.get(key).is_some()', source)

    def test_the_host_and_the_app_enforce_the_same_rules(self) -> None:
        rust = read(RUST_AVATAR)
        for rule in [
            "version must be 1",
            "id must be a lowercase slug",
            "name must be 1-40 printable characters",
            "eyes.scale",
            "eyes.spacing",
            "eyes must sit inside the body",
            "body.path leaves the safe area",
        ]:
            self.assertIn(rule, rust, f"the host is missing the {rule!r} rule the app enforces")
        self.assertIn("BODY_MIN: f64 = 6.0", rust)
        self.assertIn("BODY_MAX: f64 = 94.0", rust)

    def test_the_rust_tests_round_trip_and_refuse(self) -> None:
        routes = read(RUST_ROUTES)
        self.assertIn("a_definition_and_colour_round_trip_through_the_document", routes)
        self.assertIn("an_invalid_definition_is_refused_and_nothing_is_written", routes)
        self.assertIn("a_bad_colour_is_refused", routes)
        avatar = read(RUST_AVATAR)
        self.assertIn("the_contract_example_validates_and_round_trips", avatar)


class BothAppsOfferTheAvatarTab(unittest.TestCase):
    def test_the_mac_settings_have_an_avatar_tab(self) -> None:
        source = read(MAC_SETTINGS)
        self.assertIn("case avatar = \"Avatar\"", source)
        self.assertIn("case about = \"About\"", source)
        self.assertIn("OpenBotAvatarEditor(", source)
        self.assertIn("store.saveBotAvatar", source)
        self.assertIn("store.botAvatars[bot.id]", source)

    def test_the_phone_settings_have_an_avatar_tab(self) -> None:
        source = read(IOS_SETTINGS)
        self.assertIn("case avatar = \"Avatar\"", source)
        self.assertIn("case about = \"About\"", source)
        self.assertIn("OpenBotAvatarEditor(", source)
        self.assertIn("saveAvatar", source)

    def test_the_editor_can_only_write_an_avatar(self) -> None:
        source = read(EDITOR)
        # The only thing the editor saves is a face; there is no soul or config vocabulary in it.
        # Retargeted when the Classic row arrived: the document now travels inside a
        # `BotAvatarSelection`, so that saving one family clears the other in the same request. The
        # document still carries the definition, its colour and its material, in one call.
        self.assertRegex(source, r"BotAvatarSelection\.custom\(BotAvatarDocument\(definition: draft,\s*\n\s*color: colorHex,\s*\n\s*material: material\)\)")
        self.assertIn("try await save(nil)", source)
        # Look at the code, not the prose: the doc comment above explains *why* it never touches them.
        code = "\n".join(line.split("//")[0] for line in source.splitlines())
        for forbidden in ("Soul", "configureDescription", "saveSoul", "bot.soul", "config.write"):
            self.assertNotIn(forbidden, code, f"the avatar editor reaches for {forbidden!r}")


class ABotWithoutADefinitionKeepsItsPicture(unittest.TestCase):
    def test_the_shared_avatar_view_branches_on_the_definition(self) -> None:
        source = read(BOT_AVATAR_VIEW)
        self.assertIn("if let definition {", source)
        self.assertIn("OpenBotAvatarView(", source)
        self.assertIn("} else {", source)
        self.assertIn("shapeBody", source)

    def test_both_rows_and_headers_resolve_the_stored_definition(self) -> None:
        # They no longer pass it: `BotAvatarView` resolves the stored avatar from the environment,
        # so a row and a header get it without naming it — and a surface added later cannot forget
        # (2026-11-24, the report that a new avatar never reached Settings or the bot panel).
        for path in (MAC_ROW, IOS_ROW, MAC_HEADER, IOS_HEADER):
            source = read(path)
            with self.subTest(file=path.name):
                self.assertIn("BotAvatarView(", source)
                self.assertNotIn("definition:", source)
                self.assertNotIn("avatarColor:", source)

    def test_the_pet_draws_a_definition_instead_of_its_picture(self) -> None:
        source = read(MAC_PET)
        self.assertIn("if let avatar = pet.avatar", source)
        self.assertIn("OpenBotAvatarView(", source)
        self.assertIn("BotAvatarStill(", source)

    def test_both_stores_carry_the_definition_from_the_host(self) -> None:
        self.assertIn("botAvatars", read(MAC_STORE))
        self.assertIn("loadAvatars()", read(MAC_STORE))
        self.assertIn("botAvatars", read(IOS_ENV))
        self.assertIn("loadAvatars()", read(IOS_ENV))


if __name__ == "__main__":
    unittest.main()
