"""The glass shader path, guarded from the source text.

Glass on an app surface is a Metal fragment pass compiled from its own source at run time
(`Sources/HermeyUI/OpenBotAvatar/Glass/HermeyGlassSource.swift`) and everything else in the app is
`Canvas` drawing, so neither side can be exercised from this suite. What *can* be checked — and is,
below — is every fact the split can silently get wrong:

* **one decision**: exactly one function answers shader-or-Canvas, it is called once, and nothing
  else in the app answers it again;
* **one fallback**: the painted material is still there, and Reduce Transparency, a preview, a body
  under the shader's floor, the Live Activity and every material but glass all still get it;
* **the shader is compiled, not built**: the MSL is a string, it is compiled by
  `device.makeLibrary(source:)` **once per process** into one library and one pipeline pair, and a
  compile that fails falls back to the painted material instead of crashing;
* **Solid never reaches the shader**, and neither does a body drawn below the floor;
* **the Live Activity gets neither the source nor the shader**: no `.metal` file exists at all, the
  MSL string is behind the widget target's own compilation condition, and that target sets it while
  neither app does;
* **no per-frame compilation**: the library, the pipeline and the sampler are built once, and the
  per-frame uniform builder allocates nothing;
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

GLASS = AVATAR / "Glass"
SOURCE = GLASS / "HermeyGlassSource.swift"
LAYER = GLASS / "BotAvatarGlassLayer.swift"
GLASS_VIEW = GLASS / "BotAvatarGlassView.swift"
PROJECT = ROOT / "project.yml"
PACKAGE = ROOT / "Package.swift"

UPSTREAM = Path("/root/jobs/oba-upstream/packages/core/src/dom/glass/shaders.ts")

#: The one condition that keeps the MSL out of the widget binary. Only the Live Activity sets it.
WIDGET_CONDITION = "HERMEY_LIVE_ACTIVITY"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def code(text: str) -> str:
    """The text with its comments removed, so an example written in a doc comment is not a literal."""
    return "\n".join(line.split("///")[0].split("//")[0] for line in text.splitlines())


def msl() -> str:
    """The MSL source, exactly as the process receives it: the string, not the file around it."""
    source = read(SOURCE)
    start = source.index('static let msl = """') + len('static let msl = """')
    end = source.index('"""', start)
    body = source[start:end]
    # The Swift file indents the string to its own level; the MSL sees the same lines, unindented,
    # and stripping the common margin keeps the `assertIn` checks reading like the source.
    indents = [len(line) - len(line.lstrip()) for line in body.splitlines() if line.strip()]
    margin = min(indents) if indents else 0
    return "\n".join(line[margin:] for line in body.splitlines())


def msl_code() -> str:
    return code(msl())


def decide_body() -> str:
    """The body of `BotAvatarGlassRoute.decide`, from its signature to its closing brace."""
    source = code(read(ROUTE))
    start = source.index("func decide(")
    return source[start:source.index("\n    }", start)]


def target_blocks() -> dict[str, str]:
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


