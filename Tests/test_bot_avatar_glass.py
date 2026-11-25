"""The glass material, guarded from the source text.

The material is SwiftUI drawing on one side and a Rust field on the other, so neither can be
exercised from this suite. What *can* be checked — and is, below — is every fact a port can
silently get wrong:

* the six layers of the reference's spec exist, in order, with its numbers: the ramp's
  0.18/0.55/0.15, the sheen at (0.42, 0.28) with radius 0.6, **one** streak, the rim at 0.035 of the
  side but never under 1 pt, and the contact band;
* the layers a size gets are decided from the size (26 pt is a list row, 26–32 pt the chat header,
  96 pt the pet, 200–320 pt the editor's preview), not from a call site;
* the light table has all eight states with the spec's numbers, and Reduce Motion freezes every
  pulse at its midpoint rather than at its start;
* `blocked` desaturates the tint by 15 % and adds no red: it is calm, not alarmed;
* the pet always takes the two-tone rim and its halo blur is capped to the window's clear margin;
* a light page swaps the rim and adds a dark hairline, because a white rim vanishes on Parchment;
* Solid is the default, its spec is empty, and the 0.1.648 slice-stack drawing is still what a flat
  fill runs;
* `material` round-trips through the host, an unknown value is refused with a reason, absent means
  solid, and clearing the definition clears the material with it;
* the editor offers every row the table holds, at a size that can show a streak.

The material is a table (`BotAvatarMaterialSpec.all`), not a pair of cases: the guards below check
that the renderer reads the spec and the editor lists the table, so a third material is data.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UI = ROOT / "Sources" / "HermeyUI"
AVATAR = UI / "OpenBotAvatar"

MATERIAL = AVATAR / "BotAvatarMaterial.swift"
PAINT = AVATAR / "OpenBotAvatarMaterialPaint.swift"
STATE = AVATAR / "OpenBotAvatarState.swift"
RENDERER = AVATAR / "OpenBotAvatarRenderer.swift"
VIEW = AVATAR / "OpenBotAvatarView.swift"
EDITOR = AVATAR / "OpenBotAvatarEditor.swift"
LIBRARY = UI / "BotAvatarLibrary.swift"
BOT_AVATAR_VIEW = UI / "BotAvatarView.swift"

MAC_PICKER = ROOT / "Apps" / "HermesMac" / "Views" / "MacBotIconPicker.swift"
IOS_PICKER = ROOT / "Apps" / "HermesMobile" / "Views" / "BotIconPicker.swift"
MAC_PET = ROOT / "Apps" / "HermesMac" / "Pets" / "PetView.swift"

RUST_AVATAR = ROOT / "hermeyd" / "src" / "bot_avatar.rs"
RUST_ROUTES = ROOT / "hermeyd" / "src" / "bridge_routes.rs"

PRESETS = AVATAR / "OpenBotAvatarPresets.swift"
RANDOM = AVATAR / "OpenBotAvatarRandom.swift"
PALETTE = UI / "BotAvatarPalette.swift"

STATES = ["idle", "thinking", "reading", "working", "computer", "waiting", "blocked", "done"]

#: The fields a material's spec has to fill in, because the painter reads every one of them.
SPEC_FIELDS = ["material:", "name:", "summary:", "fill:", "halo:", "sheens:", "streaks:",
               "rim:", "contact:", "texture:", "desaturatesWhenBlocked:", "addsEyeCatchlight:"]


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def prose(text: str) -> str:
    """The comments of a Swift file as running text, so a sentence that wraps is still one string."""
    return " ".join(text.replace("///", " ").replace("//", " ").split())


def material_cases() -> list[str]:
    """The cases `BotAvatarMaterial` declares, in order."""
    enum = read(MATERIAL).split("public enum BotAvatarMaterial")[1].split("/// Why a stored material")[0]
    return re.findall(r"^    case (\w+)$", enum, re.MULTILINE)


def table_materials() -> list[str]:
    """The rows of `BotAvatarMaterialSpec.all`, in the order the editor lists them."""
    table = read(MATERIAL).split("static let all: [BotAvatarMaterialSpec] = [")[1].split("]")[0]
    return [row.strip().lstrip(".") for row in table.split(",") if row.strip()]


def rust_materials() -> list[str]:
    """`MATERIALS` from the host, checked against the length its type states."""
    match = re.search(r"pub const MATERIALS: \[&str; (\d+)\] = \[([^\]]+)\]", read(RUST_AVATAR))
    if match is None:
        raise AssertionError("bot_avatar.rs no longer declares MATERIALS")
    names = re.findall(r'"([a-z]+)"', match.group(2))
    assert len(names) == int(match.group(1)), "MATERIALS' length and its entries disagree"
    return names


def material_sentence(materials: list[str]) -> str:
    """The refusal's list, as both sides build it: `"a", "b" or "c"`."""
    quoted = [f'"{material}"' for material in materials]
    return quoted[0] if len(quoted) == 1 else f"{', '.join(quoted[:-1])} or {quoted[-1]}"


