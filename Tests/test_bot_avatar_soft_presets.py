"""The corner softening the twelve starting shapes go through — the Swift rule, and its geometry.

Two kinds of claim live here, as everywhere else in this suite:

* **The Swift text.** The transform exists once, it is called from exactly one place (the preset
  table), a definition a person brings never reaches it, the radius is one proportional constant
  rather than a number per shape, and the result is cached by the path string.
* **The geometry.** The transform is re-implemented below (as the validator and the volume rules
  already are in `test_open_bot_avatar.py`) and then the twelve authored paths are actually
  softened and measured: the outline differs exactly where it had a corner, it never grows past the
  box the shape had, it stays inside the safe area, it keeps its subpaths and its winding, it still
  passes the validator's arithmetic, and the volume it implies still has a slice stack to draw.

The Python port emits a polygon for every subpath of a path it changes; the Swift keeps an *uncut*
subpath's own commands, so a curve stays a curve. That difference cannot move the box, the subpath
count or the fill area by more than a flattening chord (well under 0.1 units), which is the
tolerance used below.
"""
from __future__ import annotations

import math
import re
import unittest
from pathlib import Path

from test_open_bot_avatar import (AVATAR, EYE_MARGIN, PRESETS, ROOT, contains, definition_errors,
                                  eye_outline, flatten, preset_values, read)

SOFTEN = AVATAR / "OpenBotAvatarSoften.swift"
DEFINITION = AVATAR / "BotAvatarDefinition.swift"
EDITOR = AVATAR / "OpenBotAvatarEditor.swift"
RENDERER = AVATAR / "OpenBotAvatarRenderer.swift"
VOLUME = AVATAR / "OpenBotAvatarVolume.swift"
VIEW = AVATAR / "OpenBotAvatarView.swift"
GEOMETRY = AVATAR / "OpenBotAvatarGeometry.swift"

# The Swift's own numbers, re-stated so the port and the source are checked against each other.
CORNER_FRACTION = 0.05
CORNER_TURN = 0.35
EDGE_SHARE = 0.45
PRECISION = 100.0

# The two presets that are already all Bézier: nothing in them turns enough to be a corner, so they
# must come back from the transform byte for byte.
SOFT_BY_AUTHORING = {"blob", "egg"}

# What the artwork's sharp vertices are, counted from the authored paths: documented here because
# the report names them, and because a preset whose path is redrawn should have to say so.
SHARP_CORNERS = {
    "blob": 0, "box": 4, "mug": 6, "sprout": 4, "cat": 6, "egg": 0,
    "bottle": 4, "star": 10, "droplet": 1, "hourglass": 10, "book": 6, "mushroom": 2,
}