class TheOneDecision(unittest.TestCase):
    """One function decides which drawing a surface gets, and one renderer follows it."""

    def test_exactly_one_function_decides(self):
        sources = list(UI.rglob("*.swift")) + list((ROOT / "Apps").rglob("*.swift"))
        deciders = [path for path in sources
                    if "BotAvatarGlassRoute" in read(path) and "static func decide(" in code(read(path))]
        self.assertEqual([path.name for path in deciders], ["OpenBotAvatarGlassRoute.swift"])

    def test_it_is_called_once_and_the_answer_travels(self):
        # One call site — the view's. Nothing else may ask, and the frame it answers draws.
        sources = list(UI.rglob("*.swift")) + list((ROOT / "Apps").rglob("*.swift"))
        calls = [(path.name, len(re.findall(r"BotAvatarGlassRoute\.decide\(", code(read(path)))))
                 for path in sources]
        self.assertEqual(sum(count for _, count in calls), 1, calls)
        self.assertIn(("OpenBotAvatarView.swift", 1), calls)

    def test_the_renderer_never_sees_the_route(self):
        renderer = code(read(RENDERER))
        # The renderer draws a frame; it has no opinion about which drawing the surface got, so the
        # question cannot be re-asked — or half-answered — behind the decision's back.
        self.assertNotIn("BotAvatarGlassRoute", renderer)
        self.assertNotIn("route == .metal", renderer)
        for probe in ("MTLCreateSystemDefaultDevice", "default.metallib", "ShaderLibrary",
                      "makeLibrary", "MakeLibrary"):
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

    def test_the_shader_body_never_reads_the_material_spec(self):
        # The body's pass is a silhouette and a tint: `BotAvatarGlassSurface.make` reads the spec
        # once, for the colour `bodyColor` derives, and nothing below it can paint a material.
        layer = code(read(LAYER))
        fill = layer.split("static func makeMask(")[1].split("guard let data = context.data")[0]
        for token in ("spec", "BotAvatarMaterialRender", "case .flat", "case .ramp", "paint("):
            self.assertNotIn(token, fill, token)
        # …and the tint arrives as a colour, not as the material it came from.
        self.assertIn("let tint = OpenBotAvatarMaterialPaint.bodyColor(spec, light: pose.light, tint: color)",
                      code(read(ROUTE)))

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
        # A device, the source *compiled in this process*, and not a preview — read once, together.
        self.assertIn("static let isAvailable: Bool = hasDevice && hasRuntimeShader && !isPreview", shader)
        self.assertIn('"XCODE_RUNNING_FOR_PREVIEWS"', shader)
        self.assertIn("static let hasRuntimeShader: Bool", shader)
        self.assertIn("HermeyGlassEngine.shared.isReady", shader)
        # The old test was a file look-up in the bundle. There is no such file any more.
        self.assertNotIn("metallib", shader)
        self.assertNotIn("Bundle.main", shader)

    def test_a_compile_that_fails_is_the_painted_material(self):
        layer = read(LAYER)
        # The library is the only thing that can fail silently into a crash if the error is dropped:
        # it is caught, logged with Metal's own text, and the pipeline stays nil.
        self.assertIn("library = try device.makeLibrary(source: HermeyGlassSource.msl, options: nil)", layer)
        caught = layer.split("catch {", 1)[1].split("}", 1)[0]
        self.assertIn("glassLog.error", caught)
        self.assertIn("the painted material draws instead", caught)
        # "Available" is the pipeline *and* the queue, so a half-built engine never answers yes.
        self.assertIn("var isReady: Bool { pipeline != nil && queue != nil }", layer)
        # …and the painter is what the route then answers, for the life of the process.
        self.assertIn("guard BotAvatarGlassShader.isAvailable else { return .canvas }", decide_body())

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