def spec_rows() -> dict[str, str]:
    """Each `static let <name> = BotAvatarMaterialSpec(...)` block, by name."""
    source = read(MATERIAL)
    rows: dict[str, str] = {}
    for name in material_cases():
        block = source.split(f"static let {name} = BotAvatarMaterialSpec(")
        if len(block) > 1:
            rows[name] = block[1].split("\n    )")[0]
    return rows


def code(text: str) -> str:
    """The text with its comments removed, so an example written in a doc comment is not a literal."""
    return "\n".join(line.split("///")[0].split("//")[0] for line in text.splitlines())


def case_block(text: str, case: str) -> str:
    """The lines from `case .<case>:` up to the next `case .` — one state's entry in a table."""
    pattern = re.compile(r"case \." + re.escape(case) + r"\s*:\s*(.*?)(?=\n\s*case \.|\n\s*}\s*\n)", re.S)
    match = pattern.search(text)
    return match.group(1) if match else ""


def number(pattern: str, body: str) -> float | None:
    match = re.search(pattern, body)
    return float(match.group(1)) if match else None


class TheSixLayers(unittest.TestCase):
    """The reference's material is six layers over one silhouette, bottom to top."""

    def test_the_layers_are_drawn_in_the_specs_order(self):
        paint = read(PAINT)
        markers = [
            "// 1 — halo",
            "// 2 — the body",
            "// 3 — the form sheen",
            "// 4 — the specular streak",
            "// 5 — the Fresnel rim",
            "// 6 — the contact band",
        ]
        positions = [paint.find(marker) for marker in markers]
        self.assertTrue(all(position >= 0 for position in positions),
                        f"a layer is missing: {list(zip(markers, positions))}")
        self.assertEqual(positions, sorted(positions), "the layers are out of order")

    def test_the_body_is_a_three_stop_vertical_ramp(self):
        material = read(MATERIAL)
        glass = material.split("static let glass")[1]
        self.assertRegex(glass, r"fill: \.ramp\(lightness: 0\.18, mid: 0\.55, darkness: 0\.15, step: nil\)")
        paint = read(PAINT)
        ramp = paint.split("// 2 — the body")[1].split("// 3 —")[0]
        # Vertical: same x at both ends, top to bottom of the shape's own bounds.
        self.assertIn("x: bounds.midX, y: bounds.minY", ramp)
        self.assertIn("x: bounds.midX, y: bounds.maxY", ramp)
        # The three stops themselves live in `rampStops`, one function shared by every ramp fill.
        stops = paint.split("static func rampStops")[1].split("static func haloRadius")[0]
        self.assertIn("let light = base.mixed(with: .white, lightness).color", stops)
        self.assertIn("let dark = base.mixed(with: .black, darkness).color", stops)
        three = stops.split("guard let step else {")[1].split("}")[0]
        self.assertEqual(three.count(".init(color:"), 3, "glass's ramp is three stops")
        for stop in (".init(color: light, location: 0)",
                     ".init(color: base.color, location: CGFloat(mid))",
                     ".init(color: dark, location: 1)"):
            self.assertIn(stop, three)

    def test_a_horizon_turns_the_ramp_into_a_hard_line(self):
        # The one fill behaviour the new materials needed: `step` compresses the crossing through
        # the tint instead of blending it, which is what makes metal's horizon read at 26 pt.
        paint = read(PAINT)
        stops = paint.split("static func rampStops")[1].split("static func haloRadius")[0]
        horizon = stops.split("let seam =")[1]
        self.assertIn("min(1, seam + width)", horizon, "the dark half starts `step` past the seam")
        self.assertIn("location: seam", horizon)
        self.assertIn("base.mixed(with: .black, min(1, darkness * 1.35))", horizon,
                      "the dark half keeps some form at the foot")
        material = read(MATERIAL)
        metal = material.split("static let metal")[1]
        self.assertRegex(metal, r"fill: \.ramp\(lightness: 0\.58, mid: 0\.5, darkness: 0\.52, step: 0\.03\)")
        matte = material.split("static let matte")[1]
        self.assertIn("step: nil", matte, "matte is a soft ramp, not a horizon")

    def test_one_sheen_at_the_specs_centre_and_radius(self):
        glass = read(MATERIAL).split("static let glass")[1]
        sheen = glass.split("sheens: [")[1].split("],")[0]
        self.assertEqual(sheen.count("MaterialSheen("), 1, "one sheen, not a handful")
        self.assertIn("CGPoint(x: 0.42, y: 0.28)", sheen)
        self.assertIn("radius: 0.6", sheen)
        self.assertIn("opacity: 0.22", sheen)
        self.assertIn("blend: .plusLighter", sheen)
        # …and the painter multiplies that fraction by the bounds' long side, not by the side.
        self.assertIn("let radius = CGFloat(sheen.radius) * max(bounds.width, bounds.height)",
                      read(PAINT))

    def test_the_sheen_is_clipped_to_the_shape_and_adds_light(self):
        paint = read(PAINT)
        sheen = paint.split("// 3 — the form sheen")[1].split("// 4 —")[0]
        self.assertIn("layer.clip(to: silhouette)", sheen)
        self.assertIn("blendMode = sheen.blend.graphics", sheen)
        self.assertIn(".radialGradient(", sheen)

    def test_one_streak_a_rotated_capsule_fading_across_its_short_axis(self):
        paint = read(PAINT)
        streak = paint.split("// 4 — the specular streak")[1].split("// 5 —")[0]
        self.assertIn("Path(roundedRect:", streak)
        self.assertIn("rotationAngle: CGFloat(streak.angle)", streak)
        self.assertIn("layer.clip(to: silhouette)", streak)
        # The gradient runs across the thickness: the two points are on the short axis.
        self.assertIn("across", streak)
        self.assertIn("Color.white.opacity(streak.opacity)", streak)
        glass = read(MATERIAL).split("static let glass")[1]
        self.assertEqual(glass.split("streaks: [")[1].split("],")[0].count("MaterialStreak("), 1,
                         "the reference has one streak; three read as scratches")

    def test_the_rim_is_a_gradient_stroke_that_survives_at_26pt(self):
        glass = read(MATERIAL).split("static let glass")[1]
        rim = glass.split("rim: MaterialRim(")[1].split("contact:")[0]
        self.assertIn("MaterialStop(tone: .white, opacity: 0.55, location: 0)", rim)
        self.assertIn("MaterialStop(tone: .lighten(0.3), opacity: 1, location: 0.18)", rim)
        self.assertIn("width: 0.035", rim)
        self.assertIn("minimumWidth: 1", rim)
        paint = read(PAINT)
        layer_five = paint.split("// 5 — the Fresnel rim")[1].split("// 6 —")[0]
        self.assertIn("max(CGFloat(rim.minimumWidth), side * CGFloat(rim.width))", layer_five)
        self.assertIn("layer.stroke(silhouette", layer_five)

    def test_the_contact_band_sits_inside_the_bottom_edge(self):
        glass = read(MATERIAL).split("static let glass")[1]
        contact = glass.split("contact: MaterialContact(")[1].split("\n")[0]
        self.assertIn("darken(0.35)", contact)
        self.assertIn("opacity: 0.12", contact)
        self.assertIn("blur: 2", contact)
        paint = read(PAINT)
        band = paint.split("// 6 — the contact band")[1]
        self.assertIn("bounds.maxY - height", band)
        self.assertIn("layer.clip(to: silhouette)", band)

    def test_the_halo_is_the_silhouette_offset_down_and_blurred(self):
        glass = read(MATERIAL).split("static let glass")[1]
        halo = glass.split("halo: MaterialHalo(")[1].split("),")[0]
        self.assertIn("offset: 0.04", halo)
        self.assertIn("blur: 0.08", halo)
        paint = read(PAINT)
        layer_one = paint.split("// 1 — halo")[1].split("// 2 —")[0]
        self.assertIn("boxed.clip(to: Path(box))", layer_one)


