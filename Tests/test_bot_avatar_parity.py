"""The ported bot-avatar must be the reference's avatar, not a lookalike.

The module is SwiftUI code, so most of it cannot compile off-device — which is exactly the gap this
file guards. It reads the Swift sources and checks the three things a copy can silently get wrong:

* the eight SVG paths, character for character (a reformatted path is a different drawing),
* the palette order and hexes (the identity hash indexes into it),
* the activity tool sets and their precedence (a missing tool name is a wrong face, and the order is
  the difference between `computer` and `reading`).

The hash and colour table is recomputed here from the reference's own algorithm and compared with
the table pasted into the Swift tests, so a change to either side shows up as a failure. When the
reference checkout is present the paths, the palette and the tool sets are diffed against the
TypeScript itself; when it is not, the hardcoded expectations below still apply.

Port source of truth: `packages/core/src/bot-avatar-shapes.ts`, `bot-avatar-colors.ts`,
`logo-avatar-activity.ts` and `packages/contracts/src/bot-avatar.ts`.
"""
from __future__ import annotations

import os
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UI = ROOT / "Sources" / "HermeyUI"
KIT = ROOT / "Sources" / "HermesKit"
SHAPES = UI / "BotAvatarShape.swift"
GEOMETRY = UI / "BotAvatarGeometry.swift"
PALETTE = UI / "BotAvatarPalette.swift"
IDENTITY = UI / "BotAvatarIdentity.swift"
# The activity vocabulary lives in `HermesKit`: the wire layer reduces events to it and the
# design system draws it, so it cannot sit in either one alone.
ACTIVITY = KIT / "BotAvatarActivity.swift"
MOTION = UI / "BotAvatarMotion.swift"
VIEW = UI / "BotAvatarView.swift"
PACKAGE = ROOT / "Package.swift"
PARITY_TESTS = ROOT / "Tests" / "HermeyUITests" / "BotAvatarParityTests.swift"
RENDERING_TESTS = ROOT / "Tests" / "HermeyUITests" / "BotAvatarRenderingTests.swift"

# The reference checkout sits beside this repo by default, or wherever `RAKAZO_REF` points: the
# parity pass is optional, so no one machine's absolute layout is baked into the tree.
REFERENCE = Path(os.environ.get("RAKAZO_REF") or ROOT.parent / "rakazo-ref").expanduser()
REF_SHAPES = REFERENCE / "packages" / "core" / "src" / "bot-avatar-shapes.ts"
REF_COLORS = REFERENCE / "packages" / "contracts" / "src" / "bot-avatar.ts"
REF_ACTIVITY = REFERENCE / "packages" / "core" / "src" / "logo-avatar-activity.ts"

SHAPE_ORDER = ["hex", "wedge", "squircle", "tablet", "pebble", "blob", "teardrop", "cloud"]

EXPECTED_COLORS = [
    ("white", "Staff White", "#FFFFFF", None),
    ("violet", "Executive Violet", "#A97EFE", "#8B5CF6"),
    ("green", "Emerald", "#00C972", "#10B981"),
    ("orange", "Forge Orange", "#FF781C", "#F97316"),
    ("cyan", "Cyber Cyan", "#1CC3B0", "#06B6D4"),
    ("blue", "Cobalt Blue", "#2A92FE", "#3B82F6"),
    ("yellow", "Amber Gold", "#FFAF38", "#EAB308"),
    ("brown", "Caramel Bronze", "#A27952", "#8D6E63"),
    ("red", "Crimson Red", "#FF3E51", "#EF4444"),
    ("magenta", "Neon Pink", "#FF5EB1", "#EC4899"),
    ("gray", "Slate Silver", "#94A3B8", "#64748B"),
]

READING_TOOLS = {"read_file", "web_fetch", "read_history", "skill_read"}
WRITING_TOOLS = {"write_file"}
COMPUTER_TOOLS = {
    "computer_observe", "computer_act", "browser_navigate", "browser_snapshot", "browser_act",
    "user_computer_shell", "user_computer_observe", "user_computer_act", "shell", "open_path",
    "launch_app",
}

