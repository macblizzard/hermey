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
        # The traced ray lands up to two body-widths out, and `foldIntoPlate` keeps that inside ±1.55
        # of the plate, so no sample leaves the texture; the back face is read one depth vector away,
        # which the mask's own overdraw covers.
        self.assertIn("foldIntoPlate(land / halfExtent, 1.55)", msl_code())
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
            ("* kAbsorbGain + float3(kAbsorbFloor)", "Beer-Lambert's absorption, at its own gain"),
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
        self.assertIn("float coverage = edgeCoverage(inset, outside, foot, float(silhouette.a));", source)
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
        self.assertIn("private static func analyticField(", layer)
        self.assertIn("let field = Self.analyticField(path: path, coverage: coverage, points: points,",
                      layer)
        self.assertNotIn("sdRoundedBox", source)

    def test_the_backdrop_is_a_studio_not_the_body(self):
        source = msl_code()
        self.assertIn("static inline float3 sampleGlassPlate(", source)
        # The plate is the studio's room where the surface cannot name its page, and the page itself
        # where it can: a body that transmits a bright cyclorama is a body with nothing behind it.
        self.assertIn("float3 plate = mix(sampleGlassPlate(plateUV, plateFoot, jewelTint, detail), "
                      "carried, pageKnown);", source)
        self.assertIn("float plateGain = mix(kPlateGain, kPlateGainPage, pageKnown);", source)
        self.assertIn("float interiorGain = mix(kInteriorGain, kInteriorGainPage, pageKnown);", source)
        # The plate is lit neutral and carries the body's hue at 45 %, not in full.
        self.assertIn("col *= mix(float3(1.0), jewelTint, 0.45);", source)
        self.assertIn("float3 through = (plate * plateGain + gather * interiorGain) * beer;", source)
        # The geometry is renderer.ts's inflate solid, not a quarter circle of our own.
        self.assertIn("return flatZ + kCrown * capped + rz * sqrt(max(0.0, 1.0 - side * side));", source)
        self.assertIn("float flatZ = max(0.0, halfDepth - rz);", source)
        self.assertIn("#define kCrown 0.055", source)
        # The proof's own studio is a switch in this same string, so the pictures show this transform.
        self.assertIn("#define kPlatePattern 0", source)
        # The key's own reflection on the face, and the rear surface seen through the front.
        self.assertIn("float shoulder = softbox(reflDirS, float3(-0.52, -0.68, 0.52)", source)
        # The tint is decoded to linear light before the optics, and gamma-encoded exactly once after.
        self.assertIn("float3 tint = pow(max(uniforms.tint.rgb, float3(0.0)), float3(2.2));", source)
        # The body's pixels, the page's light, and the halo's colour are each encoded exactly once —
        # and no more: a fourth encode is a term that was added in the wrong space.
        self.assertEqual(source.count("1.0 / 2.2"), 3)
        # A solid piece of glass: thickness, a lit rim, a key on the face, and something under it.
        self.assertIn("float thick = clamp(height / max(halfDepth, 0.001), 0.0, 1.0);", source)
        # The geometry is renderer.ts's inflate solid, not a quarter circle of our own.
        self.assertIn("return flatZ + kCrown * capped + rz * sqrt(max(0.0, 1.0 - side * side));", source)
        self.assertIn("float flatZ = max(0.0, halfDepth - rz);", source)
        self.assertIn("#define kCrown 0.055", source)
        self.assertIn("float rimFacing = 0.62", source)
        self.assertIn("float landing = causticLanding(rxy, rz, flatZ) * mix(1.0, kThinLanding, localThin);",
                      source)
        self.assertIn("float shadowAlpha = tight + penumbra;", source)
        # The studio it stands in is the plate's, in the body's own hue, not a flat tint.
        self.assertIn("sampleGlassPlate(plateUV, plateFoot, jewelTint, detail)", source)
        self.assertIn("float2 plateFoot = fwidth(plateUV) + 1e-5;", source)

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
        # The halo is premultiplied into the same sum: `haloA` is its own alpha, so a glow never
        # brightens the pane by mass where the body does not stand.
        self.assertIn("float3 outRGB = col * alpha + haloRGB * haloA + causticRGB * (arcA + poolA * 0.55);",
                      msl_code())

    def test_the_fallback_is_untouched(self):
        # Reduce transparency still gets the painted material, and the painter still paints its six
        # layers: the shader is an addition to the material, not a replacement for its fallback.
        self.assertIn("guard !reduceTransparency else { return .canvas }", decide_body())
        paint = code(read(PAINT)).lower()
        for layer in ("halo", "ramp", "sheen", "streak", "rim", "contact"):
            self.assertIn(layer, paint, layer)