class TheSizeThresholds(unittest.TestCase):
    """What a material draws is decided by how big it is drawn."""

    def test_the_thresholds_are_the_documented_ones(self):
        paint = read(PAINT)
        self.assertIn("static let fullStackFrom: Double = 48", paint)
        self.assertIn("static let catchlightFrom: Double = 64", paint)
        self.assertIn("static let petHaloBlurCap: Double = 6", paint)

    def test_a_list_row_and_the_chat_header_draw_only_layers_2_5_and_6(self):
        paint = read(PAINT)
        compact = paint.split("static func plan(")[1]
        self.assertIn("let full = side >= MaterialDetail.fullStackFrom", compact)
        # The halo, the sheen, the streak and the pattern all read `full`; the rim and the contact
        # band are unconditional. That is layers 2, 5 and 6 at 26 pt.
        self.assertIn("halo: full", compact)
        self.assertIn("details: full", compact)
        self.assertIn("rim: true", compact)
        self.assertIn("contact: true", compact)
        self.assertIn("catchlight: spec.addsEyeCatchlight && side >= MaterialDetail.catchlightFrom", compact)
        header = paint.split("/// 26 pt is a list row")[1].split("static func plan")[0]
        self.assertIn("26–32 pt the chat header", header)
        self.assertIn("2, 5 and 6 only", header)

    def test_the_pet_and_the_editor_preview_get_the_full_stack(self):
        paint = read(PAINT)
        self.assertIn("The pet (96 pt) and the editor's preview (200–320 pt) are well above it",
                      prose(paint))
        editor = read(EDITOR)
        # Retargeted when the Classic row arrived: the editor now holds two 200 pt previews (the
        # drawn one and a classic face), so the block is found by its own call rather than by the
        # first `size: 200` in the file.
        preview = editor.split("OpenBotAvatarView(definition: draft,")[1].split("size: 200")[0]
        self.assertIn("material: material", preview)
        self.assertIn("size: 200", editor)
        self.assertGreaterEqual(200, 48, "the preview must be above the full-stack threshold")
        self.assertGreaterEqual(200, 64, "and above the catchlight's")

    def test_the_plan_is_derived_from_the_size_not_passed_in(self):
        renderer = read(RENDERER)
        self.assertIn("MaterialPlan.plan(for: spec, side: Double(side), backdrop: backdrop)", renderer)
        # No call site chooses a layer set.
        for path in [RENDERER, EDITOR, VIEW, BOT_AVATAR_VIEW, MAC_PET]:
            self.assertNotIn("MaterialPlan(", read(path).replace("MaterialPlan.plan(", ""))