# identity -> (shippedHash, avatarIdentitySeed, palette id, hex, shape index)
# Produced by running the reference's TypeScript under Node; see the header of the Swift tests.
EXPECTED_IDENTITIES = {
    "research": (1658572492, 350895717, "cyan", "#1CC3B0", 5),
    "nightly-build": (704378051, 524064326, "red", "#FF3E51", 6),
    "ops-bot": (3901881355, 1252198356, "cyan", "#1CC3B0", 4),
    "Hermes": (229322211, 2136888634, "orange", "#FF781C", 2),
    "c0demo0001": (548618470, 2017030033, "green", "#00C972", 1),
    "\U0001F980-bot": (2452827075, 838774396, "red", "#FF3E51", 4),
}


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


# ---------------------------------------------------------------------------
# The reference algorithms, in Python, so the table can be re-derived rather than trusted.


def _i32(value: int) -> int:
    value &= 0xFFFFFFFF
    return value - 0x100000000 if value >= 0x80000000 else value


def _imul(a: int, b: int) -> int:
    return _i32(_i32(a) * _i32(b))


def _ushr(a: int, bits: int) -> int:
    return (a & 0xFFFFFFFF) >> bits


def shipped_hash(value: str) -> int:
    """FNV-1a over UTF-16 code units, as `charCodeAt` reads them."""
    units = value.encode("utf-16-le")
    hash_value = 2166136261
    for index in range(0, len(units), 2):
        unit = units[index] | (units[index + 1] << 8)
        hash_value = _imul(hash_value ^ unit, 16777619)
    return hash_value & 0xFFFFFFFF


def shipped_random(seed: int):
    value = seed & 0xFFFFFFFF

    def draw() -> float:
        nonlocal value
        value = _i32(value + 1831565813)
        nxt = _imul(value ^ _ushr(value, 15), 1 | value)
        nxt = _i32(nxt + _imul(nxt ^ _ushr(nxt, 7), 61 | nxt)) ^ nxt
        nxt = _i32(nxt)
        return (nxt ^ _ushr(nxt, 14)) & 0xFFFFFFFF

    def draw_float() -> float:
        return draw() / 4294967296

    return draw_float


def identity_seed(identity: str) -> int:
    units = identity.encode("utf-16-le")
    hash_value = 0
    for index in range(0, len(units), 2):
        unit = units[index] | (units[index + 1] << 8)
        hash_value = _i32(_imul(hash_value, 32) - hash_value + unit)
    return abs(hash_value)


def resolve_color(identity: str) -> tuple[str, str]:
    constant = 2654435769
    seed = shipped_hash(identity) ^ _imul(1, constant)
    index = int(shipped_random((seed ^ constant) & 0xFFFFFFFF)() * len(EXPECTED_COLORS))
    entry = EXPECTED_COLORS[index % len(EXPECTED_COLORS)]
    return entry[0], entry[2]


# ---------------------------------------------------------------------------
# A small SVG reader, so the path data is checked by drawing it rather than by trusting a regex.