class TheFieldIsAnalytic(unittest.TestCase):
    """The mask's distance is measured from the outline, not relaxed across a raster of it.

    This is the striping's cause, in one place: a chamfer (or any binary-mask) transform returns
    whole-pixel values, the fragment reads one of them as the argument of the bevel and differentiates
    the same channel for its normal, and a distance field's iso-lines run parallel to the outline — so
    the steps came out as vertical bands. The field must be a point-to-segment distance or the bands
    come back, however smooth the terms downstream look.
    """

    def test_the_field_is_point_to_segment_not_a_relaxation(self):
        layer = code(read(LAYER))
        self.assertIn("private static func analyticField(", layer)
        # …and the mask is *built* from it, not merely holding it: the packed channels are its only
        # source, so there is nowhere for a rasterised field to come back in.
        self.assertIn("let field = Self.analyticField(path: path, coverage: coverage, points: points,",
                      layer)
        self.assertIn("packed[i * 4 + 1] = Self.halfBits(max(0, field[i]))", layer)
        self.assertIn("packed[i * 4 + 2] = Self.halfBits(max(0, -field[i]))", layer)
        self.assertIn("for segment in segments {", layer)
        # The projection onto the segment: a clamped dot product, then the point's distance to it.
        self.assertIn("let t = length2 > 1e-9 ? max(0, min(1, (wx * segment.ex + wy * segment.ey) "
                      "/ length2)) : 0", layer)
        self.assertIn("let qx = wx - segment.ex * t, qy = wy - segment.ey * t", layer)
        # …and no two-sweep chamfer left anywhere: its `√2` diagonal step was the staircase.
        self.assertNotIn("distanceField(", layer)
        self.assertNotIn("squareRoot()\n        var field", layer)
        self.assertNotIn("let diagonal", layer)

    def test_the_curves_are_flattened_to_a_tolerance(self):
        layer = code(read(LAYER))
        self.assertIn("private static func segments(of path: Path, tolerance: Float = 0.06)",
                      layer)
        self.assertIn("if depth >= 12 || max(away(p1), away(p2)) <= CGFloat(tolerance) {", layer)
        # Every element kind is carried, or a rounded preset would lose its curves.
        for element in (".moveToPoint", ".addLineToPoint", ".addQuadCurveToPoint",
                        ".addCurveToPoint", ".closeSubpath"):
            self.assertIn(element, layer, element)

    def test_the_sample_is_a_pixel_centre_in_the_path_s_own_points(self):
        layer = code(read(LAYER))
        self.assertIn("let stepX = Float(points.width) / Float(width)", layer)
        self.assertIn("let sampleX = (Float(x) + 0.5) * stepX", layer)
        self.assertIn("let sampleY = (Float(y) + 0.5) * stepY", layer)
        # The sign is the drawn silhouette's — the same fill the Canvas draws.
        self.assertIn("let inside = coverage[index] > 127", layer)
        # Half the view's short side is the unit, exactly what the shader multiplies back by.
        self.assertIn("let span = Float(0.5 * min(points.width, points.height))", layer)
        self.assertIn("float maxInset = 0.5 * min(size.x, size.y);", msl_code())

    def test_the_geometry_of_the_mask_is_unchanged(self):
        layer = code(read(LAYER))
        # Still an RGBA16F texture, still packed by hand, still one per pixel size — and still no
        # `Float16`, whose conversions the x86_64 slice of the universal build cannot always use.
        self.assertIn("pixelFormat: .rgba16Float", layer)
        self.assertIn("packed[i * 4] = Self.halfBits(1)", layer)
        self.assertIn("packed[i * 4 + 3] = Self.halfBits(Float(coverage[i]) / 255)", layer)
        self.assertIn("private static func halfBits(_ value: Float) -> UInt16", layer)
        self.assertNotIn("Float16(", layer)
        self.assertIn("if texture == nil || texture?.width != Int(pixels.width)", layer)


