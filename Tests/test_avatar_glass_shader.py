"""The glass shader path, guarded from the source text.

Glass on an app surface is a Metal fragment pass (`Apps/Shared/Glass/OpenBotAvatarGlass.metal`) and
everything else in the app is `Canvas` drawing, so neither side can be exercised from this suite.
What *can* be checked — and is, below — is every fact the split can silently get wrong:

* **one decision**: exactly one function answers shader-or-Canvas, it is called once, and the
  renderer follows the answer instead of asking again;
* **one fallback**: the painted material is still there, and Reduce Transparency, a preview, a body
  under the shader's floor, the Live Activity and every material but glass all still get it;
* **Solid never reaches the shader**, and neither does a body drawn below the floor;
* **the `.metal` file is an app file**: it is in the Mac's and the phone's sources in `project.yml`
  and in the Live Activity's not at all, and there is no `.metal` under `Sources/`;
* **no per-frame allocation**: every probe is read once, and the per-frame uniform builder allocates
  nothing;
* **the terms are upstream's**, constant by constant, with the line each one was read from checked
  against `packages/core/src/dom/glass/shaders.ts` when that checkout is on this machine;
* **the eight built-in states still take no mark and never shrink the body**, and the shader path
  cannot draw a mark the pose did not carry.

The upstream checkout is not in the repository (it is the owner's reference tree), so the line-by-line
checks skip without it rather than failing on a machine that does not have it.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UI = ROOT / "Sources" / "HermeyUI"
AVATAR = UI / "OpenBotAvatar"

ROUTE = AVATAR / "OpenBotAvatarGlassRoute.swift"
RENDERER = AVATAR / "OpenBotAvatarRenderer.swift"
VIEW = AVATAR / "OpenBotAvatarView.swift"
PAINT = AVATAR / "OpenBotAvatarMaterialPaint.swift"
STATE = AVATAR / "OpenBotAvatarState.swift"
MATERIAL = AVATAR / "BotAvatarMaterial.swift"

METAL = ROOT / "Apps" / "Shared" / "Glass" / "OpenBotAvatarGlass.metal"
PROJECT = ROOT / "project.yml"

UPSTREAM = Path("/root/jobs/oba-upstream/packages/core/src/dom/glass/shaders.ts")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def code(text: str) -> str:
    """The text with its comments removed, so an example written in a doc comment is not a literal."""
    return "\n".join(line.split("///")[0].split("//")[0] for line in text.splitlines())


def decide_body() -> str:
    """The body of `BotAvatarGlassRoute.decide`, from its signature to its closing brace."""
    source = code(read(ROUTE))
    start = source.index("func decide(")
    return source[start:source.index("\n    }", start)]


def metal_code() -> str:
    return code(read(METAL))


class TheOneDecision(unittest.TestCase):
    """One function decides which drawing a surface gets, and one renderer follows it."""

    def test_exactly_one_function_decides(self):
        sources = list(UI.rglob("*.swift")) + list((ROOT / "Apps").rglob("*.swift"))
        deciders = [path for path in sources
                    if "BotAvatarGlassRoute" in read(path) and "static func decide(" in code(read(path))]
        self.assertEqual([path.name for path in deciders], ["OpenBotAvatarGlassRoute.swift"])

    def test_it_is_called_once_and_the_answer_travels(self):
        # One call site — the view's — and the renderer receives the answer as a parameter.
        sources = list(UI.rglob("*.swift")) + list((ROOT / "Apps").rglob("*.swift"))
        calls = [(path.name, len(re.findall(r"BotAvatarGlassRoute\.decide\(", code(read(path)))))
                 for path in sources]
        self.assertEqual(sum(count for _, count in calls), 1, calls)
        self.assertIn(("OpenBotAvatarView.swift", 1), calls)

    def test_the_renderer_does_not_answer_it_again(self):
        renderer = code(read(RENDERER))
        # The renderer takes the route and tests it exactly once, as a value.
        self.assertIn("route: BotAvatarGlassRoute = .canvas", renderer)
        self.assertEqual(len(re.findall(r"route == \.metal", renderer)), 1)
        # …and it never asks the process, the bundle or Metal itself.
        for probe in ("MTLCreateSystemDefaultDevice", "default.metallib", "ShaderLibrary"):
            self.assertNotIn(probe, renderer)

    def test_the_view_is_the_only_place_that_asks(self):
        view = code(read(VIEW))
        self.assertIn("BotAvatarGlassRoute.decide(material: material, side: Double(size),", view)
        self.assertIn("reduceTransparency: reduceTransparency", view)
        # The decision is taken outside the timeline, so a frame does not re-answer it.
        self.assertLess(view.index("let route = BotAvatarGlassRoute.decide("),
                        view.index("TimelineView(.animation"))


class SolidNeverReachesIt(unittest.TestCase):
    """The shader is glass's surface; every other material is drawn by the painter."""

    def test_glass_is_the_first_guard(self):
        body = decide_body()
        guards = re.findall(r"guard ([^\n]+) else", body)
        self.assertEqual(guards[0], "material == .glass")
        # …and every other guard sits between it and the one `return .metal`.
        first = body.index("guard material == .glass else { return .canvas }")
        for other in ("guard !reduceTransparency", "guard side >= BotAvatarGlassShader.minimumSide",
                      "guard BotAvatarGlassShader.isAvailable", "return .metal"):
            self.assertLess(first, body.index(other), other)

    def test_the_shader_is_the_last_thing_returned(self):
        # Nothing but the end of the function may say `.metal`: every earlier exit is the painter.
        body = decide_body()
        self.assertEqual(len(re.findall(r"return \.metal", body)), 1)
        self.assertGreater(body.index("return .metal"), body.index("guard BotAvatarGlassShader.isAvailable"))

    def test_the_metal_body_never_reads_the_material_spec(self):
        renderer = code(read(RENDERER))
        block = renderer.split("if pass.drawsBody, route == .metal {")[1].split("} else if pass.drawsBody {")[0]
        # A flat fill and a tint: no fill case, no spec, no plan — so a `solid` spec cannot be
        # drawn through the fragment pass by any edit that keeps this block's shape.
        for token in ("case .flat", "case .ramp", "spec.fill", "BotAvatarMaterialRender.render"):
            self.assertNotIn(token, block)

    def test_every_material_but_glass_takes_the_painter(self):
        # The material is compared to `.glass` with `==` against the stored value, so `solid`, `matte`
        # and `metal` — the three rows that are not glass — cannot reach the fragment pass.
        body = decide_body()
        self.assertEqual(re.findall(r"material == (\.\w+)", body), [".glass"])
        self.assertNotIn("material != .glass", body)