class TheShaderIsCompiledNotBuilt(unittest.TestCase):
    """One shader, as a string, compiled by Metal at run time — and one target kept out of it."""

    def test_there_is_no_shader_file_left(self):
        # A `.metal` file is what needed Apple's Metal toolchain, and what the app could not build.
        self.assertEqual([path.relative_to(ROOT).as_posix() for path in ROOT.rglob("*.metal")], [])
        self.assertEqual([path.relative_to(ROOT).as_posix()
                          for path in ROOT.rglob("*.metallib")], [])

    def test_the_source_lives_in_one_swift_string(self):
        carriers = [path for path in (ROOT / "Sources").rglob("*.swift")
                    if 'static let msl = """' in read(path)]
        self.assertEqual([path.name for path in carriers], ["HermeyGlassSource.swift"])
        source = msl()
        self.assertIn("#include <metal_stdlib>", source)
        self.assertIn("using namespace metal;", source)
        # The SwiftUI shader's own bridge is gone: a runtime library cannot be handed a `Layer`.
        self.assertNotIn("SwiftUI_Metal", msl_code())
        self.assertNotIn("stitchable", msl_code())
        self.assertNotIn("SwiftUI::Layer", msl_code())
        # …and the prologue says why, where the next person reads it.
        self.assertIn("a `SwiftUI::Layer` is not reachable from a runtime-compiled library", source)

    def test_the_string_is_one_library_one_pipeline(self):
        layer = read(LAYER)
        swift = code(layer)
        # Compiled once, in the singleton's init: not in a view, not in a draw, not per frame.
        self.assertEqual(swift.count("makeLibrary("), 1)
        self.assertIn("static let shared = HermeyGlassEngine()", swift)
        self.assertIn('library.makeFunction(name: "hermeyGlassBody")', swift)
        self.assertIn('library.makeFunction(name: "hermeyGlassVertex")', swift)
        self.assertEqual(swift.count("makeRenderPipelineState"), 1)
        # The pipeline is built for the format a `MetalKit` view presents.
        self.assertIn("static let pixelFormat: MTLPixelFormat = .bgra8Unorm", layer)
        self.assertIn("attachment.pixelFormat = Self.pixelFormat", layer)

    def test_nothing_compiles_per_frame(self):
        layer = read(LAYER)
        draw = layer.split("func draw(in view: MTKView)")[1].split("static func makeMask")[0]
        for token in ("makeLibrary", "makeRenderPipelineState", "makeFunction", "makeSamplerState",
                      "makeCommandQueue"):
            self.assertNotIn(token, draw, token)
        # What a frame does do: one texture when the pixels change, and six `float4`s.
        self.assertIn("setFragmentBytes(&uniforms", draw)
        self.assertIn("MemoryLayout<BotAvatarGlassUniforms>.stride", draw)
        self.assertIn("if texture == nil || texture?.width != Int(pixels.width)", draw)

    def test_the_library_is_lazy_and_held(self):
        layer = read(LAYER)
        # Stored properties on the singleton: an answer the route can read at any moment, without
        # paying for the compile again.
        for held in ("let library: MTLLibrary?", "let pipeline: MTLRenderPipelineState?",
                     "let sampler: MTLSamplerState?", "let queue: MTLCommandQueue?"):
            self.assertIn(held, layer)

    def test_the_two_apps_build_no_metallib(self):
        targets = target_blocks()
        for app in ("HermesMac", "HermesMobile"):
            self.assertNotIn("Apps/Shared/Glass", targets[app], app)
            self.assertNotIn(WIDGET_CONDITION, targets[app], app)
        text = read(PROJECT)
        self.assertNotIn("- path: Apps/Shared/Glass", text)

    def test_the_live_activity_gets_neither_the_source_nor_the_shader(self):
        targets = target_blocks()
        self.assertIn("HermesLiveActivity", targets)
        # It does not build a shader file…
        self.assertNotIn("Apps/Shared/Glass", targets["HermesLiveActivity"])
        # …and it is the only target that compiles the source out, which is how the MSL string stays
        # out of the widget binary while the folder it lives in is still compiled there.
        self.assertIn(f"SWIFT_ACTIVE_COMPILATION_CONDITIONS: {WIDGET_CONDITION}",
                      targets["HermesLiveActivity"])
        self.assertNotIn(WIDGET_CONDITION, targets["HermesMac"])
        self.assertNotIn(WIDGET_CONDITION, targets["HermesMobile"])
        # …and it still compiles the avatar's Swift, which is why the condition has to exist.
        self.assertIn("- path: Sources/HermeyUI/OpenBotAvatar", targets["HermesLiveActivity"])
        # The condition wraps the source and the engine, and answers "no shader" to the route.
        source_file = code(read(SOURCE))
        self.assertIn(f"#if !{WIDGET_CONDITION}", source_file)
        self.assertLess(source_file.index(f"#if !{WIDGET_CONDITION}"),
                        source_file.index("static let msl"))
        self.assertTrue(source_file.rstrip().endswith("#endif"))
        self.assertIn(f"#if canImport(Metal) && !{WIDGET_CONDITION}", read(LAYER))
        route = code(read(ROUTE))
        widget = route.split(f"#if !{WIDGET_CONDITION}")[1]
        self.assertIn("HermeyGlassEngine.shared.isReady", widget.split("#else")[0])
        self.assertIn("return false", widget.split("#else")[1].split("#endif")[0])
        # The view it compiles falls back to nothing, so a widget never builds a `MetalKit` view.
        self.assertIn("Color.clear", read(GLASS_VIEW))

    def test_the_package_still_compiles_the_source(self):
        # The apps get the shader through the package, whose HermeyUI target is the whole folder —
        # so the string is Swift source in the module and nothing has to be listed for it.
        package = read(PACKAGE)
        self.assertIn('.macOS(.v14)', package)
        self.assertIn('.iOS(.v17)', package)
        self.assertIn('path: "Sources/HermeyUI"', package)
        self.assertTrue(SOURCE.exists())
        self.assertTrue(SOURCE.is_relative_to(ROOT / "Sources" / "HermeyUI"))

    def test_no_layer_effect_survives(self):
        # `.layerEffect` and `ShaderLibrary` are exactly the path that needed `default.metallib`.
        for path in list(UI.rglob("*.swift")) + list((ROOT / "Apps").rglob("*.swift")):
            text = code(read(path))
            for token in ("layerEffect", "ShaderLibrary", "ShaderBo" + "olean",
                          "maxSampleOffset"):
                self.assertNotIn(token, text, f"{path.name}: {token}")