class TheLightIsReadFromTheFields(unittest.TestCase):
    """The two new terms are measurements of the body, not constants tuned to a look.

    A bounce that does not depend on the path through the glass is a brightening; a junction line
    that is not the field's own ridge is a painted streak; a caustic at one distance for the whole
    body is a U. Each of these would survive an eye, and each is what the previous round's critique
    named, so each is pinned to the quantity that makes it physical.
    """

    PROOF = ROOT / "Tools" / "glass-proof"

    def test_the_bounce_is_the_thickness_field_s_own(self):
        source = msl()
        # The wall's light, how square it stands to the ray, and the two-way path: `beer * beer` is
        # the transmittance of the ray's own optical path, so a thin fin bounces and a belly does not.
        self.assertIn("float wallFacing = clamp(dot(into, n2S), 0.0, 1.0);", source)
        self.assertIn("float3 bounce = wallLight * (wallFacing * wallFacing) * (beer * beer)", source)
        self.assertIn("* (1.0 - F1) * kBounceGain * detail;", source)
        self.assertIn("#define kBounceGain 1.35", source)
        # …and both factors it multiplies are the path's, which is the body's thickness.
        self.assertIn("float3 beer = absorptionAlong(optical, absorbSigma);", source)
        self.assertIn("float optical = opticalThickness(absorbingPath, halfDepth);", source)
        self.assertIn("through += bounce;", source)
        mirror = read(self.PROOF / "numbers.py")
        self.assertIn("BOUNCE_GAIN = 1.35", mirror)
        self.assertIn("bounce = [wall_light[i] * (wall_facing * wall_facing) * (beer[i] * beer[i])",
                      mirror)

    def test_the_junction_line_is_the_field_s_ridge(self):
        source = msl()
        # Four taps of the same mask at a one-point stencil: the field's own second difference.
        self.assertIn("float2 joinTexel = kJoinStencil * (pixels / max(size, float2(1.0)));", source)
        self.assertIn("float joinRidge = max(0.0, (float(silhouette.g) - joinAround * 0.25) * maxInset);",
                      source)
        self.assertIn("float joinLine = smoothstep(0.12, 0.40, joinRidge);", source)
        self.assertIn("#define kJoinStencil 1.0", source)
        # Gated to the wall: the belly's medial axis has a ridge too and must not light up.
        self.assertIn("joinLine *= (1.0 - smoothstep(0.10, 0.45, inset / max(halfDepth, 0.001)))",
                      source)
        mirror = read(self.PROOF / "numbers.py")
        self.assertIn("JOIN_GAIN = 0.85", mirror)
        self.assertIn("join_line = smoothstep(0.12, 0.40, join_ridge_value)", mirror)

    def test_the_caustic_lands_by_the_silhouette_s_own_thickness(self):
        source = msl()
        # The probe: a step into the body from this contour, read back as the *outside* distance,
        # which is positive only where the step crossed the far wall — the thin parts.
        self.assertIn("float probeDistance = max(0.75, kThinProbe * rxy);", source)
        self.assertIn("half4 probeField = bodyLayer.sample(bodySampler,", source)
        self.assertIn("float probeOutside = max(0.0, float(probeField.b) * maxInset);", source)
        self.assertIn("float localThin = clamp(probeOutside / probeDistance, 0.0, 1.0);", source)
        # Closer, narrower and hotter where the wall is thin, so the arc is not one width.
        self.assertIn("float landing = causticLanding(rxy, rz, flatZ) * mix(1.0, kThinLanding, localThin);",
                      source)
        self.assertIn("float arcWidth = max(0.60, landing * 0.055) * mix(kThickWidth, 1.0, localThin);",
                      source)
        self.assertIn("* mix(1.0, kThinBright, localThin)", source)
        mirror = read(self.PROOF / "numbers.py")
        self.assertIn("THIN_LANDING = 0.35", mirror)
        self.assertIn("landing = caustic_landing(rxy, rz, flat_z) * mix(1.0, THIN_LANDING, local_thin)",
                      mirror)

    def test_the_untouched_parts_are_still_untouched(self):
        # The three things this round must not move, restated where the new terms are pinned: the
        # interior's step count, the Reduce Transparency fallback, and the widget's exclusion.
        source = msl()
        self.assertIn("#define kInteriorSteps 12u", source)
        self.assertIn("for (uint i = 0u; i < kInteriorSteps; ++i)", source)
        self.assertIn("guard !reduceTransparency else { return .canvas }", decide_body())
        self.assertIn("guard material == .glass else { return .canvas }", decide_body())
        self.assertIn(f"#if !{WIDGET_CONDITION}", code(read(SOURCE)))
        self.assertNotIn("Float16(", code(read(LAYER)))