class TheLightTable(unittest.TestCase):
    """Rim and halo per state, from the spec's own pairs."""

    def test_all_eight_states_have_an_entry(self):
        paint = read(PAINT)
        table = paint.split("var glassPulse: GlassPulse {")[1].split("func light(")[0]
        for state in STATES:
            self.assertIn(f"case .{state}:", table, f"{state} has no light")

    def test_the_numbers_are_the_specs(self):
        paint = read(PAINT)
        table = paint.split("var glassPulse: GlassPulse {")[1].split("func light(")[0]

        idle = case_block(table, "idle")
        self.assertEqual((number(r"rim: ([\d.]+)", idle), number(r"halo: ([\d.]+)", idle)), (0.55, 0.20))

        thinking = case_block(table, "thinking")
        self.assertEqual(number(r"rim: ([\d.]+)", thinking), 0.55)
        self.assertEqual(number(r"rimHigh: ([\d.]+)", thinking), 0.75)
        self.assertEqual(number(r"period: ([\d.]+)", thinking), 2.4)

        reading = case_block(table, "reading")
        self.assertEqual((number(r"rim: ([\d.]+)", reading), number(r"halo: ([\d.]+)", reading)), (0.60, 0.22))

        working = case_block(table, "working")
        self.assertEqual(number(r"rim: ([\d.]+)", working), 0.60)
        self.assertEqual(number(r"rimHigh: ([\d.]+)", working), 0.85)
        self.assertEqual(number(r"period: ([\d.]+)", working), 1.2)

        computer = case_block(table, "computer")
        self.assertEqual((number(r"rim: ([\d.]+)", computer), number(r"halo: ([\d.]+)", computer)), (0.70, 0.30))
        self.assertNotIn("period", computer, "computer is steady")

        waiting = case_block(table, "waiting")
        self.assertEqual(number(r"rim: ([\d.]+)", waiting), 0.65)
        self.assertEqual(number(r"halo: ([\d.]+)", waiting), 0.35)
        self.assertEqual(number(r"period: ([\d.]+)", waiting), 3.2)

        blocked = case_block(table, "blocked")
        self.assertEqual((number(r"rim: ([\d.]+)", blocked), number(r"halo: ([\d.]+)", blocked)), (0.50, 0.15))

        done = case_block(table, "done")
        self.assertEqual(number(r"rim: ([\d.]+)", done), 0.55)
        self.assertEqual(number(r"rimHigh: ([\d.]+)", done), 0.75)
        self.assertIn("fallSeconds: 1.4", done)

    def test_the_light_rides_the_pose_so_a_frame_is_reproducible(self):
        state = read(STATE)
        self.assertIn("pose.light = light(time: t, reducedMotion: reducedMotion)", state)
        self.assertIn("public var light: OpenBotAvatarLight", state)
        paint = read(PAINT)
        self.assertIn("func light(time: Double, reducedMotion: Bool) -> OpenBotAvatarLight", paint)

    def test_reduce_motion_freezes_every_pulse_at_its_midpoint(self):
        paint = read(PAINT)
        light = paint.split("func light(time:")[1].split("// MARK: - Where a face")[0]
        self.assertIn("if reducedMotion {", light)
        self.assertIn("(pulse.rim + pulse.rimHigh) / 2", light)
        # The midpoint is returned before any clock is read: a still frame must not drift.
        frozen = light.split("if reducedMotion {")[1].split("}")[0]
        self.assertNotIn("time", frozen.replace("// ", ""))

    def test_the_pulse_is_a_slow_sine_not_a_strobe(self):
        paint = read(PAINT)
        self.assertIn("let phase = (1 - cos(2 * .pi * time / pulse.period)) / 2", paint)


