//  The glass proof: the avatar's own glass body, rendered **offscreen** at three sizes and two
//  states, written as PNGs a person can look at.
//
//  Why it exists: the glass is a Metal fragment pass and a `MetalKit` view, so there is nothing in
//  this repository's test suite that can see it, and nobody reviewing a change can eyeball the app on
//  a device from here. This tool draws the same fragment, with the same uniforms, the same library
//  (`HermeyGlassSource.msl`, i.e. the run-time compile the app itself does) and the same silhouette
//  mask (`BotAvatarGlassDrawer.makeMask`), and writes the result composited over the theme's dark
//  canvas — which is what a person watching the avatar sees.
//
//  It is **opt-in and never part of the app**: no target in `project.yml` compiles this folder, and
//  nothing in `Sources/` refers to it. It is built and run by `Tools/glass-proof/render.sh` on a Mac
//  (`swiftc` over the avatar sources it needs), not by the app's build.
//
//  Usage:  glass-proof <output directory> [--scale 2] [--supersample 2] [--sides 24,48,200]
//                       [--states idle,working]
//
//  What it writes, for each case `<shape>-<state>-<side>pt`:
//
//  * `…-canvas.png`  — over the dark theme canvas (`Theme`'s `#0A0A0A`), the app's own background;
//  * `…-surface.png` — over the raised surface (`#232323`): a translucent body changes with what is
//    behind it, an opaque one does not, so this pair is the translucency proof;
//  * `…-pattern.png` — **the refraction proof.** The same fragment, recompiled from the same string
//    with `kPlatePattern` switched to 1, so the studio behind the body is a coarse checkerboard drawn
//    *by the shader* and then carried through the traced ray. Straight cells mean light went through
//    flat glass; compressed cells mean a lens; cells that fold back on themselves mean the ray turned
//    over at the wall. A composite of a pattern *behind* the view could not show any of that, because
//    the shader cannot sample what is behind it — which is why the pattern is inside the plate.
//  * `…-zoom.png`    — the same pixels, nearest-neighbour magnified, for the 24 and 48 pt cases,
//    because a 48 px PNG is not something an eye reads in a chat window.
//
//  Every case is rendered at `--supersample` times the pixel size and box-filtered down, so the
//  silhouette's edge — and the plate's, and the two rim lines' — are antialiased in the picture rather
//  than stair-stepped. The app draws at native resolution with the mask's own antialiasing; this is a
//  proof, and a proof should not be argued with about its edges.
//
//  It also prints one line per case with the alpha statistics inside the silhouette (`cover`, `mean`,
//  `max`) — a claim about translucency that is a number, not an adjective.
import AppKit
import Foundation
import Metal
import SwiftUI

// MARK: - Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
// The first bare argument is the output directory; `--flag value` pairs are not.
var outArgument: String?
var scan = 0
while scan < arguments.count {
    let argument = arguments[scan]
    if argument.hasPrefix("--") { scan += 2; continue }
    outArgument = argument
    break
}
let outDirectory = URL(fileURLWithPath: outArgument ?? FileManager.default.currentDirectoryPath
                        + "/glass-proof", isDirectory: true)

func option(_ name: String, _ fallback: String) -> String {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
        return fallback
    }
    return arguments[index + 1]
}

let scale = Double(option("--scale", "2")) ?? 2
let supersample = max(1, Int(option("--supersample", "2")) ?? 2)
let sides = option("--sides", "24,48,200").split(separator: ",").compactMap { Double($0) }
let states = option("--states", "idle,working").split(separator: ",").map(String.init)