class TheBodyTransmitsThePage(unittest.TestCase):
    """The body is a tint over what is behind it, not a block in front of it.

    The round-4 critique said it in one line — "the body is only translucent at the very outer edges;
    the central body is incredibly dense" — and the measurement agreed: over the app's own pane the
    body's centre sat at three times the pane's luminance. The fix has three parts, and each is a
    quantity rather than a look:

    * the surface *names* the page it is drawn over (the theme's own surface colour), so the shader has
      something real to transmit — and says `.zero` where it cannot (the pet), which is the fallback;
    * the absorption is cut to a tint's strength, and stays a function of the path;
    * the invented studio is scaled by the page's own light, so a bright cyclorama cannot be the
      brightest thing on a dark page, and a light surface still gets a lit face.
    """

    def test_the_surface_names_the_page_it_is_drawn_over(self):
        route = code(read(ROUTE))
        # The uniform, and the one place that fills it.
        self.assertIn("var page: SIMD4<Float> = .zero", route)
        self.assertIn("page: BotAvatarGlassSurface.page(for: backdrop)", route)
        self.assertIn("static func page(for backdrop: OpenBotAvatarBackdrop) -> SIMD4<Float>", route)
        # The theme's own tokens, not an invented colour.
        self.assertIn("Float(0x23) / 255, Float(0x23) / 255, Float(0x23) / 255, 1", route)
        self.assertIn("Float(0xF0) / 255, Float(0xEE) / 255, Float(0xE6) / 255, 1", route)
        # …and the named fallback: the pet has no page, so the studio lights the body alone.
        self.assertIn("case .pet:", route)
        self.assertIn("return .zero", route)

    def test_the_fragment_transmits_it_and_falls_back_to_the_studio(self):
        source = msl_code()
        self.assertIn("float pageKnown = uniforms.page.w;", source)
        self.assertIn("float3 pageLight = pow(max(uniforms.page.rgb, float3(0.0)), float3(2.2)) * pageKnown;",
                      source)
        # The plate, the interior's slices and the wall's reflection all take the same mix, so the body's
        # light has one source and `pageKnown == 0` reproduces the pre-change body exactly.
        self.assertIn("float3 plate = mix(sampleGlassPlate(plateUV, plateFoot, jewelTint, detail), "
                      "carried, pageKnown);", source)
        self.assertIn("float3 slice = mix(sampleInternalStudio(posS, into, jewelTint, rearTIR ? 1.0 : 0.0,",
                      source)
        self.assertIn("carried, pageKnown);", source)
        # `carried` is the page plus the material's own light, and it is what every one of those mixes
        # takes — the plate, the interior's slices, the wall's reflection, the bounce and the focus.
        self.assertIn("float3 carried = pageLight + ownLight * kSelfLightRoom;", source)
        self.assertEqual(source.count("carried, pageKnown);"), 4)
        # The pair of gains is chosen by whether there is a page: 1.35 of a bright cyclorama over a page
        # that is 0.01 up is the density the critique named.
        self.assertIn("float plateGain = mix(kPlateGain, kPlateGainPage, pageKnown);", source)
        self.assertIn("float interiorGain = mix(kInteriorGain, kInteriorGainPage, pageKnown);", source)
        self.assertIn("#define kPlateGain 1.35", source)
        self.assertIn("#define kPlateGainPage 0.82", source)

    def test_the_front_face_is_as_bright_as_the_room_behind_it(self):
        source = msl_code()
        # The key's reflection on the face, scaled by the page's own luminance: on the dark pane it is a
        # hint, on a light surface the full studio. A 13.0-gain softbox over a 0.01 page is nine times
        # the page's light, measured — that highlight, not the plate, was the solid body.
        self.assertIn("float pageLum = dot(pageLight, float3(0.2126, 0.7152, 0.0722));", source)
        self.assertIn("float sheen = mix(1.0, clamp(pageLum * kPageSheenGain, kPageSheenFloor, 1.0), "
                      "pageKnown);", source)
        self.assertIn("accum *= sheen;", source)
        self.assertIn("#define kPageSheenGain 2.0", source)
        self.assertIn("#define kPageSheenFloor 0.03", source)
        # And the internal focus concentrates what the body carries rather than painting a white studio
        # spot on it.
        self.assertIn("float3 focusLight = mix(gather * 0.55 + keyColour * 0.45, carried * 1.20, "
                      "pageKnown);", source)

    def test_the_absorption_is_a_tint_and_still_a_function_of_the_path(self):
        source = msl_code()
        self.assertIn("#define kAbsorbGain 0.40", source)
        self.assertIn("#define kAbsorbFloor 0.045", source)
        self.assertIn("float3 absorbSigma = (-log(max(transColor, float3(0.12))) * kAbsorbGain "
                      "+ float3(kAbsorbFloor)) * tone.w;", source)
        self.assertIn("#define kAbsorptionOpacity 0.26", source)
        # The reference's constant is gone: no literal can flatten the gradient again.
        self.assertNotIn("* 0.62 + float3(0.08)", source)
        # …and the path is still scaled and shortened where the body is thin.
        self.assertIn("float absorbingPath = pathLength * (0.30 + 0.70 * localBody);", source)
        self.assertIn("float3 beer = absorptionAlong(optical, absorbSigma);", source)

    def test_the_mirror_follows_the_shader(self):
        mirror = read(ROOT / "Tools" / "glass-proof" / "numbers.py")
        for literal in ("PLATE_GAIN_PAGE = 0.82", "INTERIOR_GAIN_PAGE = 0.38",
                        "PAGE_SHEEN_GAIN = 2.0", "PAGE_SHEEN_FLOOR = 0.03",
                        "ABSORB_GAIN = 0.40", "ABSORB_FLOOR = 0.045"):
            self.assertIn(literal, mirror, literal)
        # It measures the claim, not just the picture: the three flat pages, the body's hue and
        # chroma on each, and the eyes against the body — in the contrast ratio the ink is built for.
        self.assertIn("def page_report(side):", mirror)
        self.assertIn("INK = 0.082", mirror)
        self.assertIn("def relative(rgb):", mirror)
        self.assertIn("def hue_chroma(rgb):", mirror)
        self.assertIn("eyes ", mirror)
        self.assertIn("'PASS' if ratio >= 3.0 else 'FAIL'", mirror)

    def test_the_proof_renders_the_surfaces_it_is_judged_on(self):
        main = read(ROOT / "Tools" / "glass-proof" / "main.swift")
        self.assertIn("let paneBackground = (r: 0x1E, g: 0x1E, b: 0x1E)", main)
        self.assertIn("let controlBackground = (r: 0x2B, g: 0x2B, b: 0x2B)", main)
        self.assertIn("let litBackground = (r: 0xF2, g: 0xF2, b: 0xF2)", main)
        self.assertIn('-pane.png', main)
        self.assertIn('-ctrl.png', main)
        self.assertIn('-lit.png', main)
        self.assertIn('-busy.png', main)
        self.assertIn("func busyPage(width: Int, height: Int) -> [UInt8]", main)
        # Measured on the composited colour, not on a grey of the same luma: a saturated body read that
        # way is a whole contrast step darker than the pixels are.
        self.assertIn("contrastRatio(atCentre, ink)", main)
        self.assertIn("relativeLuminance(meanColor(over, width: frame.width, height: frame.height,",
                      main)
        self.assertNotIn("relativeLuminance((atCentre, atCentre, atCentre))", main)