class BlockedIsCalm(unittest.TestCase):
    """Blocked desaturates; it does not turn red or start an alarm."""

    def test_blocked_takes_fifteen_percent_of_the_saturation(self):
        paint = read(PAINT)
        blocked = case_block(paint.split("var glassPulse: GlassPulse {")[1], "blocked")
        self.assertIn("desaturate: 0.15", blocked)
        self.assertIn("let base = spec.desaturatesWhenBlocked && light.desaturate > 0",
                      paint)
        self.assertIn("raw.desaturated(by: light.desaturate)", paint)

    def test_desaturation_is_around_luminance_not_a_new_colour(self):
        material = read(MATERIAL)
        body = material.split("func desaturated(by amount: Double)")[1].split("/// One of a material's tones")[0]
        self.assertIn("0.299 * red + 0.587 * green + 0.114 * blue", body)

    def test_no_red_anywhere_in_the_material(self):
        for path in [MATERIAL, PAINT]:
            text = read(path)
            # `blocked` is calm: no red ink, no alarm colour, no system red. (`other.red` is the
            # colour struct's own field, so the check is on colour tokens rather than the word.)
            self.assertNotRegex(text, r"Color\.red|systemRed|(?<![\w.])\.red\b",
                                f"{path.name} paints a red")
            for forbidden in ["#FF0000", "#ff0000", "Color(red: 1, green: 0"]:
                self.assertNotIn(forbidden, text, f"{path.name} paints a red {forbidden}")

    def test_a_solid_ignores_the_state_and_keeps_the_bots_colour(self):
        material = read(MATERIAL)
        solid = material.split("static let solid")[1].split("static let glass")[0]
        self.assertIn("desaturatesWhenBlocked: false", solid)


class TheBackdropRules(unittest.TestCase):
    """The pet cannot know its wallpaper; a light page needs a different rim."""

    def test_the_pet_forces_the_two_tone_rim(self):
        paint = read(PAINT)
        self.assertIn("var forcesTwoToneRim: Bool { self == .pet }", paint)
        self.assertIn("let twoTone = backdrop.forcesTwoToneRim || !backdrop.isLight", paint)
        self.assertIn("backdrop: .pet", read(MAC_PET), "the pet must say where it draws")
        self.assertIn("case pet", paint)

    def test_the_pet_caps_the_halo_blur(self):
        paint = read(PAINT)
        halo = paint.split("static func haloRadius")[1].split("/// A pattern")[0]
        self.assertIn("backdrop == .pet ? min(radius, CGFloat(MaterialDetail.petHaloBlurCap)) : radius",
                      halo)
        self.assertIn("12 pt clear margin", paint)

    def test_a_light_page_swaps_the_rim_and_adds_a_hairline(self):
        paint = read(PAINT)
        self.assertIn("let stops: [Gradient.Stop] = (twoTone ? rim.stops : (rim.lightStops ?? rim.stops))",
                      paint)
        self.assertIn("if !twoTone, let hairline = rim.outerHairline {", paint)
        glass = read(MATERIAL).split("static let glass")[1]
        light_stops = glass.split("lightStops: [")[1].split("],")[0]
        self.assertIn("MaterialStop(tone: .white, opacity: 0.55, location: 0)", light_stops)
        self.assertIn("MaterialStop(tone: .tint, opacity: 0.5, location: 0.18)", light_stops)
        hairline = glass.split("outerHairline:")[1].split("\n")[0]
        self.assertIn("darken(0.4)", hairline)
        self.assertIn("0.25", hairline)
        self.assertIn("hairlineWidth: 1", glass)

    def test_a_themed_surface_follows_the_environment(self):
        view = read(VIEW)
        self.assertIn("let surface = backdrop ?? .themed(dark: colorScheme != .light)", view)
        self.assertIn("backdrop: surface,", view)