class NoPerFrameAllocation(unittest.TestCase):
    """The animating path builds six small vectors and one texture; it allocates no images."""

    def test_every_probe_is_read_once(self):
        shader = code(read(ROUTE))
        self.assertEqual(len(re.findall(r"MTLCreateSystemDefaultDevice\(\)", shader)), 1)
        # Both inside `static let`s: a `var` would be re-answered, and a `func` could be called.
        for name in ("hasDevice", "hasRuntimeShader", "isPreview", "isAvailable", "minimumSide"):
            self.assertRegex(shader, r"static let " + name)

    def test_the_uniform_builder_allocates_nothing(self):
        source = code(read(ROUTE))
        build = source.split("static func make(model:")[1].split("\n    }")[0]
        for allocation in (".map(", ".filter(", "Array(", "Data(", "CGImage", "UIGraphics",
                           "MTLTexture", "makeBuffer", "boundingRect"):
            self.assertNotIn(allocation, build, allocation)
        # One path is measured, and it is the four corners of the drawn box.
        self.assertIn(".applying(face)", build)

    def test_the_vertex_function_draws_no_buffer(self):
        source = msl_code()
        self.assertIn("vertex float4 hermeyGlassVertex(uint vertexID [[vertex_id]])", source)
        self.assertIn("encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)",
                      read(LAYER))

    def test_the_texture_covers_what_the_shader_may_sample(self):
        # The refraction reads 8 points out and the mask is the whole view, so a sample at the
        # body's edge is still on a pixel — the job `maxSampleOffset` did for `.layerEffect`.
        self.assertIn("float2(-8.0), float2(8.0)", msl_code())
        layer = read(LAYER)
        self.assertIn("makeMask(path: path, points: surface.size, pixels: pixels", layer)
        self.assertIn("scaleBy(x: CGFloat(width) / points.width, y: -CGFloat(height) / points.height",
                      layer)


