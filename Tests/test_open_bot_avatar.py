"""The generated-avatar feature, guarded from the source text.

`OpenBotAvatar` is SwiftUI and the storage is Rust, so neither can be exercised from this suite
directly. What *can* be checked — and is, below — is every fact a port can silently get wrong:

* the definition's field set is the upstream contract's, exactly, and unknown fields are refused;
* the validator implements the contract's rules (version, slug, name, box, eye scale and spacing,
  eyes inside the body) rather than a subset;
* the presets really are valid definitions — this file re-implements the validator's arithmetic and
  runs every shipped path through it, so a preset that drifts below the safe area or puts its eyes
  outside the body fails here;
* all eight states exist and each one takes its own branch of the pose model, with the mark, slit,
  ribbon and lean each state is supposed to have;
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
        pose = source[source.index("public func pose("):source.index("// MARK: - Clocks")]
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

    def test_the_marks_slits_and_ribbons_are_where_the_contract_says(self) -> None:
        source = read(STATE)
        pose = source[source.index("public func pose("):source.index("// MARK: - Clocks")]
        for label, marker in [
            ("thinking", "pose.gazeY = -0.8"),
            ("blocked", "pose.mark = .bang"),
            ("waiting", "pose.slit = 1"),
            ("working", "pose.sweep = 2 * .pi * turn"),
            ("done", "pose.yaw += 2 * .pi * eased"),
            ("reading", "pose.tilt = 0.2"),
            ("computer", "pose.gazeX = 0.55"),
        ]:
            branch = pose.split(f"case .{label}:")[1].split("case .")[0]
            self.assertIn(marker, branch, f"{label} no longer draws its own mark")

    def test_the_renderer_has_a_path_for_each_mark(self) -> None:
        source = read(RENDERER)
        self.assertIn("case .bang:", source)
        self.assertIn("pose.arch >= 0.5", source)
        self.assertIn("pose.slit >= 0.5", source)
        self.assertIn("bodyScale", source)


class OnePairOfEyesInEveryState(unittest.TestCase):
    """A mark is a face, not an ornament over one: no state may draw two pairs of eyes."""

    def renderer_draw(self) -> str:
        return read(RENDERER).split("public static func draw(")[1].split("// MARK: - View maths")[0]

    def eyes(self) -> str:
        return read(RENDERER).split("static func drawEyes(")[1].split("// MARK: - Ribbons")[0]

    def pose(self) -> str:
        source = read(STATE)
        return source[source.index("public func pose("):source.index("// MARK: - Clocks")]

    def test_the_eyes_are_drawn_once_and_never_beside_a_mark(self) -> None:
        draw = self.renderer_draw()
        self.assertEqual(draw.count("drawEyes("), 1,
                         "the eyes must be drawn once per frame, or a state shows two pairs")
        # One gate, one place: the renderer weighs a mark against the face exactly once.
        self.assertEqual(read(RENDERER).count("pose.mark != nil"), 1,
                         "the mark/eyes gate has been copied; it must live in one place")
        gate = draw.split("if !givesWay {")[1].split("}")[0]
        self.assertIn("drawEyes(", gate, "the eyes must be inside the one gate")
        self.assertIn("let givesWay = pose.mark != nil", draw)

    def test_the_only_marked_state_is_blocked(self) -> None:
        pose = self.pose()
        self.assertEqual(pose.count("pose.mark = "), 1,
                         "a state that gives its body up sets its mark here, and only it")
        thinking = pose.split("case .thinking:")[1].split("case .reading:")[0]
        blocked = pose.split("case .blocked:")[1].split("case .done:")[0]
        # Thinking gave its body and its face up to three dots once; it draws a face now.
        self.assertNotIn("pose.mark", thinking, "thinking must not hand its face to a mark again")
        self.assertNotIn("pose.bodyScale", thinking, "thinking must not shrink again")
        self.assertIn("pose.mark = .bang", blocked)
        self.assertIn("pose.bodyScale = 0.32", blocked)

    def test_the_eyes_travel_with_a_body_that_gives_way(self) -> None:
        # The second half of the same defect: the eyes used to keep their full-size positions while
        # the body shrank under them, so even one pair read as loose eyes. They now take the body's
        # own shrink, so no state can leave a pair behind outside the body.
        renderer = read(RENDERER)
        self.assertIn("shrink: shrink", renderer)
        eyes = self.eyes()
        self.assertIn("layer.transform = transform", eyes)
        self.assertIn("\n                .concatenating(shrink)", eyes)
        self.assertNotIn("drawnScale = scale * bodyScale", eyes,
                         "the shrink must not be applied to the eyes twice")

    def test_every_other_overlay_is_on_the_eyes_own_plane(self) -> None:
        eyes = self.eyes()
        # The happy arc, the waiting slit and the neutral pill are one exclusive chain: one shape per
        # eye, never a shape and its replacement.
        chain = eyes.split("if pose.arch >= 0.5 {")[1]
        self.assertIn("} else if pose.slit >= 0.5 {", chain)
        self.assertIn("} else {", chain)
        self.assertEqual(eyes.count("if pose.arch >= 0.5 {"), 1,
                         "the eye's shape is chosen once, not drawn twice")
        # The catchlight is drawn inside the eye it belongs to, in the same loop over the same pair.
        self.assertIn("if catchlight {", chain.split("let pill")[1])
        # The ribbons are behind the body, before the body block, so they cannot cross the face.
        draw = self.renderer_draw()
        self.assertLess(draw.index("drawRibbons("), draw.index("switch spec.fill"),
                        "ribbons must be drawn behind the body")
        self.assertNotIn("drawRibbons", eyes)

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
        return source[source.index("public func pose("):source.index("// MARK: - Clocks")]

    def branch(self, label: str) -> str:
        return self.code(self.pose().split(f"case .{label}:")[1].split("case .")[0])

    def renderer_draw(self) -> str:
        return read(RENDERER).split("public static func draw(")[1].split("// MARK: - View maths")[0]

    def eyes(self) -> str:
        return read(RENDERER).split("static func drawEyes(")[1].split("// MARK: - Ribbons")[0]

    def test_thinking_is_drawn_at_the_resting_scale(self) -> None:
        thinking = self.branch("thinking")
        # 0.42 was the shrink; a state may no longer resize the silhouette it shares with the rest.
        self.assertNotIn("pose.bodyScale", thinking, "thinking is drawn smaller than idle again")
        self.assertIn("public var bodyScale: Double = 1", read(STATE),
                      "the resting scale is the default, so a pose that never names it is idle's")
        self.assertEqual(self.pose().count("pose.bodyScale = "), 1,
                         "only a body that gives way to a mark may shrink")
        self.assertIn("pose.bodyScale = 0.32", self.branch("blocked"))
        # No squash or stretch either: the pulse it keeps is a lift, which moves the body without
        # resizing it, and both states breathe on the same resting envelope.
        for channel in ("pose.sx =", "pose.sy ="):
            self.assertNotIn(channel, thinking, f"thinking squashes its body ({channel})")
        self.assertIn("rest(1)", thinking)
        self.assertIn("rest(1)", self.branch("idle"))

    def test_thinking_draws_eyes_instead_of_suppressing_them(self) -> None:
        thinking = self.branch("thinking")
        self.assertNotIn("pose.mark", thinking, "thinking hands its face to a mark again")
        # The one gate that can suppress a face keys off the mark alone, so a state with no mark
        # cannot reach it; and nothing in the renderer branches on a state name.
        draw = self.renderer_draw()
        self.assertIn("let givesWay = pose.mark != nil", draw)
        self.assertEqual(read(RENDERER).count("pose.mark != nil"), 1,
                         "the mark/eyes gate has been copied; it must live in one place")
        renderer = read(RENDERER)
        self.assertNotIn("case .thinking", renderer, "the renderer must not special-case a state")
        self.assertEqual(draw.count("drawEyes("), 1,
                         "the eyes are drawn once per frame, whichever state asked")

    def test_thinking_wears_idles_eyes_exactly(self) -> None:
        thinking = self.branch("thinking")
        # `squint`, `slit` and `arch` are the only channels that reshape an eye; a state that sets
        # none of them draws exactly the pair idle draws — same pill, same size, same place.
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
        pose = self.pose()
        self.assertEqual(re.findall(r"pose\.mark = \.(\w+)", pose), ["bang"],
                         "only blocked wears a mark, and its body gives way to it")
        # The two are complementary: eyes are drawn only for a body with no mark, and a mark is
        # drawn after them, outside that gate — so nothing can sit over a face that has eyes.
        draw = self.renderer_draw()
        gate = draw.split("if !givesWay {")[1].split("}\n        }")[0]
        self.assertNotIn("drawMark(", gate)
        self.assertGreater(draw.index("if let mark = pose.mark {"), draw.index("if !givesWay {"))
        # The mark that sat over thinking's eyes is gone, path and all.
        self.assertNotIn("dots", self.code(read(RENDERER)),
                         "the mark that hid thinking's eyes is still drawn")

    def test_a_blink_from_the_shared_motion_reaches_thinking(self) -> None:
        pose = self.pose()
        override = pose.split("if let eyeOverride {")[1]
        self.assertIn("pose.blink = eyeOverride.blink", override)
        self.assertIn("pose.squint = eyeOverride.squint", override)
        # Applied after the state's branch, and no branch returns early, so thinking obeys it.
        self.assertGreater(pose.index("if let eyeOverride {"), pose.index("switch self {"))
        self.assertEqual(self.code(pose).count("return"), 1,
                         "a state that returns early would skip the override")

    def test_every_other_state_is_drawn_exactly_as_it_was(self) -> None:
        # Pinned: the resting pace each state breathes on, and every squash or shrink it adds.
        for label, pace in [("idle", "rest(1)"), ("reading", "rest(1.1)"), ("working", "rest(1.3)"),
                            ("computer", "rest(1.2)"), ("waiting", "rest(0.9)"),
                            ("done", "rest(1.25)")]:
            self.assertIn(pace, self.branch(label), f"{label} changed its resting pose")
        working = self.branch("working")
        self.assertIn("pose.sy = 0.99 - 0.008 * beat", working)
        self.assertIn("pose.sx = 1.005 + 0.005 * beat", working)
        blocked = self.branch("blocked")
        self.assertIn("pose.sy = 1.02", blocked)
        self.assertIn("pose.sx = 0.99", blocked)
        self.assertIn("pose.bodyScale = 0.32", blocked)
        self.assertIn("pose.markScale = 1 + 0.04 * wave(2.4)", blocked)
        # And none of them may join thinking in shrinking: the default is the resting scale.
        for label in STATES:
            if label == "blocked":
                continue
            self.assertNotIn("pose.bodyScale", self.branch(label), label)


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