def svg_points(data: str) -> list[tuple[float, float]]:
    tokens = re.findall(r"[MmLlHhVvCcSsQqTtZz]|-?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?", data)
    index = 0
    command = None
    current = (0.0, 0.0)
    start = (0.0, 0.0)
    last_control = None
    points: list[tuple[float, float]] = []

    def number() -> float:
        nonlocal index
        value = float(tokens[index])
        index += 1
        return value

    def pair(relative: bool) -> tuple[float, float]:
        x, y = number(), number()
        return (current[0] + x, current[1] + y) if relative else (x, y)

    def curve(p0, p1, p2, p3=None, steps=16):
        out = []
        for step in range(1, steps + 1):
            t = step / steps
            mt = 1 - t
            if p3 is None:
                out.append((mt * mt * p0[0] + 2 * mt * t * p1[0] + t * t * p2[0],
                            mt * mt * p0[1] + 2 * mt * t * p1[1] + t * t * p2[1]))
            else:
                out.append((mt ** 3 * p0[0] + 3 * mt * mt * t * p1[0] + 3 * mt * t * t * p2[0] + t ** 3 * p3[0],
                            mt ** 3 * p0[1] + 3 * mt * mt * t * p1[1] + 3 * mt * t * t * p2[1] + t ** 3 * p3[1]))
        return out

    while index < len(tokens):
        if re.fullmatch(r"[MmLlHhVvCcSsQqTtZz]", tokens[index]):
            command = tokens[index]
            index += 1
            if command in "Zz":
                current = start
                points.append(current)
                continue
        assert command is not None
        relative = command.islower()
        family = command.upper()
        if family == "M":
            current = pair(relative)
            start = current
            points.append(current)
            command = "l" if relative else "L"
        elif family == "L":
            current = pair(relative)
            points.append(current)
        elif family == "H":
            x = number()
            current = (current[0] + x, current[1]) if relative else (x, current[1])
            points.append(current)
        elif family == "V":
            y = number()
            current = (current[0], current[1] + y) if relative else (current[0], y)
            points.append(current)
        elif family == "C":
            c1, c2, end = pair(relative), pair(relative), pair(relative)
            points.extend(curve(current, c1, c2, end))
            last_control = c2
            current = end
        elif family == "S":
            c1 = ((2 * current[0] - last_control[0], 2 * current[1] - last_control[1])
                  if last_control else current)
            c2, end = pair(relative), pair(relative)
            points.extend(curve(current, c1, c2, end))
            last_control = c2
            current = end
        elif family == "Q":
            control, end = pair(relative), pair(relative)
            points.extend(curve(current, control, end))
            last_control = control
            current = end
        elif family == "T":
            control = ((2 * current[0] - last_control[0], 2 * current[1] - last_control[1])
                       if last_control else current)
            end = pair(relative)
            points.extend(curve(current, control, end))
            last_control = control
            current = end
        else:
            raise AssertionError(f"unhandled command {command}")
    return points


def swift_shapes() -> dict[str, str]:
    source = read(SHAPES)
    found = dict(re.findall(r'case \.([a-z]+):\n\s*return "([^"]+)"', source))
    return found


def swift_palette() -> list[tuple[str, str, str, str | None]]:
    source = read(PALETTE)
    start = source.index("colors: [BotAvatarColorDef] = [")
    body = source[start:source.index("\n    ]", start)]
    rows = re.findall(
        r'BotAvatarColorDef\(id: "([^"]+)", name: "([^"]+)", hex: "([^"]+)"(?:, previousHex: "([^"]+)")?\)',
        body,
    )
    return [(row[0], row[1], row[2], row[3] or None) for row in rows]


def swift_tool_set(name: str) -> set[str]:
    source = read(ACTIVITY)
    match = re.search(name + r": Set<String> = \[(.*?)\]", source, re.S)
    assert match, f"{name} not found in BotAvatarActivity.swift"
    return set(re.findall(r'"([^"]+)"', match.group(1)))


class ThePathsAreTheReferenceArtwork(unittest.TestCase):
    def test_eight_shapes_in_the_reference_order(self) -> None:
        shapes = swift_shapes()
        self.assertEqual(list(shapes), SHAPE_ORDER,
                         "the order is the index order a stored shape_N refers to")

    def test_every_path_draws_a_body_inside_the_view_box(self) -> None:
        for name, data in swift_shapes().items():
            points = svg_points(data)
            self.assertGreater(len(points), 20, f"{name} draws almost nothing")
            xs = [p[0] for p in points]
            ys = [p[1] for p in points]
            self.assertGreater(max(xs) - min(xs), 100, f"{name} is a sliver")
            self.assertGreater(max(ys) - min(ys), 100, f"{name} is a sliver")
            # The view box is "-15 -15 259 259".
            self.assertGreaterEqual(min(xs), -15.5, f"{name} runs off the left")
            self.assertLessEqual(max(xs), 244.5, f"{name} runs off the right")
            self.assertGreaterEqual(min(ys), -15.5, f"{name} runs off the top")
            self.assertLessEqual(max(ys), 244.5, f"{name} runs off the bottom")

    @unittest.skipUnless(REF_SHAPES.exists(), "reference checkout not present")
    def test_paths_are_byte_for_byte_the_reference_strings(self) -> None:
        reference = read(REF_SHAPES)
        expected = {}
        for name in SHAPE_ORDER:
            match = re.search(r"\n  " + name + r':\s*\n?\s*"([^"]+)"', reference)
            self.assertIsNotNone(match, f"{name} missing from the reference")
            assert match is not None
            expected[name] = match.group(1)
        self.assertEqual(swift_shapes(), expected,
                         "a reformatted or retyped path is a different drawing")

    def test_the_geometry_constants_are_the_reference_ones(self) -> None:
        geometry = read(GEOMETRY)
        self.assertIn('viewBoxString = "-15 -15 259 259"', geometry)
        self.assertIn("centreValue: Double = 114.2705", geometry)
        self.assertIn("width: 15,", geometry)
        self.assertIn("height: 52,", geometry)
        self.assertIn("leftCx: centreValue - 22.5", geometry)
        self.assertIn("rightCx: centreValue + 22.5", geometry)
        self.assertIn("cy: centreValue - 8", geometry)
        # The eye bars are fully rounded: half the width.
        self.assertIn("cornerRadius: width / 2", geometry)