class TheBodyCarriesItsOwnColour(unittest.TestCase):
    """On a dark pane the face is a piece of coloured glass, not a black shape.

    0.1.685 made the body transmit the page it is drawn on, which is right over a page and wrong over a
    black one: transmission *multiplies* the backdrop, so over the app's own pane (`#1E1E1E`, linear
    0.0125) every bot was its hue multiplied by nothing. Measured then on the mirror: the body's centre
    0.129 against the pane's 0.118 — a difference nobody can see — and the eyes 1.13:1 against the pane,
    i.e. gone. The owner's words were "its all black now".

    The fix is the half of a material's colour that was missing: the body also *adds* its own chroma, and
    the amount is a function of the backdrop's own luminance. On a light page the term is exactly zero and
    0.1.685 is untouched; on a dark page the body lands in a luminance band chosen from the eye ink rather
    than by eye, so near-black features read at 3.9:1 and the hue is still the bot's own.

    The four claims below are the ones a photograph of the app is judged on: the colour is the material's
    and not only the page's, the mix moves with the backdrop, the eyes clear 3:1 on both named surfaces,
    and the four proofs are rendered. The numbers come from `Tools/glass-proof/numbers.py`, the mirror of
    the fragment that the suite already pins constant by constant.
    """

    @classmethod
    def setUpClass(cls):
        import importlib.util

        spec = importlib.util.spec_from_file_location(
            "glass_numbers", ROOT / "Tools" / "glass-proof" / "numbers.py")
        cls.numbers = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.numbers)
        mirror = cls.numbers
        cls.surface = mirror.surface(24.0)
        cls.centre = mirror.deepest_point(cls.surface)
        cls.measured = {
            "pane": cls.composited((0x23 / 255,) * 3, 0x1E),
            "ctrl": cls.composited((0x23 / 255,) * 3, 0x2B),
            "lit": cls.composited((0xF0 / 255, 0xEE / 255, 0xE6 / 255), 0xF2),
        }

    @classmethod
    def composited(cls, page_rgb, backdrop):
        """The body's centre as a person sees it: the fragment's colour, premultiplied over the page.

        Per channel and then turned into a relative luminance — a saturated body averaged across its
        channels and treated as a grey reads a whole contrast step darker than the pixels are.
        """
        mirror = cls.numbers
        pixel = mirror.shade(cls.surface, cls.centre, page_rgb=page_rgb)
        return {
            "rgb": tuple(pixel["colour"][i] * pixel["alpha"] + backdrop / 255 * (1 - pixel["alpha"])
                         for i in range(3)),
            "alpha": pixel["alpha"],
            "shadow": mirror.shade(cls.surface, cls.centre),
        }

    def test_the_chroma_is_the_material_s_own_and_not_only_the_page_s(self):
        source = msl_code()
        # The emission: the same `jewelTint` the rim and the caustic are lit with, divided by its own
        # luminance so the level is a brightness and the bot's hue decides only the colour.
        self.assertIn("float3 hueUnit = jewelTint / max(dot(jewelTint, float3(0.2126, 0.7152, 0.0722)), "
                      "0.02);", source)
        self.assertIn("float3 ownLight = hueUnit * (kSelfLightLevel * pageDark);", source)
        self.assertIn("#define kSelfLightLevel 0.70", source)
        # It is added to the page, not mixed into it: a mix with a dark page degenerates to the page,
        # which is exactly the fault ("the mix degenerates to pure transmission") this guard exists for.
        self.assertIn("float3 carried = pageLight + ownLight * kSelfLightRoom;", source)
        self.assertNotIn("carried = mix(pageLight", source)
        # One source: every term that used to take the page takes what the body carries.
        self.assertEqual(source.count("carried, pageKnown);"), 4)
        self.assertIn("float3 plate = mix(sampleGlassPlate(plateUV, plateFoot, jewelTint, detail), "
                      "carried, pageKnown);", source)
        # The share emitted where it is seen is added *after* the path's absorption — an emitted photon
        # does not cross the body, and a thick belly that filters its own colour down to the red end is
        # the same black face again. So the emission must come after the `* beer` line, not inside it.
        beer_at = source.index("float3 through = (plate * plateGain + gather * interiorGain) * beer;")
        emit_at = source.index("through += ownLight * ((1.0 - kSelfLightRoom) * (0.35 + 0.65 * thick));")
        self.assertLess(beer_at, emit_at)
        self.assertIn("#define kSelfLightRoom 0.35", source)

    def test_the_mix_is_a_function_of_the_backdrop_s_luminance(self):
        source = msl_code()
        self.assertIn("float pageDark = pageKnown * (1.0 - smoothstep(kPageSelfDark, kPageSelfLit, "
                      "pageLum));", source)
        self.assertIn("#define kPageSelfDark 0.05", source)
        self.assertIn("#define kPageSelfLit 0.55", source)
        # …and the ramp really is a ramp over the three surfaces the proof judges, not a switch that
        # would need retuning the first time the theme moves. In linear light: the pane and the control
        # are dark, the light page is not, and a mid grey is between them.
        def ramp(linear_luminance):
            return 1.0 - self.numbers.smoothstep(0.05, 0.55, linear_luminance)
        self.assertAlmostEqual(ramp(self.numbers.wcag(0x1E / 255)), 1.0, places=3)
        self.assertAlmostEqual(ramp(self.numbers.wcag(0x2B / 255)), 1.0, places=3)
        self.assertEqual(ramp(self.numbers.wcag(0xF2 / 255)), 0.0)
        self.assertTrue(0.05 < ramp(self.numbers.wcag(0x80 / 255)) < 0.95)

    def test_the_body_clears_the_ink_band_on_the_dark_pane(self):
        """Solved, not tuned by eye: the ink is fixed, so the body's luminance is the free variable."""
        mirror = self.numbers
        ink = mirror.relative((mirror.INK,) * 3)
        # 3:1 against the ink is the floor the band has to sit above.
        floor = 3.0 * (ink + 0.05) - 0.05
        centre = self.measured["pane"]
        body = mirror.relative(centre["rgb"])
        page = mirror.relative((0x1E / 255,) * 3)
        self.assertGreater(body, floor, f"the body must clear {floor:.3f} of relative luminance")
        # …and clearly above the pane, which is the thing "all black" meant.
        self.assertGreater(body, page * 6)
        # The bot's own hue is still identifiable at 38 pt: chroma, and the hue angle the tint's own.
        hue, chroma = mirror.hue_chroma(centre["rgb"])
        tint_hue, _ = mirror.hue_chroma(mirror.TINT)
        self.assertGreater(chroma, 0.35, f"chroma {chroma:.2f} is a grey body")
        self.assertLess(abs(hue - tint_hue), 30)
        # A body that carries its own light is denser than a film of it: the middle is not a wash.
        self.assertGreaterEqual(min(centre["alpha"], self.measured["ctrl"]["alpha"]), 0.6)

    def test_the_eyes_clear_three_to_one_on_both_named_surfaces(self):
        mirror = self.numbers
        ink = mirror.relative((mirror.INK,) * 3)

        def eyes(key):
            body = mirror.relative(self.measured[key]["rgb"])
            return (max(body, ink) + 0.05) / (min(body, ink) + 0.05)

        self.assertGreaterEqual(eyes("pane"), 3.0, "the face is unreadable on the pane again")
        self.assertGreaterEqual(eyes("ctrl"), 3.0, "the face is unreadable a shade up from the pane")
        self.assertGreaterEqual(eyes("lit"), 3.0, "the light page lost the eyes to the fix")
        # The page the owner liked is untouched: the light body keeps 0.1.685's brightness and its
        # transmission. Measured on this same mirror at 24 pt before the change: 0.569 of relative
        # luminance and alpha 0.596 — the emission is gated on the backdrop, so the light page gets
        # exactly zero of it.
        self.assertAlmostEqual(mirror.relative(self.measured["lit"]["rgb"]), 0.569, delta=0.02)
        self.assertGreater(self.measured["lit"]["alpha"], 0.55)
        # …and the desktop pet, which cannot name a page, is bit-for-bit what it was: no page, no
        # emission, the studio plate alone.
        self.assertEqual(self.measured["pane"]["shadow"]["colour"],
                         self.measured["lit"]["shadow"]["colour"])

    def test_the_proof_renders_the_four_surfaces(self):
        main = read(ROOT / "Tools" / "glass-proof" / "main.swift")
        for literal in ("-pane.png", "-ctrl.png", "-lit.png", "-busy.png"):
            self.assertIn(literal, main, literal)
        self.assertIn("let controlBackground = (r: 0x2B, g: 0x2B, b: 0x2B)", main)
        self.assertIn("func busyPage(width: Int, height: Int) -> [UInt8]", main)
        # The mirror carries the same constants, and reports the band rather than an adjective.
        mirror = read(ROOT / "Tools" / "glass-proof" / "numbers.py")
        for literal in ("SELF_LIGHT_LUM = 0.70", "SELF_LIGHT_ROOM = 0.35", "SELF_LIGHT_DENSITY = 0.78",
                        "SELF_LIGHT_DIM = 0.050", "SELF_LIGHT_LIT = 0.550"):
            self.assertIn(literal, mirror, literal)
        self.assertIn("#define kSelfLightDensity 0.78", msl_code())