class SolidIsTheDefaultAndUntouched(unittest.TestCase):
    """Nothing stored changes, and the 0.1.648 drawing is still what a flat fill runs."""

    def test_absent_is_solid(self):
        material = read(MATERIAL)
        self.assertIn("public static let fallback: BotAvatarMaterial = .solid", material)
        self.assertIn("guard let raw else {\n            self = .fallback", material)
        view = read(VIEW)
        self.assertIn("material: BotAvatarMaterial = .solid", view)
        self.assertIn("material = try container.decodeIfPresent(BotAvatarMaterial.self, forKey: .material)\n            ?? .fallback", view)

    def test_solid_is_the_first_row_and_its_spec_is_empty(self):
        material = read(MATERIAL)
        self.assertIn("static let all: [BotAvatarMaterialSpec] = [.solid, .glass, .matte, .metal]",
                      material)
        self.assertEqual(table_materials()[0], "solid", "Solid is still the default row")
        solid = material.split("static let solid = BotAvatarMaterialSpec(")[1].split("static let glass")[0]
        self.assertIn("fill: .flat", solid)
        for empty in ["halo: nil", "sheens: []", "streaks: []", "rim: nil", "contact: nil",
                      "texture: nil", "addsEyeCatchlight: false"]:
            self.assertIn(empty, solid, f"solid's spec must be empty: {empty}")

    def test_the_flat_fill_still_draws_the_volume_slice_by_slice(self):
        renderer = read(RENDERER)
        flat = renderer.split("case .flat:")[1].split("case .ramp:")[0]
        self.assertIn("for slice in drawnSlices(volume: volume, basis: basis)", flat)
        self.assertIn("bodyContext.fill(slice.path,", flat)
        self.assertIn("with: .color(color),", flat)
        self.assertIn("FillStyle(eoFill: slice.evenOdd, antialiased: true)", flat)
        # The renderer's default is still the solid face: a caller that says nothing gets 0.1.648.
        self.assertIn("material: BotAvatarMaterial = .solid", renderer)

    def test_the_definition_itself_is_untouched(self):
        definition = read(AVATAR / "BotAvatarDefinition.swift")
        self.assertNotIn("material", definition,
                         "the open-bot-avatar definition must not grow a material field")
        self.assertIn('public static let topLevelKeys = ["version", "id", "name", "body", "eyes"]',
                      definition)


class TheMaterialIsStored(unittest.TestCase):
    """`material` travels beside `definition` and `color`, refused when it is not one of the table."""

    def test_the_two_sides_agree_on_the_values(self):
        # The host's list is the authority a stored value is checked against, so the table the
        # editor draws from has to be a subset of it — one material that is drawable but unstorable
        # is a face a person can design and cannot save.
        table = table_materials()
        host = rust_materials()
        for material in table:
            self.assertIn(material, host,
                          f"{material!r} is in the editor's table but the host would answer 400")
        self.assertEqual(table, material_cases(),
                         "the table and the enum's cases have drifted apart")
        self.assertEqual(sorted(set(table)), sorted(set(host)),
                         "the editor and the host accept different sets of materials")
        # An old client's two values are still there, and still first: nothing it sends is refused.
        self.assertEqual(host[:2], ["solid", "glass"])
        self.assertIn("public static let accepted: [String] = allCases.map(\\.rawValue)", read(MATERIAL))

    def test_both_sides_build_the_same_sentence_and_draw_it_from_their_list(self):
        host = rust_materials()
        spoken = material_sentence(host)              # "solid", "glass", "matte" or "metal"
        literal = spoken.replace('"', '\\"')          # the same inside a Rust string literal
        self.assertEqual(len(host), 4, "the list the sentence is built from changed; update the test")
        # Rust: the sentence is built from `MATERIALS`, and the test pins the exact wording.
        rust = read(RUST_AVATAR)
        self.assertIn("let quoted: Vec<String> = MATERIALS.iter()", rust)
        self.assertIn('"material must be {}, not {raw:?}"', rust)
        self.assertIn(spoken, rust, "the refusal's list is not the one MATERIALS holds")
        self.assertIn(f'material must be {literal}, not \\"chrome\\"', rust)
        self.assertIn(f'material must be a string, {literal}', rust)
        # Swift: the sentence is built from `accepted`, which is built from the cases.
        swift = read(MATERIAL)
        self.assertIn("let quoted = accepted.map { \"\\\"\\($0)\\\"\" }", swift)
        self.assertIn('"material must be \\(allowedDescription), not \\"\\(raw)\\""', swift)
        self.assertIn("quoted.dropLast().joined(separator: \", \") + \" or \" + last", swift)

    def test_the_host_validates_and_stores_it(self):
        routes = read(RUST_ROUTES)
        self.assertIn("crate::bot_avatar::parse_material(value)", routes)
        self.assertIn('entry["material"] = json!(material)', routes)
        self.assertIn('object.remove("material");', routes)
        # Cleared with the definition, in the same branch.
        clear = routes.split('Some(Value::Null) | None => {')[1]
        self.assertIn('object.remove("definition");', clear)
        self.assertIn('object.remove("material");', clear)

    def test_the_python_count_matches_the_route(self):
        # One field, one place: nothing else in the document learned about materials.
        routes = read(RUST_ROUTES)
        material_writes = routes.count('entry["material"]')
        self.assertEqual(material_writes, 1)

    def test_both_apps_send_and_read_it(self):
        for path in [MAC_PICKER, IOS_PICKER]:
            text = read(path)
            self.assertIn('material: face["material"] as? String', text)
            self.assertIn('"material": document?.material.rawValue ?? NSNull()', text)

    def test_the_library_carries_it_to_every_surface(self):
        # The document carries the material, the library carries documents, so no call site needs a
        # new argument for a bot's glass choice to reach the list row, the header, the settings
        # panel, the sidebar and the pet.
        self.assertIn("public var material: BotAvatarMaterial", read(VIEW))
        self.assertIn("material: face.material", read(BOT_AVATAR_VIEW))
        self.assertIn("material: avatar.material", read(MAC_PET))
        library = read(LIBRARY)
        self.assertIn("public var avatars: [String: BotAvatarDocument]", library)

    def test_the_document_round_trips_through_json(self):
        view = read(VIEW)
        document = view.split("public struct BotAvatarDocument")[1]
        self.assertIn("public var material: BotAvatarMaterial", document)
        self.assertIn("material: BotAvatarMaterial = .solid", document)
        self.assertIn("case material", document)