class TheFallbackStays(unittest.TestCase):
    """The Canvas glass is not vestigial: it is what most surfaces draw."""

    def test_reduce_transparency_gets_the_painter(self):
        body = decide_body()
        self.assertIn("guard !reduceTransparency else { return .canvas }", body)
        self.assertIn("accessibilityReduceTransparency", read(VIEW))

    def test_a_body_under_the_floor_gets_the_painter(self):
        self.assertIn("guard side >= BotAvatarGlassShader.minimumSide else { return .canvas }", decide_body())
        floor = re.search(r"static let minimumSide: Double = (\d+)", code(read(ROUTE)))
        self.assertIsNotNone(floor)
        self.assertEqual(float(floor.group(1)), 24)

    def test_a_process_without_the_shader_gets_the_painter(self):
        self.assertIn("guard BotAvatarGlassShader.isAvailable else { return .canvas }", decide_body())
        shader = code(read(ROUTE))
        # A device, a compiled shader in *this* bundle, and not a preview — read once, together.
        self.assertIn('Bundle.main.url(forResource: "default", withExtension: "metallib")', shader)
        self.assertIn('"XCODE_RUNNING_FOR_PREVIEWS"', shader)
        self.assertIn("static let isAvailable: Bool = hasDevice && hasShader && !isPreview", shader)

    def test_the_painter_still_paints_the_six_layers(self):
        paint = code(read(PAINT))
        for layer in ("// 1 — halo", "// 2 — the body", "// 3 — the form sheen",
                      "// 4 — the specular streak", "// 5 — the Fresnel rim", "// 6 — the contact band"):
            # The comments are stripped above, so check the order they gate instead.
            self.assertTrue(paint.count("context.fill") + paint.count("layer.fill") >= 4)
        source = read(PAINT)
        for marker in ("// 1 — halo", "// 2 — the body", "// 3 — the form sheen",
                       "// 4 — the specular streak", "// 5 — the Fresnel rim", "// 6 — the contact band"):
            self.assertIn(marker, source)

    def test_the_one_material_entry_point_is_still_one(self):
        # `paint` is entered from `render`, and `render` is what both drawings call.
        paint = code(read(PAINT))
        callers = re.findall(r"OpenBotAvatarMaterialPaint\.paint\(", paint)
        self.assertEqual(len(callers), 2, "render's silhouette and mark branches, and nothing else")
        self.assertEqual(len(re.findall(r"OpenBotAvatarMaterialPaint\.painter\.paint\(", paint)), 0)

    def test_the_painted_route_draws_the_ramp_through_the_entry_point(self):
        renderer = code(read(RENDERER))
        self.assertIn("case .ramp:", renderer)
        ramp = renderer.split("case .ramp:")[1].split("}\n        }")[0]
        self.assertIn("BotAvatarMaterialRender.render([.silhouette(", ramp)

    def test_the_canvas_route_is_one_pass(self):
        view = code(read(VIEW))
        canvas_route = view.split("case .canvas:")[1].split("case .metal:")[0]
        self.assertIn("OpenBotAvatarRenderer.draw(model,", canvas_route)
        # The one-pass drawing passes no `pass:` — `.all` is the default, which is the old frame.
        self.assertNotIn("pass: .", canvas_route)