class TheBodyGlowsWithoutBeingWashed(unittest.TestCase):
    """The trial: brighter on a dark pane, a halo outside the silhouette, and the face still readable.

    0.1.686 gave the body its own colour so a dark pane could not black it out, and the owner answered
    "they all feel a bit dark, maybe a little brighter with a little glow would make them pop better".
    Two numbers carry that and nothing else: `kSelfLightLevel` (how bright the body's own light is) and
    `kGlowRadius` / `kGlowStrength` (the halo). Both are named, bounded, and tied to the body's own
    size, and neither may touch the light page — a warm halo on paper is a grey smudge.
    """

    @classmethod
    def setUpClass(cls):
        import importlib.util

        spec = importlib.util.spec_from_file_location(
            "glass_numbers_glow", ROOT / "Tools" / "glass-proof" / "numbers.py")
        cls.numbers = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.numbers)

    def test_the_glow_is_two_named_bounded_constants_tied_to_the_side(self):
        source = msl_code()
        self.assertIn("#define kGlowRadius 0.16", source)
        self.assertIn("#define kGlowStrength 0.45", source)
        # Named, and in a band: a radius that is a share of the form (never wider than half of it, or
        # the halo is a fog around the head) and a strength that is an alpha (never 1, or it is a block
        # of paint on the page).
        radius = float(source.split("#define kGlowRadius")[1].split("\n")[0])
        strength = float(source.split("#define kGlowStrength")[1].split("\n")[0])
        self.assertTrue(0.02 <= radius <= 0.50, f"glow radius {radius} is out of band")
        self.assertTrue(0.05 <= strength <= 0.80, f"glow strength {strength} is out of band")
        # It scales: the radius is the body's own half width times the constant, not a point size.
        self.assertIn("float glowRadius = max(0.75, kGlowRadius * halfExtent.x);", source)
        # It is outside the silhouette only, and it is off on a light page — `pageDark` is exactly zero
        # there, so #F2F2F2 gets the pixels it had.
        self.assertIn("* exp(-max(outside, 0.0) / glowRadius)", source)
        self.assertIn("float halo = kGlowStrength * pageDark", source)
        self.assertIn("float haloA = clamp(halo * page, 0.0, 1.0);", source)
        # Cheap by construction: one Gaussian on a distance field the pass already samples.
        for expensive in ("CIGaussianBlur", "shadow(", "MPSImageGaussianBlur", "makeTexture"):
            self.assertNotIn(expensive, source, expensive)

    def test_the_eyes_clear_three_to_one_at_the_size_the_trial_was_rendered(self):
        """The eye ratio wins any argument with the brightness target: measured, on every named page.

        The mirror is evaluated at 200 pt — the size the trial picture is — over the three surfaces a
        face is judged on. If a brighter body ever pushes the ink below 3:1 the picture is not the
        trial any more, and this is the assert that says so.
        """
        mirror = self.numbers
        surface = mirror.surface(200.0)
        centre = mirror.deepest_point(surface)
        ink = mirror.relative((mirror.INK,) * 3)
        for name, page_rgb, backdrop in (
                ("pane", (0x23 / 255,) * 3, 0x1E),
                ("ctrl", (0x23 / 255,) * 3, 0x2B),
                ("lit", (0xF0 / 255, 0xEE / 255, 0xE6 / 255), 0xF2)):
            pixel = mirror.shade(surface, centre, page_rgb=page_rgb)
            rgb = tuple(pixel["colour"][i] * pixel["alpha"] + backdrop / 255 * (1 - pixel["alpha"])
                        for i in range(3))
            body = mirror.relative(rgb)
            ratio = (max(body, ink) + 0.05) / (min(body, ink) + 0.05)
            self.assertGreaterEqual(ratio, 3.0, f"the eyes read {ratio:.2f}:1 on the {name}")
            if name == "pane":
                # …and the body really is in the band the trial claims, not merely above the ink.
                self.assertGreater(body, 0.24, f"the body is {body:.3f} on the pane, too dark again")
                self.assertLess(body, 0.33, f"the body is {body:.3f} on the pane, over-bright")