// The background the person actually sees behind a glass body on a dark page, and one step up from
// it: `Theme`'s dark token table, `canvas: 0x0A0A0A`, `surface: 0x232323`.
let canvasBackground = (r: 0x0A, g: 0x0A, b: 0x0A)
let surfaceBackground = (r: 0x23, g: 0x23, b: 0x23)
// The two surfaces an avatar is actually drawn on: the dark theme's raised pane (`#1E1E1E`, the tone a
// row and a header sit at) and the light theme's surface (`#F2F2F2`, one step off `Theme.light.surface`
// so the number is quoted against a round value). These are the backdrops the translucency and the
// brightness are measured on.
let paneBackground = (r: 0x1E, g: 0x1E, b: 0x1E)
// The control: one step up from the pane. A body that only reads on #1E1E1E has been tuned to one
// number; this is the same judgement a shade lighter, and it is where a pure transmission would still
// be within 5 % of the page and still be invisible.
let controlBackground = (r: 0x2B, g: 0x2B, b: 0x2B)
let litBackground = (r: 0xF2, g: 0xF2, b: 0xF2)
// The busy page: a screenshot-shaped backdrop of rows, captions, icons and separators, generated here
// because the proof has no app to screenshot. A face that reads against a flat pane and vanishes
// against a page with content on it has not been fixed.
let busyHeader = (r: 0x26, g: 0x26, b: 0x26)

// MARK: - The app's own pieces

let engine = HermeyGlassEngine.shared
guard engine.isReady,
      let device = engine.device,
      let pipeline = engine.pipeline,
      let sampler = engine.sampler,
      let queue = engine.queue else {
    FileHandle.standardError.write(Data("glass-proof: the glass shader is not available on this Mac\n".utf8))
    exit(2)
}

/// The same MSL with the proof's studio switched on, and a pipeline built from it.
///
/// The app's engine is untouched: it compiles `HermeyGlassSource.msl` once per process and this is a
/// second library in the *proof tool*, for a picture the app never draws. One substitution, no edited
/// shader — so what the pattern picture shows is the transform the app's pass applies, including its
/// absorption, its rim and its two edges.
let patternPipeline: MTLRenderPipelineState? = {
    let source = HermeyGlassSource.msl.replacingOccurrences(of: "#define kPlatePattern 0",
                                                            with: "#define kPlatePattern 1")
    guard source != HermeyGlassSource.msl,
          let library = try? device.makeLibrary(source: source, options: nil),
          let vertex = library.makeFunction(name: "hermeyGlassVertex"),
          let fragment = library.makeFunction(name: "hermeyGlassBody") else {
        FileHandle.standardError.write(Data("glass-proof: the pattern variant did not compile\n".utf8))
        return nil
    }
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.label = "HermeyGlassProofPattern"
    descriptor.vertexFunction = vertex
    descriptor.fragmentFunction = fragment
    if let attachment = descriptor.colorAttachments[0] {
        attachment.pixelFormat = HermeyGlassEngine.pixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }
    return try? device.makeRenderPipelineState(descriptor: descriptor)
}()

guard let cat = OpenBotAvatarPresets.all.first(where: { $0.id == "cat" }),
      let model = OpenBotAvatarModel.model(for: cat) else {
    FileHandle.standardError.write(Data("glass-proof: the cat preset did not validate\n".utf8))
    exit(2)
}

try? FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)

// MARK: - One frame

/// The last case's mask build, in milliseconds: the one CPU-side cost this pass pays, once per size.
var lastMaskMilliseconds: Double = 0

/// One case's pixels: premultiplied RGBA, y down, at the drawable's resolution.
struct Rendered {
    var rgba: [UInt8]
    var width: Int
    var height: Int
}