def read_swift(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def swift_number(source: str, name: str) -> float:
    match = re.search(rf"\b{name}\s*=\s*([-\d.]+)", source)
    assert match is not None, f"{name} is no longer declared in {SOFTEN.name}"
    return float(match.group(1))


_SWIFT: dict[Path, str] | None = None


def swift_sources() -> dict[Path, str]:
    """Every Swift file in the package and both apps: the call-site guard has to see all of them."""
    global _SWIFT
    if _SWIFT is None:
        _SWIFT = {}
        for root in (ROOT / "Sources", ROOT / "Apps"):
            for path in root.rglob("*.swift"):
                _SWIFT[path] = read_swift(path)
    return _SWIFT


# --------------------------------------------------------------------------- the transform, ported


def unit(a, b):
    dx, dy = b[0] - a[0], b[1] - a[1]
    length = math.hypot(dx, dy)
    return ((dx / length, dy / length) if length > 0 else (0.0, 0.0)), length


def number(value: float) -> str:
    """Swift's `OpenBotAvatarSoften.number`: two decimals, no locale, trailing zeros dropped."""
    hundredths = int(math.floor(abs(value) * PRECISION + 0.5))
    sign = "-" if value < 0 and hundredths else ""
    magnitude = hundredths
    whole, fraction = magnitude // 100, magnitude % 100
    if fraction == 0:
        return f"{sign}{whole}"
    text = (str(fraction // 10) if fraction % 10 == 0
            else f"0{fraction}" if fraction < 10 else str(fraction))
    return f"{sign}{whole}.{text}"


def cleaned(polygon):
    out = []
    for point in polygon:
        if out and math.hypot(point[0] - out[-1][0], point[1] - out[-1][1]) <= 1e-6:
            continue
        out.append(point)
    if len(out) > 2 and math.hypot(out[0][0] - out[-1][0], out[0][1] - out[-1][1]) <= 1e-6:
        out.pop()
    return out


def turn_at(previous, vertex, following):
    """The outline's turn at a vertex in radians: 0 straight, pi/2 square, near pi doubled back."""
    (inward, into), (outward, out) = unit(vertex, previous), unit(vertex, following)
    if into <= 1e-9 or out <= 1e-9:
        return 0.0
    cosine = max(-1.0, min(1.0, inward[0] * outward[0] + inward[1] * outward[1]))
    return math.pi - math.acos(cosine)


def fillet(previous, vertex, following, radius):
    """The circular fillet at one vertex: (start, c1, c2, end), or None. Swift's `fillet`."""
    (inward, into), (outward, out) = unit(vertex, previous), unit(vertex, following)
    if into <= 1e-9 or out <= 1e-9:
        return None
    if turn_at(previous, vertex, following) < CORNER_TURN:
        return None
    cosine = max(-1.0, min(1.0, inward[0] * outward[0] + inward[1] * outward[1]))
    interior = math.acos(cosine)
    half = interior / 2
    sine, tangent_of_half = math.sin(half), math.tan(half)
    if sine <= 1e-6 or tangent_of_half <= 1e-9:
        return None
    walk = min(radius / tangent_of_half, EDGE_SHARE * into, EDGE_SHARE * out)
    if walk <= 1e-6:
        return None
    fillet_radius = walk * tangent_of_half
    start = (vertex[0] + inward[0] * walk, vertex[1] + inward[1] * walk)
    end = (vertex[0] + outward[0] * walk, vertex[1] + outward[1] * walk)
    bisector = (inward[0] + outward[0], inward[1] + outward[1])
    length = math.hypot(*bisector)
    if length <= 1e-9:
        return None
    bisector = (bisector[0] / length, bisector[1] / length)
    distance = fillet_radius / sine
    centre = (vertex[0] + bisector[0] * distance, vertex[1] + bisector[1] * distance)
    sweep = math.pi - interior
    k = 4.0 / 3.0 * math.tan(sweep / 4)
    normal1 = ((start[0] - centre[0]) / fillet_radius, (start[1] - centre[1]) / fillet_radius)
    perpendicular1 = (-normal1[1], normal1[0])
    cross = perpendicular1[0] * (end[0] - centre[0]) + perpendicular1[1] * (end[1] - centre[1])
    side = 1.0 if cross > 0 else -1.0
    control1 = (start[0] + side * perpendicular1[0] * k * fillet_radius,
                start[1] + side * perpendicular1[1] * k * fillet_radius)
    normal2 = ((end[0] - centre[0]) / fillet_radius, (end[1] - centre[1]) / fillet_radius)
    perpendicular2 = (-normal2[1], normal2[0])
    control2 = (end[0] - side * perpendicular2[0] * k * fillet_radius,
                end[1] - side * perpendicular2[1] * k * fillet_radius)
    return start, control1, control2, end


def soften_polygon(polygon, radius):
    """One closed polygon, cut. Returns (start point, ops after it, corners cut)."""
    vertices = cleaned(polygon)
    if len(vertices) < 3 or radius <= 0:
        return None, [], 0
    count = len(vertices)
    corners = [fillet(vertices[i - 1], vertices[i], vertices[(i + 1) % count], radius)
               for i in range(count)]
    cuts = sum(1 for corner in corners if corner is not None)
    if not cuts:
        return None, [], 0

    # Start at the first corner's tangency point and draw its arc at once, so the closing edge is
    # the plain remainder of an edge rather than a chord across a fillet.
    first = corners[0]
    start = first[0] if first is not None else vertices[0]
    ops = []  # ("L", point) | ("C", c1, c2, point)
    if first is not None:
        ops.append(("C", first[1], first[2], first[3]))
    for index, corner in enumerate(corners[1:], start=1):
        if corner is None:
            ops.append(("L", vertices[index]))
        else:
            ops.append(("L", corner[0]))
            ops.append(("C", corner[1], corner[2], corner[3]))
    return start, ops, cuts


def emit(start, ops) -> str:
    parts = [f"M{number(start[0])} {number(start[1])}"]
    for op in ops:
        if op[0] == "L":
            parts.append(f"L{number(op[1][0])} {number(op[1][1])}")
        else:
            _, c1, c2, end = op
            parts.append(f"C{number(c1[0])} {number(c1[1])} {number(c2[0])} {number(c2[1])} "
                         f"{number(end[0])} {number(end[1])}")
    return " ".join(parts) + " Z"


def soften(path: str, fraction: float = CORNER_FRACTION):
    """Swift's `soften(_:)`: (softened path, corners cut, radius). Unchanged when it has no corner."""
    polygons = flatten(path)
    points = [point for polygon in polygons for point in polygon]
    if not points:
        return path, 0, 0.0
    width = max(p[0] for p in points) - min(p[0] for p in points)
    height = max(p[1] for p in points) - min(p[1] for p in points)
    radius = fraction * max(width, height)
    pieces, total = [], 0
    for polygon in polygons:
        start, ops, cuts = soften_polygon(polygon, radius)
        total += cuts
        pieces.append(emit(start, ops) if cuts else emit(polygon[0], [("L", p) for p in polygon[1:]]))
    if not total:
        return path, 0, radius
    return " ".join(pieces), total, radius


# --------------------------------------------------------------------------- measuring the result


def bbox(polygons):
    xs = [p[0] for polygon in polygons for p in polygon]
    ys = [p[1] for polygon in polygons for p in polygon]
    return min(xs), min(ys), max(xs), max(ys)


def signed_area(polygon):
    total = 0.0
    previous = polygon[-1]
    for vertex in polygon:
        total += previous[0] * vertex[1] - vertex[0] * previous[1]
        previous = vertex
    return total / 2


def turn_angles(polygon):
    """The outline's turn at each vertex, in degrees: 0 on a straight run, 90 on a square corner."""
    turns = []
    polygon = cleaned(polygon)  # every closed path flattens to a repeated last point
    count = len(polygon)
    for index in range(count):
        previous, vertex, following = polygon[index - 1], polygon[index], polygon[(index + 1) % count]
        (into, _), (out, _) = unit(vertex, previous), unit(vertex, following)
        cosine = max(-1.0, min(1.0, into[0] * out[0] + into[1] * out[1]))
        turns.append(math.degrees(math.pi - math.acos(cosine)))
    return turns


def sharp_corners(polygons, degrees: float = 20.0) -> int:
    return sum(1 for polygon in polygons for turn in turn_angles(polygon) if turn >= degrees)


def edge_distance(polygon, p):
    best = float("inf")
    previous = polygon[-1]
    for vertex in polygon:
        dx, dy = vertex[0] - previous[0], vertex[1] - previous[1]
        length2 = dx * dx + dy * dy
        if length2:
            t = max(0.0, min(1.0, ((p[0] - previous[0]) * dx + (p[1] - previous[1]) * dy) / length2))
            q = (previous[0] + t * dx, previous[1] + t * dy)
        else:
            q = previous
        best = min(best, math.hypot(p[0] - q[0], p[1] - q[1]))
        previous = vertex
    return best


def inscribed_radius(polygon, step: float = 2.0) -> float:
    """The field's maximum (half the part's thickness), on a coarse grid.

    `OpenBotAvatarGeometry.field` samples the same distance on a 0.35..0.6 grid, so this is a
    deliberately coarse, *under*-estimating stand-in: the numbers below clear thresholds, which is
    the direction a test wants.
    """
    x0, y0, x1, y1 = bbox([polygon])
    best = 0.0
    y = y0 + step / 2
    while y < y1:
        x = x0 + step / 2
        while x < x1:
            if contains([polygon], (x, y)):
                best = max(best, edge_distance(polygon, (x, y)))
            x += step
        y += step
    return best


def part_depth(thickness: float, box) -> float:
    """Swift's `OpenBotAvatarVolume.partDepth`."""
    long_side = max(box[2] - box[0], box[3] - box[1])
    return min(30, max(3, 0.8 * max(thickness, min(0.4 * long_side, 2.4 * thickness))))


def inset_distance(level: float, depth: float, rxy: float, rz: float) -> float:
    """Swift's `OpenBotAvatarVolume.insetDistance`."""
    half = depth / 2
    if rxy <= 0 or rz <= 0 or level <= half - rz:
        return 0.0
    if level >= half:
        return rxy
    s = (level - (half - rz)) / rz
    return rxy * (1 - math.sqrt(max(0.0, 1 - s * s)))


def slice_stack(polygon):
    """What `makePart` would build from one outline: (thickness, depth, deepest inset asked for)."""
    inset = inscribed_radius(polygon)
    thickness = 2 * inset
    depth = part_depth(thickness, bbox([polygon]))
    rxy = min(thickness / 2, depth / 2) * 0.9
    rz = (depth / 2) * 0.85
    half = depth / 2
    steps = max(4, min(14, int(round(rz / 0.8))))
    levels = [half - rz] + [half - rz + rz * math.sin(k / steps * math.pi / 2) for k in range(1, steps)]
    deepest = max(inset_distance(level, depth, rxy, rz) for level in levels if level >= 0.02)
    return thickness, depth, deepest


def self_intersections(polygons) -> int:
    def side(a, b, c):
        return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])

    def crosses(p1, p2, p3, p4):
        d1, d2 = side(p3, p4, p1), side(p3, p4, p2)
        d3, d4 = side(p1, p2, p3), side(p1, p2, p4)
        return (d1 > 0) != (d2 > 0) and (d3 > 0) != (d4 > 0)

    found = 0
    for polygon in (cleaned(polygon) for polygon in polygons):
        count = len(polygon)
        for i in range(count):
            for j in range(i + 2, count):
                if i == 0 and j == count - 1:
                    continue
                if crosses(polygon[i], polygon[(i + 1) % count], polygon[j], polygon[(j + 1) % count]):
                    found += 1
    return found