class ThePaletteIsTheReferenceList(unittest.TestCase):
    def test_list_order_names_and_hexes(self) -> None:
        self.assertEqual(swift_palette(), EXPECTED_COLORS,
                         "the palette order indexes the identity hash: do not reorder")

    @unittest.skipUnless(REF_COLORS.exists(), "reference checkout not present")
    def test_matches_the_contracts_package(self) -> None:
        blocks = re.findall(
            r'\{\s*id: "([^"]+)",\s*name: "([^"]+)",\s*hex: "([^"]+)"(?:,\s*previousHex: "([^"]+)",?)?\s*\}',
            read(REF_COLORS),
        )
        expected = [(b[0], b[1], b[2], b[3] or None) for b in blocks]
        self.assertEqual(swift_palette(), expected)

    def test_the_eye_tone_thresholds_are_the_reference_ones(self) -> None:
        palette = read(PALETTE)
        self.assertIn('contrastRatio(hex, "#FFFFFF") < 2.4', palette)
        self.assertIn('contrastRatio(hex, "#000000") < 2', palette)
        self.assertIn("0.03928", palette)


class TheHashAndColourRuleIsTheReferenceOne(unittest.TestCase):
    def test_the_resolver_uses_the_reference_constants(self) -> None:
        identity = read(IDENTITY)
        self.assertIn("2_166_136_261", identity)          # FNV offset basis
        self.assertIn("16_777_619", identity)             # FNV prime
        self.assertIn("&+ 1_831_565_813", identity)       # shippedRandom's increment
        self.assertIn("2_654_435_769", identity)          # the XOR constant, both times
        self.assertIn("value.utf16", identity)            # code units, not bytes
        self.assertIn("/ 4_294_967_296", identity)

    def test_expected_table_matches_the_recomputed_reference(self) -> None:
        for identity, (hash_value, seed, color_id, hex_value, shape_index) in EXPECTED_IDENTITIES.items():
            self.assertEqual(shipped_hash(identity), hash_value, identity)
            self.assertEqual(identity_seed(identity), seed, identity)
            self.assertEqual(resolve_color(identity), (color_id, hex_value), identity)
            self.assertEqual(seed % len(SHAPE_ORDER), shape_index, identity)

    def test_the_swift_tests_assert_the_same_table(self) -> None:
        source = read(PARITY_TESTS)
        rows = re.findall(
            r'\("([^"]+)", "([a-z]+)", "(#[0-9A-F]{6})", (\d+), \.([a-z]+)\)', source)
        self.assertGreaterEqual(len(rows), 6, "the resolver table lost its samples")
        for identity, color_id, hex_value, shape_index, shape in rows:
            self.assertIn(identity, EXPECTED_IDENTITIES, f"{identity} is not a reference sample")
            _, _, expected_id, expected_hex, expected_index = EXPECTED_IDENTITIES[identity]
            self.assertEqual((color_id, hex_value), (expected_id, expected_hex), identity)
            self.assertEqual(int(shape_index), expected_index, identity)
            self.assertEqual(shape, SHAPE_ORDER[expected_index], identity)

    def test_the_swift_tests_assert_the_draw_stream(self) -> None:
        source = read(PARITY_TESTS)
        for identity, (hash_value, _, _, _, _) in EXPECTED_IDENTITIES.items():
            self.assertIn(f'("{identity}", {hash_value}, [', source,
                          f"the draw-stream table lost {identity}")
            draws = shipped_random(hash_value)
            first = draws()
            self.assertRegex(source, r"0\.\d{15}", "draws must be pasted at full precision")
            self.assertTrue(0 <= first < 1)