/// One case at `supersample` times the resolution, box-filtered down to `width` × `height`.
func render(side: Double, state: OpenBotAvatarState, pipeline: MTLRenderPipelineState,
            dark: Bool = true) -> Rendered? {
    let points = CGSize(width: side, height: side)
    let finalPixels = CGSize(width: (side * scale).rounded(), height: (side * scale).rounded())
    let width = Int(finalPixels.width), height = Int(finalPixels.height)
    let sampleWidth = width * supersample, sampleHeight = height * supersample
    let pixels = CGSize(width: sampleWidth, height: sampleHeight)

    // A still frame of the state, at the pose the app holds when it is not animating: the same
    // uniforms a screenshot of a paused avatar would be drawn with.
    let pose = state.pose(mood: .neutral, time: 0, seed: BotAvatarHash.shippedHash(cat.id),
                          reducedMotion: true)
    let face = OpenBotAvatarRenderer.bodyTransform(model, pose: pose, size: points)
    let surface = BotAvatarGlassSurface.make(model: model, pose: pose, size: points, face: face,
                                             color: OpenBotAvatarRenderer.defaultColor,
                                             backdrop: .themed(dark: dark), material: .glass)
    // How long the mask costs, per case: the analytic field is the one part of this pass that runs on
    // the CPU, and it runs once per pixel size — so its number is the price of the fix, quoted rather
    // than guessed.
    let maskStart = CFAbsoluteTimeGetCurrent()
    guard let mask = BotAvatarGlassDrawer.makeMask(path: model.silhouette.applying(face),
                                                   points: points, pixels: pixels,
                                                   device: device) else { return nil }
    lastMaskMilliseconds = (CFAbsoluteTimeGetCurrent() - maskStart) * 1000

    var uniforms = surface.uniforms
    uniforms.size = SIMD4<Float>(Float(points.width), Float(points.height),
                                 Float(sampleWidth), Float(sampleHeight))

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                              width: sampleWidth, height: sampleHeight,
                                                              mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .managed
    guard let target = device.makeTexture(descriptor: descriptor),
          let commandBuffer = queue.makeCommandBuffer() else { return nil }

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
    encoder.label = "HermeyGlassProof"
    encoder.setRenderPipelineState(pipeline)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BotAvatarGlassUniforms>.stride, index: 0)
    encoder.setFragmentTexture(mask, index: 0)
    encoder.setFragmentSamplerState(sampler, index: 0)
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    encoder.endEncoding()

    if let blit = commandBuffer.makeBlitCommandEncoder() {
        blit.synchronize(resource: target)
        blit.endEncoding()
    }
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    // BGRA premultiplied, y down from the top-left — `[[position]]`'s own orientation.
    var bgra = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
    target.getBytes(&bgra, bytesPerRow: sampleWidth * 4,
                    from: MTLRegionMake2D(0, 0, sampleWidth, sampleHeight), mipmapLevel: 0)
    var rgba = [UInt8](repeating: 0, count: bgra.count)
    for i in stride(from: 0, to: bgra.count, by: 4) {
        rgba[i] = bgra[i + 2]
        rgba[i + 1] = bgra[i + 1]
        rgba[i + 2] = bgra[i]
        rgba[i + 3] = bgra[i + 3]
    }
    return Rendered(rgba: downsampled(rgba, width: sampleWidth, height: sampleHeight),
                    width: width, height: height)
}

/// A box filter over the supersampled frame: premultiplied, so the average is the average.
func downsampled(_ rgba: [UInt8], width: Int, height: Int) -> [UInt8] {
    guard supersample > 1 else { return rgba }
    let outWidth = width / supersample, outHeight = height / supersample
    var out = [UInt8](repeating: 0, count: outWidth * outHeight * 4)
    let perPixel = supersample * supersample
    for y in 0..<outHeight {
        for x in 0..<outWidth {
            var sum = [Int](repeating: 0, count: 4)
            for dy in 0..<supersample {
                let row = (y * supersample + dy) * width
                for dx in 0..<supersample {
                    let source = (row + x * supersample + dx) * 4
                    for channel in 0..<4 { sum[channel] += Int(rgba[source + channel]) }
                }
            }
            let destination = (y * outWidth + x) * 4
            for channel in 0..<4 {
                out[destination + channel] = UInt8(clamping: sum[channel] / perPixel)
            }
        }
    }
    return out
}

// MARK: - Writing