# The twelve softened once, so each measurement below shares one pass.
_TABLE: list | None = None


def softened_table():
    global _TABLE
    if _TABLE is None:
        rows = []
        for preset_id, path, eyes in preset_values():
            text, corners, radius = soften(path)
            rows.append({"id": preset_id, "authored": path, "soft": text,
                         "corners": corners, "radius": radius, "eyes": eyes})
        _TABLE = rows
    return _TABLE


# --------------------------------------------------------------------------- the Swift text


class TheTransformExistsOnceAndRunsAtLoad(unittest.TestCase):
    def test_the_softener_is_declared_in_exactly_one_file(self) -> None:
        sources = swift_sources()
        declaring = sorted(path.name for path, source in sources.items() if "func softenedPath(" in source)
        self.assertEqual(declaring, [SOFTEN.name],
                         "the corner transform must exist once, or two surfaces soften differently")
        source = read_swift(SOFTEN)
        for name in ("static func soften(_ path: String)", "static func soften(polygon:",
                     "static func fillet(", "static func number(", "static func emit("):
            self.assertEqual(source.count(name), 1, f"{name} is declared more than once")
        # It is one transform, not a per-shape table of hand-drawn paths.
        self.assertNotIn("M20 20", source, "the softener must not carry artwork of its own")

    def test_it_is_called_at_the_preset_table_and_nowhere_else(self) -> None:
        sources = swift_sources()
        touching = sorted(path.name for path, source in sources.items() if "OpenBotAvatarSoften" in source)
        self.assertEqual(touching, sorted([SOFTEN.name, PRESETS.name]),
                         "the soften step belongs to the preset table; a user's path must never meet it")
        presets = read_swift(PRESETS)
        # The prose above the table names it too, so count the code, not the comments.
        code = "\n".join(line.split("//")[0] for line in presets.splitlines())
        self.assertEqual(code.count("OpenBotAvatarSoften.softened"), 1,
                         "one call site: `all`, the table the editor and Random both read")
        self.assertIn(".map(OpenBotAvatarSoften.softened)", code)
        self.assertLess(code.index("public static let all:"),
                        code.index("OpenBotAvatarSoften.softened"))
        # Random and the editor read the softened table (`validated()` maps `all`), not the raw one.
        self.assertIn("try all.map { try $0.validated() }", presets)

    def test_both_readers_take_the_softened_table(self) -> None:
        # The table is the one place softening happens, so the two surfaces that offer presets have
        # to read it: the editor's "start from" row (`all`) and Random (`validated()`, i.e. `all`).
        self.assertIn("OpenBotAvatarPresets.all", read_swift(EDITOR))
        self.assertIn("OpenBotAvatarPresets.validated()", read_swift(AVATAR / "OpenBotAvatarRandom.swift"))
        self.assertIn("all.first { $0.id == id }", read_swift(PRESETS))

    def test_a_users_definition_is_never_softened(self) -> None:
        for path in (DEFINITION, EDITOR, RENDERER, VOLUME, VIEW, GEOMETRY):
            with self.subTest(file=path.name):
                self.assertNotIn("Soften", read_swift(path),
                                 f"{path.name} reaches for the preset softener: a user's geometry is theirs")
        definition = read_swift(DEFINITION)
        decode = definition.split("static func decode(json text: String)")[1].split("private static func describe")[0]
        self.assertIn("return try definition.validated()", decode)
        self.assertNotIn("body =", decode,
                         "a pasted definition is validated as pasted, never rewritten on the way in")
        # The validator returns the definition it was given, eyes and body untouched.
        self.assertIn("body: body, eyes: eyes", definition)
        # …and the softener says which definitions it is allowed to touch.
        source = read_swift(SOFTEN)
        self.assertIn("never", source)
        self.assertIn("pasted", source)
        self.assertIn("`OpenBotAvatarPresets.all`", source)

    def test_the_presets_keep_their_authored_paths(self) -> None:
        authored = {preset_id: path for preset_id, path, _ in preset_values()}
        self.assertEqual(len(authored), 12)
        # Still the sharp text in source: the box is four right angles, the star is ten points.
        self.assertEqual(authored["box"], "M20 20 H80 V80 H20 Z")
        self.assertEqual(authored["star"], "M50 10 L61 34 L88 38 L68 56 L73 82 L50 69 L27 82 "
                                          "L32 56 L12 38 L39 34 Z")
        source = read_swift(PRESETS)
        table = source.split("public static let all: [BotAvatarDefinition] = [")[1].split("]")[0]
        names = [name.strip() for name in table.replace("\n", " ").split(",") if name.strip()]
        self.assertEqual(len(names), 12, "all twelve authored presets are still the table")

    def test_the_radius_is_one_proportional_constant(self) -> None:
        source = read_swift(SOFTEN)
        fraction = swift_number(source, "cornerFraction")
        self.assertEqual(fraction, CORNER_FRACTION)
        self.assertTrue(0.04 <= fraction <= 0.06, "the radius must stay 4-6% of the box")
        self.assertIn("cornerFraction * Swift.max(box.width, box.height)", source,
                      "the radius comes from the shape's own box, not from a table")
        self.assertEqual(swift_number(source, "cornerTurn"), CORNER_TURN)
        self.assertEqual(swift_number(source, "edgeShare"), EDGE_SHARE)
        # No preset names a radius, and no shape is special-cased.
        for _, path, _ in preset_values():
            self.assertNotIn("radius", path)
        self.assertNotIn("if definition.id", source)
        self.assertNotIn("definition.id ==", source)

    def test_the_result_is_cached_by_the_path_string(self) -> None:
        source = read_swift(SOFTEN)
        self.assertIn("private var storage: [String: String]", source)
        self.assertIn("NSLock", source)
        self.assertIn("cache.value(for: path)", source)
        self.assertIn("cache.insert(result, for: path)", source)
        self.assertIn("cacheLimit", source)

    def test_the_softener_cuts_corners_instead_of_blending_the_outline(self) -> None:
        source = read_swift(SOFTEN)
        # No Chaikin weights: those subdivide every edge and shrink the shape toward its centroid,
        # which is what pulls a star's points in and thins a bottle's neck.
        for weight in ("0.75", "0.25"):
            self.assertNotIn(weight, source, "a Chaikin pass would thin the whole outline, not a corner")
        self.assertIn("fillet", source)
        self.assertIn("tangent", source)
        self.assertIn("Chaikin", source, "the choice of a fillet has to be explained where it lives")
        # …and the one Chaikin in the codebase is still the contour smoother, where it belongs.
        self.assertIn("One Chaikin pass", read_swift(GEOMETRY))