class TheMetalFileIsAnAppFile(unittest.TestCase):
    """One shader, in the two app bundles, and in no extension and no package."""

    def test_there_is_one_shader_and_it_is_shared(self):
        metal = list(ROOT.rglob("*.metal"))
        self.assertEqual([path.relative_to(ROOT).as_posix() for path in metal],
                         ["Apps/Shared/Glass/OpenBotAvatarGlass.metal"])

    def test_nothing_under_sources_carries_one(self):
        # A package target's shader lands in the package's resource bundle, which is not the library
        # the renderer looks a function up in: it would be compiled and never found.
        self.assertEqual(list((ROOT / "Sources").rglob("*.metal")), [])

    def project_targets(self) -> dict[str, str]:
        """Each target's own block of `project.yml`, so a path is checked in the target that lists it."""
        text = read(PROJECT)
        body = text.split("\ntargets:\n", 1)[1].split("\nschemes:\n", 1)[0]
        blocks: dict[str, str] = {}
        current = ""
        for line in body.splitlines():
            match = re.match(r"^  (\w+):\s*$", line)
            if match:
                current = match.group(1)
                blocks[current] = ""
            elif current:
                blocks[current] += line + "\n"
        return blocks

    def test_both_apps_compile_it(self):
        targets = self.project_targets()
        for app in ("HermesMac", "HermesMobile"):
            self.assertIn("- path: Apps/Shared/Glass", targets[app], app)

    def test_the_live_activity_does_not(self):
        targets = self.project_targets()
        self.assertIn("HermesLiveActivity", targets)
        self.assertNotIn("Apps/Shared/Glass", targets["HermesLiveActivity"])
        # …and it still compiles the avatar's Swift, which is why the probe has to be the bundle's.
        self.assertIn("- path: Sources/HermeyUI/OpenBotAvatar", targets["HermesLiveActivity"])

    def test_the_deployment_targets_already_carry_swiftui_shaders(self):
        text = read(PROJECT)
        self.assertIn('macOS: "14.0"', text)
        self.assertIn('iOS: "17.0"', text)
        # `Shader`, `.layerEffect` and `ShaderLibrary` are macOS 14 / iOS 17, so nothing was raised.
        package = read(ROOT / "Package.swift")
        self.assertIn(".macOS(.v14)", package)
        self.assertIn(".iOS(.v17)", package)


class NoPerFrameAllocation(unittest.TestCase):
    """The animating path builds six small vectors and samples a layer; it allocates nothing."""

    def test_every_probe_is_read_once(self):
        shader = code(read(ROUTE))
        self.assertEqual(len(re.findall(r"MTLCreateSystemDefaultDevice\(\)", shader)), 1)
        self.assertEqual(len(re.findall(r"Bundle\.main", shader)), 1)
        # Both inside `static let`s: a `var` would be re-answered, and a `func` could be called.
        for name in ("hasDevice", "hasShader", "isPreview", "isAvailable", "minimumSide"):
            self.assertRegex(shader, r"static let " + name)

    def test_the_uniform_builder_allocates_nothing(self):
        source = code(read(ROUTE))
        build = source.split("static func make(model:")[1].split("\n    }")[0]
        for allocation in (".map(", ".filter(", "Array(", "Data(", "CGImage", "UIGraphics",
                           "MTLTexture", "makeBuffer", "Path(", "boundingRect"):
            self.assertNotIn(allocation, build, allocation)

    def test_the_shader_is_a_function_lookup_not_a_file_read(self):
        shader = code(read(ROUTE))
        self.assertIn("ShaderLibrary.default.hermeyGlassBody(", shader)
        self.assertNotIn("MTLLibrary(", shader)
        self.assertNotIn("makeDefaultLibrary", shader)

    def test_the_layer_is_sampled_within_the_declared_offset(self):
        shader = code(read(ROUTE))
        self.assertIn("maxSampleOffset = CGSize(width: 8, height: 8)", shader)
        self.assertIn("float2(-8.0), float2(8.0)", metal_code())