/// WCAG relative luminance of one sRGB channel triple 0…1, and the contrast ratio between two.
///
/// The number a person's eye uses for "how much darker", and the one an accessibility audit quotes:
/// `(lighter + 0.05) / (darker + 0.05)`.
func relativeLuminance(_ rgb: (Double, Double, Double)) -> Double {
    func linear(_ channel: Double) -> Double {
        channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(rgb.0) + 0.7152 * linear(rgb.1) + 0.0722 * linear(rgb.2)
}

func contrastRatio(_ a: Double, _ b: Double) -> Double {
    (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

/// The mean *colour* of a square of `rgba`, as an sRGB triple 0…1.
///
/// The mean has to be taken per channel and then turned into a luminance: averaging the three channels
/// first and treating the result as a grey reads a saturated body as a much darker one than it is, which
/// is how a `#BD471C` body could be reported at 1.8:1 against near-black ink when the pair is really 3.9:1.
func meanColor(_ rgba: [UInt8], width: Int, height: Int, centre: (Int, Int), side: Int) -> (Double, Double, Double) {
    var red = 0.0, green = 0.0, blue = 0.0
    var count = 0
    for y in max(0, centre.1 - side / 2)..<min(height, centre.1 + side / 2) {
        for x in max(0, centre.0 - side / 2)..<min(width, centre.0 + side / 2) {
            let i = (y * width + x) * 4
            red += Double(rgba[i]); green += Double(rgba[i + 1]); blue += Double(rgba[i + 2])
            count += 1
        }
    }
    guard count > 0 else { return (0, 0, 0) }
    let n = Double(count) * 255.0
    return (red / n, green / n, blue / n)
}

func composite(_ frame: Rendered, over background: (r: Int, g: Int, b: Int)) -> [UInt8] {
    var out = frame.rgba
    let br = UInt8(background.r), bg = UInt8(background.g), bb = UInt8(background.b)
    for i in stride(from: 0, to: out.count, by: 4) {
        let a = Double(out[i + 3]) / 255
        func blend(_ channel: UInt8, _ back: UInt8) -> UInt8 {
            UInt8(max(0, min(255, (Double(channel) + Double(back) * (1 - a)).rounded())))
        }
        out[i] = blend(out[i], br)
        out[i + 1] = blend(out[i + 1], bg)
        out[i + 2] = blend(out[i + 2], bb)
        out[i + 3] = 255
    }
    return out
}

/// A page with content on it, at the body's own pixel size.
///
/// The app's list is rows: a header, a separator, twelve captions and two icon columns on a `#1E1E1E`
/// pane. The centre cell is left empty because that is where the body is composited — everything the
/// face has to hold its own against is *around* it, which is the case the owner's screenshot is.
func busyPage(width: Int, height: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: width * height * 4)
    func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ colour: (r: Int, g: Int, b: Int)) {
        for y in max(0, y0)..<min(height, y1) {
            for x in max(0, x0)..<min(width, x1) {
                let i = (y * width + x) * 4
                out[i] = UInt8(colour.r); out[i + 1] = UInt8(colour.g); out[i + 2] = UInt8(colour.b)
                out[i + 3] = 255
            }
        }
    }
    fill(0, 0, width, height, (0x1E, 0x1E, 0x1E))
    // A header band, and the hairline under it.
    fill(0, 0, width, height / 8, busyHeader)
    fill(Int(Double(width) * 0.06), Int(Double(height) * 0.045),
         Int(Double(width) * 0.44), Int(Double(height) * 0.045) + max(2, height / 60), (0x8A, 0x8A, 0x8A))
    fill(0, height / 8, width, height / 8 + 1, (0x2C, 0x2C, 0x2C))
    // Three columns of rows; the centre cell stays empty for the body.
    let cellW = width / 3, cellH = height / 4
    for column in 0..<3 {
        for row in 0..<3 {
            let x0 = column * cellW, y0 = height / 8 + row * cellH
            if column == 1 && row == 1 { continue }
            // An icon block, and two caption bars beside it.
            fill(x0 + cellW / 8, y0 + cellH / 4, x0 + cellW / 8 + cellW / 8, y0 + cellH / 4 + cellW / 8,
                 (0x4A, 0x4A, 0x4A))
            fill(x0 + cellW / 3, y0 + cellH / 3, x0 + cellW - cellW / 10,
                 y0 + cellH / 3 + max(2, height / 90), (0x7A, 0x7A, 0x7A))
            fill(x0 + cellW / 3, y0 + cellH / 3 + cellH / 5, x0 + cellW - cellW / 4,
                 y0 + cellH / 3 + cellH / 5 + max(1, height / 120), (0x50, 0x50, 0x50))
            fill(x0, y0 + cellH - 1, x0 + cellW, y0 + cellH, (0x30, 0x30, 0x30))
        }
    }
    return out
}

/// The same premultiplied-over-body composite, over a page that is an image rather than one colour.
func composite(_ frame: Rendered, over page: [UInt8]) -> [UInt8] {
    var out = frame.rgba
    for i in stride(from: 0, to: out.count, by: 4) {
        let a = Double(out[i + 3]) / 255
        for channel in 0..<3 {
            let back = Double(page[i + channel])
            out[i + channel] = UInt8(max(0, min(255, (Double(out[i + channel]) + back * (1 - a)).rounded())))
        }
        out[i + 3] = 255
    }
    return out
}

func writePNG(_ rgba: [UInt8], width: Int, height: Int, to url: URL) {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let provider = CGDataProvider(data: Data(rgba) as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: width * 4, space: space,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false,
                              intent: .defaultIntent),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else {
        FileHandle.standardError.write(Data("glass-proof: could not encode \(url.lastPathComponent)\n".utf8))
        return
    }
    try? data.write(to: url)
}

func magnified(_ rgba: [UInt8], width: Int, height: Int, by factor: Int) -> [UInt8] {
    let wide = width * factor, tall = height * factor
    var out = [UInt8](repeating: 0, count: wide * tall * 4)
    for y in 0..<tall {
        let sourceY = y / factor
        for x in 0..<wide {
            let source = (sourceY * width + x / factor) * 4
            let destination = (y * wide + x) * 4
            out[destination] = rgba[source]
            out[destination + 1] = rgba[source + 1]
            out[destination + 2] = rgba[source + 2]
            out[destination + 3] = rgba[source + 3]
        }
    }
    return out
}

// MARK: - Every case

for side in sides {
    for name in states {
        guard let state = OpenBotAvatarState(rawValue: name) else {
            FileHandle.standardError.write(Data("glass-proof: no state called \(name)\n".utf8))
            continue
        }
        guard let frame = render(side: side, state: state, pipeline: pipeline) else {
            FileHandle.standardError.write(Data("glass-proof: \(name) at \(side) pt did not render\n".utf8))
            continue
        }
        let stem = "cat-\(name)-\(Int(side))pt"

        // The points every claim below is measured at. A patch a twenty-fourth of the body wide: wide
        // enough to average the dither, narrow enough that it cannot reach the dark features either side
        // of the centre — a twelfth reads the eyes and the junction line into the "centre" and reports a
        // body darker than it is. The ink is opaque `.082` in every channel.
        let centre = (frame.width / 2, frame.height / 2)
        let ring = (frame.width / 2 + frame.width * 26 / 100, frame.height / 2)
        let patch = max(6, frame.width / 24)
        let ink = relativeLuminance((0.082, 0.082, 0.082))

        writePNG(composite(frame, over: canvasBackground), width: frame.width, height: frame.height,
                 to: outDirectory.appendingPathComponent("\(stem)-canvas.png"))
        writePNG(composite(frame, over: surfaceBackground), width: frame.width, height: frame.height,
                 to: outDirectory.appendingPathComponent("\(stem)-surface.png"))
        if side <= 96 {
            let factor = max(2, 384 / max(1, frame.width))
            writePNG(magnified(composite(frame, over: canvasBackground),
                               width: frame.width, height: frame.height, by: factor),
                     width: frame.width * factor, height: frame.height * factor,
                     to: outDirectory.appendingPathComponent("\(stem)-zoom.png"))
        }

        // The four surfaces the body is judged on, and the reason there are four. `-pane` is the dark
        // theme's raised surface — the bot list the owner photographed, where 0.1.685's transmission left
        // black shapes. `-ctrl` is the same judgement a shade up (#2B2B2B), so a fix tuned to one number
        // cannot pass. `-lit` is the light theme's surface, drawn with the light scheme's own page: the
        // brighter, transmitting body the owner liked, unchanged. `-busy` is a page with rows and captions
        // on it, because a face that reads on a flat pane and disappears among text has not been fixed.
        writePNG(composite(frame, over: paneBackground), width: frame.width, height: frame.height,
                 to: outDirectory.appendingPathComponent("\(stem)-pane.png"))
        writePNG(composite(frame, over: controlBackground), width: frame.width, height: frame.height,
                 to: outDirectory.appendingPathComponent("\(stem)-ctrl.png"))
        let busy = busyPage(width: frame.width, height: frame.height)
        writePNG(composite(frame, over: busy), width: frame.width, height: frame.height,
                 to: outDirectory.appendingPathComponent("\(stem)-busy.png"))
        if let lit = render(side: side, state: state, pipeline: pipeline, dark: false) {
            let overLit = composite(lit, over: litBackground)
            writePNG(overLit, width: lit.width, height: lit.height,
                     to: outDirectory.appendingPathComponent("\(stem)-lit.png"))
            let atCentre = relativeLuminance(meanColor(overLit, width: lit.width, height: lit.height,
                                                        centre: centre, side: patch))
            let pageLum = relativeLuminance((0xF2 / 255.0, 0xF2 / 255.0, 0xF2 / 255.0))
            print(String(format: "  lit centre %.3f (%+.0f%% of page)  eyes %.2f:1",
                         atCentre, (atCentre / max(pageLum, 1e-4) - 1) * 100, contrastRatio(atCentre, ink)))
        }

        // The refraction proof: the same body over a studio that has edges in it.
        if let patternPipeline,
           let patternFrame = render(side: side, state: state, pipeline: patternPipeline) {
            writePNG(composite(patternFrame, over: canvasBackground),
                     width: patternFrame.width, height: patternFrame.height,
                     to: outDirectory.appendingPathComponent("\(stem)-pattern.png"))
        }

        // The numbers behind the picture: how much of the body the surface covers, and how much of
        // the background it lets through.
        var covered = 0, alphaSum = 0.0, alphaMax = 0
        for i in stride(from: 0, to: frame.rgba.count, by: 4) where frame.rgba[i + 3] > 8 {
            covered += 1
            alphaSum += Double(frame.rgba[i + 3]) / 255
        }
        for i in stride(from: 3, to: frame.rgba.count, by: 4) {
            alphaMax = max(alphaMax, Int(frame.rgba[i]))
        }
        let mean = covered > 0 ? alphaSum / Double(covered) : 0
        let padded = stem.padding(toLength: 22, withPad: " ", startingAt: 0)
        print(String(format: "%@ %dx%d  cover=%d  mean=%.2f  max=%.2f  mask=%.0f ms",
                     padded, frame.width, frame.height, covered, mean, Double(alphaMax) / 255,
                     lastMaskMilliseconds))

        // The brightness and the transmission, as numbers: the body's centre and its mid-ring over
        // every page it is drawn on, and the eyes against all of them. The ink is opaque (`.082` in every
        // channel, relative luminance 0.0075), so the two claims are that the body is *clearly* above a
        // dark page — it carries its own colour instead of a black shape — and that the pair clears 3:1.
        //
        // Measured on the composited *colour* per channel and then turned into a relative luminance, not
        // on a grey of the same luma: a saturated body averaged across channels reads a whole contrast
        // step darker than it is, which is how a 3.9:1 face was once reported at 1.8:1.
        var line = ""
        for (label, over, pageLum) in [
            ("pane", composite(frame, over: paneBackground),
             relativeLuminance((0x1E / 255.0, 0x1E / 255.0, 0x1E / 255.0))),
            ("ctrl", composite(frame, over: controlBackground),
             relativeLuminance((0x2B / 255.0, 0x2B / 255.0, 0x2B / 255.0))),
            ("busy", composite(frame, over: busy),
             relativeLuminance((0x1E / 255.0, 0x1E / 255.0, 0x1E / 255.0))),
        ] {
            let atCentre = relativeLuminance(meanColor(over, width: frame.width, height: frame.height,
                                                        centre: centre, side: patch))
            let atRing = relativeLuminance(meanColor(over, width: frame.width, height: frame.height,
                                                     centre: ring, side: patch))
            line += String(format: "  %@ centre %.3f (%+.0f%% of page)  ring %.3f  eyes %.2f:1",
                           label, atCentre, (atCentre / max(pageLum, 1e-4) - 1) * 100, atRing,
                           contrastRatio(atCentre, ink))
        }
        print(line)
    }
}

print("glass-proof: wrote \(outDirectory.path)")