class TheActivityRulesAreTheReferenceOnes(unittest.TestCase):
    def test_tool_sets(self) -> None:
        self.assertEqual(swift_tool_set("readingTools"), READING_TOOLS)
        self.assertEqual(swift_tool_set("writingTools"), WRITING_TOOLS)
        self.assertEqual(swift_tool_set("computerTools"), COMPUTER_TOOLS)

    @unittest.skipUnless(REF_ACTIVITY.exists(), "reference checkout not present")
    def test_tool_sets_match_the_reference_source(self) -> None:
        source = read(REF_ACTIVITY)
        for name, expected in (("READING_TOOLS", READING_TOOLS),
                               ("WRITING_TOOLS", WRITING_TOOLS),
                               ("COMPUTER_TOOLS", COMPUTER_TOOLS)):
            block = re.search(name + r" = new Set\(\[(.*?)\]\)", source, re.S)
            self.assertIsNotNone(block, f"{name} missing from the reference")
            assert block is not None
            self.assertEqual(set(re.findall(r'"([^"]+)"', block.group(1))), expected, name)

    def test_precedence_is_in_the_reference_order(self) -> None:
        source = read(ACTIVITY)
        body = source[source.index("public static func from("):]
        body = body[:body.index("\n    }")]
        order = [
            ("background", body.index("if background")),
            ("failed", body.index('if status == "failed"')),
            ("waiting", body.index("if isWaitingOnUser")),
            ("not-working", body.index("if !isWorking")),
            ("computer", body.index("if computerTools.contains")),
            ("reading", body.index("if readingTools.contains")),
            ("writing", body.index("if writingTools.contains")),
            ("composing", body.index("if composing")),
            ("thinking", body.index("if thinking")),
        ]
        positions = [position for _, position in order]
        self.assertEqual(positions, sorted(positions),
                         "the precedence order is the rule: " + ", ".join(name for name, _ in order))

    def test_the_ring_rule_is_the_reference_data_working_flag(self) -> None:
        activity = read(ACTIVITY)
        self.assertIn("self != .idle && self != .error", activity)


class TheMotionIsTheReferenceKeyframes(unittest.TestCase):
    def test_cycles_are_the_css_animations(self) -> None:
        motion = read(MOTION)
        for activity, seconds in (
            (".idle", "1.8"),        # rakazo-organic-float
            (".reading", "1.6"),     # rakazo-organic-sway
            (".writing", "1.35"),    # rakazo-organic-squash
            (".thinking", "1.1"),    # rakazo-organic-pulse
            (".computer", "2.4"),    # rakazo-organic-turn
            (".working", "1.35"),    # rakazo-organic-ring
            (".waiting", "1.6"),     # rakazo-avatar-breathe
        ):
            self.assertRegex(motion, r"case " + re.escape(activity) + r": return " + re.escape(seconds) + r"\b",
                             f"{activity} cycle length changed")
        self.assertIn("workingRingDuration: Double = 1.2", motion)
        # The four eyes loops and their negative delays.
        for duration, delay in (("6.6", None), ("7.2", "1.4"), ("6.1", "3.2"), ("7.8", "2.1")):
            self.assertIn(f"EyeProgram(duration: {duration}", motion)
        self.assertIn("1.4 / 7.2", motion)
        self.assertIn("3.2 / 6.1", motion)
        self.assertIn("2.1 / 7.8", motion)

    def test_ease_is_the_css_cubic_bezier(self) -> None:
        motion = read(MOTION)
        self.assertIn("x1 = 0.42", motion)
        self.assertIn("x2 = 0.58", motion)