class EveryRowIsAWholeSpec(unittest.TestCase):
    """A material is a row that fills in every field the painter reads — no half a spec."""

    def test_each_row_fills_every_field_the_painter_reads(self):
        rows = spec_rows()
        self.assertEqual(sorted(rows), sorted(material_cases()), "a material has no spec row")
        self.assertEqual(table_materials(), material_cases(),
                         "a case is missing from the table, so `spec(for:)` would fall back to solid")
        for name, row in rows.items():
            with self.subTest(material=name):
                for field in SPEC_FIELDS:
                    self.assertIn(field, row, f"{name} does not set {field}")
                self.assertIn(f"material: .{name}", row, f"{name}'s row names another material")
                self.assertIn("name: \"", row)
                self.assertIn("summary: \"", row)

    def test_every_row_still_reads_at_26pt(self):
        # 26 pt is a list row, and the plan draws three layers there: the fill, the rim and the
        # contact band. Every material except the deliberately empty solid must own all three.
        for name, row in spec_rows().items():
            with self.subTest(material=name):
                if name == "solid":
                    self.assertIn("fill: .flat", row)
                    continue
                self.assertIn("fill: .ramp(", row)
                self.assertIn("rim: MaterialRim(", row,
                              "the rim is what holds a silhouette at 26 pt")
                self.assertIn("contact: MaterialContact(", row,
                              "without a contact band the shape looks pasted on")
                self.assertIn("minimumWidth: 1", row, "a rim thinner than a point is not there")
                self.assertIn("width: 0.", row)

    def test_the_new_rows_are_told_apart_by_what_they_draw(self):
        rows = spec_rows()
        matte, metal, glass = rows["matte"], rows["metal"], rows["glass"]
        # Matte: no specular at all, a grain only the full stack draws, and a rim that takes light
        # away rather than adding it.
        self.assertIn("halo: nil", matte, "a matte surface throws no light")
        self.assertIn("sheens: []", matte)
        self.assertIn("streaks: []", matte)
        self.assertIn("texture: MaterialTexture(pattern: .grain", matte)
        self.assertIn("blend: .normal", matte)
        self.assertNotIn(".white", matte, "nothing on a matte body is white")
        self.assertIn("addsEyeCatchlight: false", matte)
        self.assertIn("desaturatesWhenBlocked: true", matte)
        # Metal: the horizon, a narrow bright rim, no halo, no streak.
        self.assertIn("step: 0.03", metal)
        self.assertIn("halo: nil", metal, "a halo would wash out the horizon")
        self.assertIn("streaks: []", metal, "a long streak is glass's signature")
        self.assertIn("width: 0.012", metal)
        self.assertIn("addsEyeCatchlight: true", metal)
        self.assertIn("desaturatesWhenBlocked: false", metal)
        # Glass keeps its own: a halo, one streak, a wide soft rim and no horizon.
        self.assertIn("halo: MaterialHalo(", glass)
        self.assertIn("MaterialStreak(", glass)
        self.assertIn("width: 0.035", glass)
        self.assertIn("step: nil", glass)