# --------------------------------------------------------------------------- the geometry


class TheSoftenedPresetsKeepTheirShape(unittest.TestCase):
    def test_all_twelve_are_softened_except_the_two_already_soft(self) -> None:
        for row in softened_table():
            with self.subTest(preset=row["id"]):
                if row["id"] in SOFT_BY_AUTHORING:
                    self.assertEqual(row["soft"], row["authored"],
                                     f"{row['id']} is all curve: the transform must not touch it")
                    self.assertEqual(row["corners"], 0)
                else:
                    self.assertNotEqual(row["soft"], row["authored"],
                                        f"{row['id']} has sharp corners and came back unchanged")
                    self.assertGreater(row["corners"], 0)

    def test_the_corners_cut_are_the_sharp_vertices_and_no_more(self) -> None:
        for row in softened_table():
            with self.subTest(preset=row["id"]):
                authored = flatten(row["authored"])
                sharp = sharp_corners(authored)
                self.assertEqual(sharp, SHARP_CORNERS[row["id"]],
                                 f"{row['id']}: the sharp-vertex count changed with the artwork")
                self.assertEqual(row["corners"], sharp,
                                 f"{row['id']}: the transform cut {row['corners']} of {sharp} corners")

    def test_no_sharp_vertex_is_left(self) -> None:
        for row in softened_table():
            with self.subTest(preset=row["id"]):
                remaining = sharp_corners(flatten(row["soft"]))
                self.assertEqual(remaining, 0,
                                 f"{row['id']} still has {remaining} vertices turning 20° or more")

    def test_the_softened_path_keeps_its_subpaths_and_winding(self) -> None:
        for row in softened_table():
            with self.subTest(preset=row["id"]):
                before, after = flatten(row["authored"]), flatten(row["soft"])
                self.assertEqual(len(before), len(after),
                                 f"{row['id']}: softening merged or split a subpath")
                for original, rounded in zip(before, after):
                    self.assertEqual(math.copysign(1, signed_area(original)),
                                     math.copysign(1, signed_area(rounded)),
                                     f"{row['id']}: a subpath changed winding (a hole would fill)")
                # A hole is still a hole: the mug's handle must still read as its own part.
                self.assertGreater(abs(signed_area(after[0])), 100.0)

    def test_the_outline_never_grows_past_the_authored_box(self) -> None:
        for row in softened_table():
            with self.subTest(preset=row["id"]):
                x0, y0, x1, y1 = bbox(flatten(row["authored"]))
                nx0, ny0, nx1, ny1 = bbox(flatten(row["soft"]))
                tolerance = 1e-6
                self.assertGreaterEqual(nx0, x0 - tolerance, f"{row['id']} grew to the left")
                self.assertGreaterEqual(ny0, y0 - tolerance, f"{row['id']} grew upward")
                self.assertLessEqual(nx1, x1 + tolerance, f"{row['id']} grew to the right")
                self.assertLessEqual(ny1, y1 + tolerance, f"{row['id']} grew downward")
                # …and it does not shrink away either: the deepest cut a fillet makes is
                # `r / sin(θ/2) - r`, which for the sharpest corner in the twelve (the star's 49°
                # points) is 1.4r — hence the 1.5r bound.
                limit = 1.5 * row["radius"] + tolerance
                for moved, name in ((nx0 - x0, "left"), (ny0 - y0, "top"),
                                    (x1 - nx1, "right"), (y1 - ny1, "bottom")):
                    self.assertLessEqual(moved, limit,
                                         f"{row['id']} lost {moved:.2f} at the {name}, more than a fillet")

    def test_the_softened_outline_stays_inside_the_safe_area(self) -> None:
        for row in softened_table():
            with self.subTest(preset=row["id"]):
                x0, y0, x1, y1 = bbox(flatten(row["soft"]))
                self.assertGreaterEqual(x0, 6.0)
                self.assertGreaterEqual(y0, 6.0)
                self.assertLessEqual(x1, 94.0)
                self.assertLessEqual(y1, 94.0)
                self.assertLessEqual(len(row["soft"]), 6000,
                                     "the parser refuses a path longer than 6000 characters")
                self.assertLessEqual(len(flatten(row["soft"])), 16,
                                     "the parser refuses more than sixteen subpaths")

    def test_no_softened_outline_crosses_itself(self) -> None:
        for row in softened_table():
            with self.subTest(preset=row["id"]):
                self.assertEqual(self_intersections(flatten(row["soft"])), 0,
                                 f"{row['id']}: a fillet folded the outline through itself")

    def test_the_radius_is_proportional_to_each_shape(self) -> None:
        ratios = []
        for row in softened_table():
            x0, y0, x1, y1 = bbox(flatten(row["authored"]))
            self.assertAlmostEqual(row["radius"], CORNER_FRACTION * max(x1 - x0, y1 - y0), places=9)
            ratios.append(row["radius"] / max(x1 - x0, y1 - y0))
        self.assertEqual(len(set(round(ratio, 9) for ratio in ratios)), 1,
                         "every preset takes the same share of its own box")
        # Twelve shapes, one rule: the radii land in a narrow band (3.0 to 4.0 units), none of them
        # a number somebody picked for that shape.
        for row in softened_table():
            self.assertGreater(row["radius"], 2.5)
            self.assertLess(row["radius"], 4.5)

    def test_it_is_idempotent(self) -> None:
        for row in softened_table():
            with self.subTest(preset=row["id"]):
                again, corners, _ = soften(row["soft"])
                self.assertEqual(corners, 0,
                                 f"{row['id']}: softening a softened path found {corners} corners")
                self.assertEqual(again, row["soft"],
                                 "the editor stores what it draws; rounding it again must be a no-op")

    def test_the_star_keeps_five_points(self) -> None:
        # The transform Chaikin would have eaten: the star's ten points. A fillet cuts each tip by
        # `r / sin(θ/2) - r` = 5.3 units at its 49° points, and what is left is still five points.
        row = next(row for row in softened_table() if row["id"] == "star")
        self.assertEqual(row["corners"], 10)
        before, after = flatten(row["authored"]), flatten(row["soft"])
        cx = sum(p[0] for p in after[0]) / len(after[0])
        cy = sum(p[1] for p in after[0]) / len(after[0])
        # Five tips: local maxima of the distance to the outline's own centre, above the inner radius.
        radii = [math.hypot(p[0] - cx, p[1] - cy) for p in after[0]]
        peak = max(radii)
        remeasured = [i for i in range(len(radii))
                      if radii[i] > radii[i - 1] and radii[i] >= radii[(i + 1) % len(radii)]
                      and radii[i] > 0.8 * peak]
        self.assertEqual(len(remeasured), 5,
                         f"the star has {len(remeasured)} points left, not five")
        self.assertGreater(peak, 30, "the points must still reach out; a pebble would not")
        self.assertLess(peak, 40, "…but no point may reach past the authored one")

    def test_the_bottle_and_the_mushroom_keep_their_junctions(self) -> None:
        # Two shapes whose softness is in the *join*, not in the outline: the bottle's neck-to-
        # shoulder (127°) and the mushroom's cap lip (90°).
        for preset_id, corners in (("bottle", 4), ("mushroom", 2)):
            row = next(row for row in softened_table() if row["id"] == preset_id)
            self.assertEqual(row["corners"], corners)
            angles = sorted(round(turn) for polygon in flatten(row["authored"])
                            for turn in turn_angles(polygon) if turn >= 20)
            self.assertEqual(len(angles), corners)
            self.assertEqual(sharp_corners(flatten(row["soft"])), 0)