class TheTermsAreUpstreams(unittest.TestCase):
    """Every constant in the fragment function is the reference's, not a guess."""

    def test_the_optics_are_the_reference_s(self):
        source = read(SOURCE)
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
            ("0.34, 0.97", "its clamp, re-based so a translucent body stays translucent"),
            ("float3(1.0 / 2.2)", "the gamma"),
        ):
            self.assertIn(literal, source, why)

    def test_the_prologue_cites_where_each_one_came_from(self):
        source = read(SOURCE)
        # A citation may name a range (`shaders.ts:391-399`), so every number in one counts.
        cited = {number for run in re.findall(r"shaders\.ts:\s*([\d,\s-]+)", source)
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
        # The silhouette is the body's own, through the frame's one transform — no `shrink`, and no
        # `bodyScale` anywhere near the pass that draws it.
        view = code(read(VIEW))
        metal_route = view.split("case .metal:")[1]
        self.assertIn("BotAvatarGlassView(surface: glass, path: model.silhouette.applying(face))",
                      metal_route)
        self.assertNotIn("bodyScale", metal_route)
        self.assertNotIn("shrink", metal_route)
        # …and the texture is filled from that path, in the body's own tint.
        layer = read(LAYER)
        self.assertIn("context.addPath(path.cgPath)", layer)

    def test_the_state_s_light_still_reaches_the_shader(self):
        shader = code(read(ROUTE))
        self.assertIn("Float(pose.light.rim)", shader)
        # The eight-state light table is unmoved: `light(time:reducedMotion:)` still drives it.
        self.assertIn("pose.light = light(time: t, reducedMotion: reducedMotion)", code(read(STATE)))
        paint = code(read(PAINT))
        self.assertIn("func light(time: Double, reducedMotion: Bool) -> OpenBotAvatarLight", paint)
        self.assertIn("var glassPulse: GlassPulse", paint)

    def test_the_shader_path_is_three_parts_in_paint_order(self):
        view = code(read(VIEW))
        metal_route = view.split("case .metal:")[1]
        order = [metal_route.index("pass: .behind"),
                 metal_route.index("BotAvatarGlassView(surface: glass"),
                 metal_route.index("pass: .over")]
        self.assertEqual(order, sorted(order))
        # The shader's pass is between the two `Canvas` passes and nothing else is between them.
        self.assertEqual(metal_route.count("Canvas {"), 2)
        self.assertEqual(metal_route.count("BotAvatarGlassView("), 1)


class TheBodyLooksLikeAGlass(unittest.TestCase):
    """The shading: a studio behind the glass, a mask under it, light on the edge."""

    def test_no_painted_body_is_asked_for_on_the_metal_route(self):
        # The prime suspect for an opaque blob: a `Canvas` body drawn under the shader. The frame
        # asks the renderer for `.behind` and `.over` only, and says so where the passes are named.
        view = code(read(VIEW))
        metal = view.split("case .metal:")[1]
        self.assertNotIn("pass: .body", metal)
        self.assertNotIn("pass: .all", metal)
        self.assertEqual(metal.count("pass: .behind"), 1)
        self.assertEqual(metal.count("pass: .over"), 1)
        # The invariant is stated as a value, not an `assert`: a Void expression inside a
        # `ViewBuilder` is a compile error, which broke the release build of the whole app.
        self.assertIn("!OpenBotAvatarRenderer.Pass.behind.drawsBody", metal)
        self.assertIn("!OpenBotAvatarRenderer.Pass.over.drawsBody", metal)
        self.assertNotIn("assert(!OpenBotAvatarRenderer.Pass.behind.drawsBody", metal,
                         "an assert in the view builder cannot compile")
        # …and the renderer's own gate is the one that does it.
        renderer = code(read(RENDERER))
        self.assertIn("if pass.drawsBody {", renderer)
        self.assertIn("var drawsBody: Bool { self == .all || self == .body }", renderer)

    def test_the_shader_never_reads_a_fill_from_the_texture(self):
        source = msl_code()
        # The mask is read for its silhouette and its distance field — `a`, `g`, `b` — and never for a
        # colour.
        self.assertIn("half4 silhouette = bodyLayer.sample(bodySampler, pos.xy / pixels);", source)
        self.assertIn("float coverage = float(silhouette.a);", source)
        self.assertIn("float inset = float(silhouette.g) * maxInset;", source)
        self.assertIn("float outside = float(silhouette.b) * maxInset;", source)
        for channel in ("silhouette.rgb", "silhouette.r", "behind", "sampled", "src.rgb", "src.a"):
            self.assertNotIn(channel, source, channel)
        # And the texture it is handed is white with the outline in its alpha, so even a mistake could
        # not be the body's tint.
        layer = read(LAYER)
        self.assertIn("CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)", layer)
        self.assertNotIn("CGFloat(tint.red)", layer)
        # The field is the drawn outline's, built on the CPU once per size — not the body's bbox.
        self.assertIn("private static func distanceField(", layer)
        self.assertIn("let inset = distanceField(coverage, width: width, height: height, inside: true)",
                      layer)
        self.assertIn("let outside = distanceField(coverage, width: width, height: height, inside: false)",
                      layer)
        self.assertNotIn("sdRoundedBox", source)

    def test_the_backdrop_is_a_studio_not_the_body(self):
        source = msl_code()
        self.assertIn("static inline float3 sampleGlassPlate(", source)
        self.assertIn("float3 plate = sampleGlassPlate(plateUV, jewelTint, detail);", source)
        # The plate is lit neutral and carries the body's hue at 45 %, not in full.
        self.assertIn("col *= mix(float3(1.0), jewelTint, 0.45);", source)
        self.assertIn("float3 through = plate * beer * mix(1.15, 0.78, thick);", source)
        # The key's own reflection on the face, and the rear surface seen through the front.
        self.assertIn("float hood = 1.0 - smoothstep(-0.04, 0.12", source)
        self.assertIn("abs(inset - rimWidth * 1.70)", source)
        # The tint is decoded to linear light before the optics, and gamma-encoded exactly once after.
        self.assertIn("float3 tint = pow(max(uniforms.tint.rgb, float3(0.0)), float3(2.2));", source)
        self.assertEqual(source.count("1.0 / 2.2"), 1)
        # A solid piece of glass: thickness, a lit rim, a key on the face, and something under it.
        self.assertIn("float thick = clamp(height / max(halfDepth, 0.001), 0.0, 1.0);", source)
        self.assertIn("float rimFacing = 0.62", source)
        self.assertIn("float caustic = (1.0 - smoothstep(0.10, 1.0, length(causticP))) * 0.75;", source)
        self.assertIn("float shadowAlpha = max(shadowShape * 0.55, contact * 0.30);", source)
        # The studio it stands in is the plate's, in the body's own hue, not a flat tint.
        self.assertIn("sampleGlassPlate(plateUV, jewelTint, detail)", source)
        self.assertIn("travel = clamp(travel, float2(-8.0), float2(8.0));", source)

    def test_the_layer_is_transparent_end_to_end(self):
        layer = read(LAYER)
        swift = code(layer)
        self.assertIn("MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)", layer)
        # The view cannot claim to be opaque, on either platform…
        self.assertIn("final class BotAvatarGlassMTKView: MTKView {", swift)
        self.assertIn("override var isOpaque: Bool { false }", swift)
        self.assertIn("view.isOpaque = false", swift)
        # …nor can its backing layer, which is the one AppKit actually composites.
        self.assertIn("view.layer?.isOpaque = false", swift)
        self.assertIn("metalLayer.isOpaque = false", swift)
        self.assertIn("metalLayer.backgroundColor = nil", swift)
        # …and the blend is premultiplied over, as the fragment writes.
        self.assertIn("attachment.sourceRGBBlendFactor = .one", layer)
        self.assertIn("attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha", layer)
        self.assertIn("float3 outRGB = col * alpha + causticLight * (caustic * (1.0 - alpha));", msl_code())

    def test_the_fallback_is_untouched(self):
        # Reduce transparency still gets the painted material, and the painter still paints its six
        # layers: the shader is an addition to the material, not a replacement for its fallback.
        self.assertIn("guard !reduceTransparency else { return .canvas }", decide_body())
        paint = code(read(PAINT)).lower()
        for layer in ("halo", "ramp", "sheen", "streak", "rim", "contact"):
            self.assertIn(layer, paint, layer)


class TheProofToolIsOptIn(unittest.TestCase):
    """The offscreen renderer exists, renders the asked-for cases, and no app target builds it."""

    PROOF = ROOT / "Tools" / "glass-proof"

    def test_it_renders_the_asked_for_cases(self):
        main = read(self.PROOF / "main.swift")
        self.assertIn('option("--sides", "24,48,200")', main)
        self.assertIn('option("--states", "idle,working")', main)
        self.assertIn('OpenBotAvatarPresets.all.first(where: { $0.id == "cat" })', main)
        # The app's own compile, the app's own uniforms and the app's own mask — not a copy.
        self.assertIn("HermeyGlassEngine.shared", main)
        self.assertIn("BotAvatarGlassDrawer.makeMask", main)
        self.assertIn("BotAvatarGlassSurface.make", main)
        # Offscreen, over the theme's dark canvas and over the surface one step up from it.
        self.assertIn("canvasBackground = (r: 0x0A, g: 0x0A, b: 0x0A)", main)
        self.assertIn("surfaceBackground = (r: 0x23, g: 0x23, b: 0x23)", main)

    def test_no_app_target_builds_it(self):
        for name, block in target_blocks().items():
            self.assertNotIn("Tools/glass-proof", block, name)
        self.assertNotIn("Tools/glass-proof", read(PROJECT))
        # No surface, view or model refers to it: the app cannot reach the proof at all.
        for path in list((ROOT / "Sources").rglob("*.swift")) + list((ROOT / "Apps").rglob("*.swift")):
            self.assertNotIn("glass-proof", code(read(path)), path.name)

    def test_a_numeric_mirror_reports_the_same_terms(self):
        # Without a Mac there is still a number for every claim: `numbers.py` mirrors the fragment
        # and prints the centre, mid and rim pixel at 24, 48 and 200 pt. It is guarded so it cannot
        # drift from the shader — every literal it relies on is pinned here.
        mirror = read(self.PROOF / "numbers.py")
        source = msl()
        for literal in ("mix(1.15, 0.78, thick)",
                        "math.exp(-sigma[i] * (optical * (0.30 + 0.60 * thick)))",
                        "0.62 + 0.38 *",
                        "1.0 - smoothstep(rim_width * 0.25, rim_width * 0.90",
                        "edge_transparency * 1.15",
                        "mix(0.120, 0.700, top)",
                        "mix(1.0, jewel[i], 0.45)",
                        "max(0.34, min(0.97,"):
            self.assertIn(literal, mirror, literal)
        for literal in ("mix(1.15, 0.78, thick)",
                        "opticalDist * (0.30 + 0.60 * thick)",
                        "0.62 + 0.38 * clamp(",
                        "abs(inset - rimWidth * 1.70)",
                        "edgeTransparency * 1.15",
                        "float3(0.120, 0.126, 0.140), float3(0.700, 0.740, 0.840)",
                        "mix(float3(1.0), jewelTint, 0.45)",
                        "0.34, 0.97"):
            self.assertIn(literal, source, literal)

    def test_it_runs_from_a_shell_script_on_the_mac(self):
        script = read(self.PROOF / "render.sh")
        self.assertIn("swiftc", script)
        self.assertIn("Glass/HermeyGlassSource.swift", script)
        self.assertIn("Glass/BotAvatarGlassLayer.swift", script)
        # One module, so the preview sees the same internal types the app does.
        self.assertIn("Tools/glass-proof/main.swift", script)


if __name__ == "__main__":
    unittest.main()