class TheTermsAreUpstreams(unittest.TestCase):
    """Every constant in the fragment function is the reference's, not a guess."""

    def test_the_optics_are_the_reference_s(self):
        metal = read(METAL)
        for literal, why in (
            ("constant float kIOR = 1.50;", "IOR"),
            ("constant float kF0 = 0.04;", "F0"),
            ("pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0)", "Schlick's fifth power"),
            ("float3(-0.60, -0.74, -0.30), float2(0.70, 0.155), 0.090, -0.52", "the key softbox"),
            ("float3(-0.24, -0.76, -0.60), float2(0.70, 0.095), 0.075, -0.22", "the rim softbox"),
            ("keyMain * 13.0", "the key's weight"),
            ("keyRim * 8.0", "the rim's weight"),
            ("0.62 + float3(0.08)", "Beer-Lambert's absorption"),
            ("peak / (1.0 + peak * 0.48)", "the tone map"),
            ("smoothstep(2.2, 5.2, peak)", "the white roll"),
            ("mix(0.36, 0.68, pow(1.0 - cos1, 1.55))", "the edge transparency"),
            ("0.28, 0.98", "its clamp"),
            ("float3(1.0 / 2.2)", "the gamma"),
        ):
            self.assertIn(literal, metal, why)

    def test_the_prologue_cites_where_each_one_came_from(self):
        metal = read(METAL)
        # A citation may name a range (`shaders.ts:391-399`), so every number in one counts.
        cited = {number for run in re.findall(r"shaders\.ts:\s*([\d,\s-]+)", metal)
                 for number in re.findall(r"\d+", run)}
        for line in ("46", "47", "137", "152", "161", "289", "340", "391", "408", "422"):
            self.assertIn(line, cited, f"shaders.ts:{line}")

    @unittest.skipUnless(UPSTREAM.exists(), "the upstream checkout is not on this machine")
    def test_the_cited_lines_still_say_what_was_ported(self):
        lines = UPSTREAM.read_text(encoding="utf-8").splitlines()
        def at(n: int) -> str:
            return lines[n - 1]
        self.assertIn("IOR = 1.50", at(46))
        self.assertIn("F0", at(47))
        self.assertIn("0.04", at(47))
        self.assertIn("fresnelSchlick", at(137))
        self.assertIn("-0.60, -0.74, -0.30", at(152))
        self.assertIn("13.0", at(161))
        self.assertIn("refract(rd, n1, 1.0 / IOR)", at(289))
        self.assertIn("absorbSigma", at(422))
        self.assertIn("1.0 / 2.2", at(408))


class TheEightStatesAreUntouched(unittest.TestCase):
    """The shader path draws the same frame: no mark, no shrunken body, the state's own light."""

    def test_no_mark_reaches_the_body_from_the_shader_path(self):
        renderer = code(read(RENDERER))
        # The only source of a mark is the pose, and the only pass that draws one is `.over`.
        marks = [line.strip() for line in renderer.splitlines()
                 if "BotAvatarMaterialRender.render(markShapes(" in line]
        self.assertEqual(marks, ["BotAvatarMaterialRender.render(markShapes(pose.marks, model: model, seed: seed, still: still,"])
        self.assertIn("guard pass.drawsOver else { return }", renderer)
        self.assertLess(renderer.index("guard pass.drawsOver else { return }"),
                        renderer.index("markShapes(pose.marks"))

    def test_the_body_is_filled_at_its_own_scale(self):
        renderer = code(read(RENDERER))
        metal_block = renderer.split("if pass.drawsBody, route == .metal {")[1]
        metal_block = metal_block.split("} else if pass.drawsBody {")[0]
        # The shader's fill is the silhouette through the body's own transform — no `shrink`, and no
        # `bodyScale` anywhere near it.
        self.assertIn("model.silhouette.applying(face)", metal_block)
        self.assertNotIn("bodyScale", metal_block)
        self.assertNotIn("shrink", metal_block)

    def test_the_state_s_light_still_reaches_the_shader(self):
        shader = code(read(ROUTE))
        self.assertIn("Float(pose.light.rim)", shader)
        # The eight-state light table is unmoved: `light(time:reducedMotion:)` still drives it.
        # The pose still takes the state's own light, and the eight-state table is unmoved.
        self.assertIn("pose.light = light(time: t, reducedMotion: reducedMotion)", code(read(STATE)))
        paint = code(read(PAINT))
        self.assertIn("func light(time: Double, reducedMotion: Bool) -> OpenBotAvatarLight", paint)
        self.assertIn("var glassPulse: GlassPulse", paint)

    def test_the_shader_path_is_three_passes_in_paint_order(self):
        view = code(read(VIEW))
        metal_route = view.split("case .metal:")[1]
        order = [metal_route.index(f"pass: .{name}") for name in ("behind", "body", "over")]
        self.assertEqual(order, sorted(order))
        self.assertIn(".layerEffect(glass.shader", metal_route)
        # The effect is applied to the body's pass and to nothing else.
        body = metal_route.split("pass: .body")[1].split("pass: .over")[0]
        self.assertIn(".layerEffect(", body)


if __name__ == "__main__":
    unittest.main()