class TheRandomButtonUsesTheTables(unittest.TestCase):
    """Random is three tables read once — not a fourth palette, a fifth material list or a shape."""

    def test_the_button_exists_and_applies_all_three_at_once(self):
        editor = read(EDITOR)
        self.assertIn('Button("Random") { randomise() }', editor)
        self.assertIn("OpenBotAvatarRandom.pick(avoiding: lastRandomPick)", editor)
        self.assertIn("material = pick.material", editor)
        self.assertIn("colorHex = pick.colorHex", editor)
        self.assertIn("adopt(pick.definition)", editor,
                      "the preview and the JSON box must change together")
        self.assertIn("private func randomise()", editor)

    def test_the_pick_draws_shape_material_and_colour_from_the_tables(self):
        random = read(RANDOM)
        self.assertIn("try? OpenBotAvatarPresets.validated()", random,
                      "a random shape must be a validated preset")
        self.assertIn("BotAvatarMaterialSpec.all.map(\\.material)", random,
                      "a random material must be a row of the table")
        self.assertIn("BotAvatarPalette.colors.filter", random,
                      "a random colour must come from the app's palette")
        self.assertIn(".map(\\.hex)", random,
                      "the colour is a palette entry's hex, not a new value")
        # …and nothing of its own.
        self.assertNotRegex(code(random), r"#[0-9A-Fa-f]{3,6}\b",
                            "the randomiser has a colour list of its own")
        self.assertNotIn("M50", random, "the randomiser has shapes of its own")

    def test_it_cannot_repeat_the_last_pick(self):
        random = read(RANDOM)
        self.assertIn("all.filter { $0.combination != key }", random,
                      "the pick comes from the set minus the last one, not a re-roll")
        self.assertIn("guard !all.isEmpty else { return nil }", random)
        self.assertIn("public var combination: String", random)
        editor = read(EDITOR)
        self.assertIn("@State private var lastRandomPick: String?", editor)
        self.assertIn("lastRandomPick = pick.combination", editor)

    def test_a_random_pick_cannot_leave_the_editor_invalid(self):
        # The pick's three parts are a validated definition, a table material and a palette hex, and
        # the editor adopts it through the same path a preset takes — so the JSON box follows and
        # Save cannot be refused for something Random did.
        editor = read(EDITOR)
        randomise = editor.split("private func randomise() {")[1].split("\n    }")[0]
        self.assertIn("adopt(pick.definition)", randomise)
        self.assertIn("guard let pick = OpenBotAvatarRandom.pick", randomise)
        adopt = editor.split("private func adopt(")[1].split("\n    }")[0]
        self.assertIn("jsonStatus = .ok", adopt)
        self.assertIn("syncJSONText()", adopt)

    def test_the_editor_has_no_second_colour_list(self):
        editor = code(read(EDITOR))
        self.assertNotRegex(editor, r"#[0-9A-Fa-f]{3,6}", "a hex literal is a second palette")
        self.assertNotIn("BotAvatarPalette.colors", editor,
                         "the palette belongs to the randomiser, not the view")
        for name in ("palette", "swatches", "colours", "colors"):
            self.assertNotRegex(editor, rf"\b{name}\b\s*:\s*\[",
                                f"the editor grew its own {name} list")
        # The one place a colour is chosen by hand is the system picker, and it stores a hex.
        self.assertIn("ColorPicker(\"Body colour\"", editor)
        self.assertIn("colorHex = OpenBotAvatarColor.hex(of: $0)", editor)


class TheEditorOffersEveryRow(unittest.TestCase):
    """The editor lists the table, so a third material needs no new control."""

    def test_the_choice_is_built_from_the_table(self):
        editor = read(EDITOR)
        self.assertIn("ForEach(BotAvatarMaterialSpec.all, id: \\.material)", editor)
        self.assertIn("Picker(\"Material\", selection: $material)", editor)
        self.assertIn("Text(spec.name).tag(spec.material)", editor)
        self.assertIn("_material = State(initialValue: stored?.material ?? .solid)", editor)

    def test_saving_stores_the_material(self):
        editor = read(EDITOR)
        # Retargeted when the Classic row arrived: the document travels inside a `BotAvatarSelection`
        # now (one family saved, the other cleared), and the material still goes with it.
        self.assertIn("material: material", editor.split("BotAvatarSelection.custom(BotAvatarDocument(")[1])
        self.assertIn("stored.material != material", editor, "a material change must enable Save")

    def test_the_preview_is_big_enough_to_show_the_streak(self):
        editor = read(EDITOR)
        self.assertIn("size: 200", editor)


if __name__ == "__main__":
    unittest.main()