class TheModuleFitsTheRepo(unittest.TestCase):
    def test_test_target_exists_for_the_design_system(self) -> None:
        self.assertIn('name: "HermeyUITests", dependencies: ["HermeyUI"]', read(PACKAGE))

    def test_the_parity_tests_stay_off_device_runnable(self) -> None:
        source = read(PARITY_TESTS)
        self.assertNotIn("import SwiftUI", source,
                         "the parity half must compile without SwiftUI so it runs anywhere")
        self.assertIn("import XCTest", source)
        self.assertTrue(RENDERING_TESTS.exists())
        self.assertIn("import SwiftUI", read(RENDERING_TESTS))

    def test_every_surface_that_draws_a_face_uses_the_one_view(self) -> None:
        # The tripwire this file was written with ("nothing calls this yet") has fired: the view is
        # adopted, so what is pinned now is the *reverse* — no surface may keep a second face.
        surfaces = [
            "Apps/HermesMobile/Views/BotListScreen.swift",
            "Apps/HermesMobile/Views/ConversationScreen.swift",
            "Apps/HermesMobile/Views/ConversationDrawer.swift",
            "Apps/HermesMobile/Views/BotModelSettingsScreen.swift",
            "Apps/HermesMac/Conversation/TranscriptRowView.swift",
            "Apps/HermesMac/Conversation/ConversationHeader.swift",
            "Apps/HermesMac/Workspace/MacBotPanel.swift",
            "Apps/HermesMac/Sidebar/SidebarBotList.swift",
            "Apps/HermesMac/Views/MacBotSettingsSheet.swift",
        ]
        for surface in surfaces:
            self.assertIn("BotAvatarView(", read(ROOT / surface), surface)
        # The Mac's push icon renders the same face offscreen — through `PushIcon`, which is the one
        # place a banner's picture is made.
        root = read(ROOT / "Apps/HermesMac/Workspace/WorkspaceRoot.swift")
        self.assertIn("PushIcon.png(for: id, color: store.botFaces[id]?.raw)", root)
        # The transcript's own working row does not draw the face itself: it hands the bot to
        # `WorkingStatus`, which does — one drawing, two surfaces.
        transcript = read(ROOT / "Apps/HermesMac/Conversation/TranscriptScroll.swift")
        self.assertIn("WorkingStatus(bot: bot, activity: activity, color: color)", transcript)
        self.assertIn("StreamingAssistantBubble(text: model.visibleStreamingText", transcript)

    def test_the_old_face_system_is_gone(self) -> None:
        # One face system, not two: the types the port supersedes are deleted, not left dormant.
        for name in ("BotFaceSpinner.swift", "BotSilhouette.swift", "BotFaceShading.swift"):
            self.assertFalse((UI / name).exists(), name)
        for name in ("BotIconPortrait", "BotFaceSpinner", "BotSilhouette", "BotFaceLight",
                     "NeedsYouFlash", "CompactingZip", "BotWorkingSparks", "PortraitStatus"):
            self.assertNotIn(name, read(UI / "BotIconGallery.swift"), name)
        # And nothing anywhere still declares the old types.
        for path in (ROOT / "Sources").rglob("*.swift"):
            source = read(path)
            self.assertNotIn("enum BotIcon:", source, path.name)
            self.assertNotIn("struct BotFace:", source, path.name)
            self.assertNotIn("struct BotFaceChoice: Hashable, Codable, Sendable {", source, path.name)

    def test_adoption_is_documented_on_the_view(self) -> None:
        view = read(VIEW)
        self.assertIn("BotAvatarView(identity:", view)
        self.assertIn("BotActivityTracker", view)
        self.assertIn("AppModel.activity(forBot:", view)
        # The example must point at real call sites, not invented ones.
        self.assertIn("BotFaceChoice", view)
        # The ring is gone from the face: the reference's shipped bots wear none, and the acting
        # happens in the eyes and body instead (asked for 2026-11-16).
        self.assertNotIn("BotAvatarRing(size:", view)
        # The drawing call composes the port with the performance: since 2026-11-16 the view asks for
        # `performedFrame` (the reference's frame plus the jumps, flips and saccades composed over it),
        # while `BotAvatarMotion.frame` itself stays the untouched port those parity tests pin.
        self.assertIn("BotAvatarMotion.performedFrame(activity: activity", view)


if __name__ == "__main__":
    unittest.main()