class TheThreeTargetsAreSteps(unittest.TestCase):
    """Each thing that was wrong with the glass is a term the source must keep — not a look.

    The pictures are evidence, not the contract: these four check that the edge is coverage the app
    path computes (not a probe), that the caustic's distance is solved from the thickness profile and
    not blurred out of the body's middle, that absorption is the ray's own path, and that the interior
    still integrates over the same fixed number of slices.
    """

    def test_edge_coverage_is_a_named_step_the_app_path_uses(self):
        source = msl_code()
        self.assertIn("static inline float edgeCoverage(float inset, float outside, float foot, "
                      "float maskAlpha)", source)
        self.assertIn("float coverage = edgeCoverage(inset, outside, foot, float(silhouette.a));",
                      source)
        self.assertIn("alpha *= coverage;", source)
        # The rim's thin lines are filtered by the same footprint, not only the silhouette.
        self.assertIn("static inline float bandCoverage(", source)
        self.assertIn("float rimCore = bandCoverage(inset, 0.0,", source)
        self.assertIn("float darkLine = bandCoverage(inset, darkInset,", source)
        # The specular half: the key's reflection is feathered by the normal's own sweep.
        self.assertIn("float specFoot = min(0.30, length(fwidth(reflDirS)) * 0.85);", source)

    def test_the_caustic_is_the_thickness_field_not_a_radial_blur(self):
        source = msl_code()
        self.assertIn("static inline float causticLanding(float rxy, float rz, float flatZ)", source)
        body = source.split("static inline float causticLanding")[1].split("\n        }")[0]
        for term in ("criticalInset(", "bodyRise(", "bodyHeight(", "kIOR"):
            self.assertIn(term, body, term)
        self.assertIn("float landing = causticLanding(rxy, rz, flatZ) * mix(1.0, kThinLanding, localThin);",
                      source)
        # An offset curve of the silhouette at that distance — never a disc around the body.
        self.assertNotIn("poolAt", source)
        self.assertNotIn("length(p - centre", source)

    def test_absorption_is_a_function_of_path_length(self):
        source = msl_code()
        self.assertIn("static inline float opticalThickness(float pathLength, float halfDepth)",
                      source)
        self.assertIn("float optical = opticalThickness(absorbingPath, halfDepth);", source)
        self.assertIn("float absorbingPath = pathLength * (0.30 + 0.70 * localBody);", source)
        # The reference's saturating march compression is gone: no constant can flatten the gradient.
        self.assertNotIn("refScale", source)
        # Its transmittance is the path's, and the alpha carries the same term.
        self.assertIn("float3 beer = absorptionAlong(optical, absorbSigma);", source)
        self.assertIn("+ kAbsorptionOpacity * (1.0 - lumThrough)", source)

    def test_the_interior_step_count_is_unchanged(self):
        source = msl()
        self.assertIn("#define kInteriorSteps 12u", source)
        self.assertIn("for (uint i = 0u; i < kInteriorSteps; ++i)", source)


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
        for literal in ("(surface_col[i] * studio_gain + gather[i] * interior_gain) * beer[i]",
                        "optical_thickness(absorbing_path, half_depth)",
                        "0.62 + 0.38 *",
                        "ABSORPTION_OPACITY * (1.0 - lum_through)",
                        "band_coverage(inset, 0.0, max(0.30, rim_width * 0.13), foot)",
                        "caustic_landing(rxy, rz, flat_z) * mix(1.0, THIN_LANDING, local_thin)",
                        "caustic_rgb = tuple(", 
                        "mix(0.120, 0.700, top)",
                        "mix(1.0, jewel[i], 0.45)",
                        "max(0.34, min(0.97,",
                        "return flat_z + CROWN * capped + rz * math.sqrt(",
                        "(0.25 + 0.75 * f1)"):
            self.assertIn(literal, mirror, literal)
        for literal in ("float3 through = (plate * plateGain + gather * interiorGain) * beer;",
                        "float optical = opticalThickness(absorbingPath, halfDepth);",
                        "0.62 + 0.38 * clamp(",
                        "+ kAbsorptionOpacity * (1.0 - lumThrough)",
                        "bandCoverage(inset, 0.0, max(0.30, rimWidth * 0.13), foot)",
                        "float landing = causticLanding(rxy, rz, flatZ) * mix(1.0, kThinLanding, localThin);",
                        "float3(0.120, 0.126, 0.140), float3(0.700, 0.740, 0.840)",
                        "mix(float3(1.0), jewelTint, 0.45)",
                        "0.34, 0.97",
                        "return flatZ + kCrown * capped + rz * sqrt(",
                        "(0.25 + 0.75 * F1)"):
            self.assertIn(literal, source, literal)
        # The geometry's two constants are one number on both sides, and the mirror reads them.
        self.assertIn("#define kInteriorSteps 12u", source)
        self.assertIn("INTERIOR_STEPS = 12", mirror)
        self.assertIn("CROWN = 0.055", mirror)

    def test_it_runs_from_a_shell_script_on_the_mac(self):
        script = read(self.PROOF / "render.sh")
        self.assertIn("swiftc", script)
        self.assertIn("Glass/HermeyGlassSource.swift", script)
        self.assertIn("Glass/BotAvatarGlassLayer.swift", script)
        # One module, so the preview sees the same internal types the app does.
        self.assertIn("Tools/glass-proof/main.swift", script)


if __name__ == "__main__":
    unittest.main()