class TheSoftenedPresetsStillPassTheContract(unittest.TestCase):
    def test_every_preset_validates_before_and_after(self) -> None:
        for row in softened_table():
            with self.subTest(preset=row["id"]):
                self.assertEqual(definition_errors(row["authored"], row["eyes"]), [],
                                 f"{row['id']} did not validate before softening")
                self.assertEqual(definition_errors(row["soft"], row["eyes"]), [],
                                 f"{row['id']} stopped validating after softening")

    def test_the_eyes_still_sit_inside_the_softened_body(self) -> None:
        # The transform moves the outline, and the eyes were placed against the authored one: every
        # eye outline point (plus the 1.2-unit margin) still has to be inside the rounded fill.
        for row in softened_table():
            x, y, spacing, scale = row["eyes"]
            polygons = flatten(row["soft"])
            outside = [(centre, point)
                       for centre in ((x - spacing / 2, y), (x + spacing / 2, y))
                       for point in eye_outline(centre[0], centre[1], scale, EYE_MARGIN)
                       if not contains(polygons, point)]
            self.assertEqual(outside, [], f"{row['id']}: {len(outside)} eye points left the body")

    def test_the_volume_still_has_a_slice_stack(self) -> None:
        # `makePart` infers the thickness from the distance field and asks for cross-sections at
        # insets below it. If the outline got thinner than the deepest inset, that slice is empty
        # and the part would draw as a hole in the middle of its own stack.
        for row in softened_table():
            before, after = flatten(row["authored"]), flatten(row["soft"])
            for original, rounded in zip(before, after):
                with self.subTest(preset=row["id"]):
                    thickness, depth, deepest = slice_stack(rounded)
                    before_thickness, _, deepest_before = slice_stack(original)
                    self.assertGreaterEqual(depth, 3.0, "the depth is clamped from below at 3")
                    self.assertGreater(thickness, 3.0,
                                       f"{row['id']}: the part is too thin to inflate")
                    # `inscribed_radius` is coarse (2-unit grid), so it under-estimates: clearing
                    # the deepest inset here means the real field clears it with room to spare.
                    self.assertGreater(thickness / 2, deepest + 1.0,
                                       f"{row['id']}: the deepest cross-section would be empty")
                    self.assertLess(abs(deepest - deepest_before), 0.1 * max(deepest_before, 1.0),
                                    f"{row['id']}: softening moved the slice stack")
                    self.assertGreater(thickness, before_thickness - 1.0,
                                       f"{row['id']}: softening thinned the part")


if __name__ == "__main__":
    unittest.main()
