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
let litBackground = (r: 0xF2, g: 0xF2, b: 0xF2)

// MARK: - The page behind the body

/// A synthetic app page: the pane and control colours the app actually draws, with rows of text-like
/// bars through the middle where the body sits.
///
/// The pass's backdrop is a snapshot of the host's own region, and an offscreen tool has no host — so
/// this is the closest honest stand-in, and it is deliberately *busy*: a flat pane would prove the
/// body's translucency and nothing about its refraction, exactly as a smooth studio did. Straight
/// edges and light/dark contrast are what a bent ray makes visible, so the page carries a control
/// block, five rows of text at two weights, a hairline and a small accent square.
struct PageImage {
    /// RGBA, sRGB, first row is the top — the layout the shader's `position.y` uses.
    var rgba: [UInt8]
    var width: Int
    var height: Int
    /// The image's top-left corner in the body's own points (negative: the page reaches outside it).
    var origin: CGPoint
    /// The points one texel covers.
    var pointsPerTexel: CGFloat
}

/// The drawable's pixel size for a body of `side` points, at this run's scale and supersampling.
func drawableSize(side: Double) -> (points: CGSize, sample: CGSize, final: CGSize) {
    let points = CGSize(width: side, height: side)
    let final = CGSize(width: (side * scale).rounded(), height: (side * scale).rounded())
    let sample = CGSize(width: Int(final.width) * supersample, height: Int(final.height) * supersample)
    return (points, sample, final)
}

/// The page, drawn at `pixels` resolution and mapped so the body's box sits in its middle.
///
/// The region is three body-widths across — a margin of one body on every side — because a shoulder
/// sends its ray up to a body-width away and a page that stopped at the box would clamp every one of
/// them to its own edge.
func makePage(side: Double, pixels: CGSize, flat: (CGFloat, CGFloat, CGFloat)? = nil) -> PageImage? {
    let width = Int(pixels.width), height = Int(pixels.height)
    guard width >= 1, height >= 1,
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    let points = 3 * side
    let unit = CGFloat(width) / CGFloat(points)      // pixels per point of the page
    // y down from the top-left: the orientation the shader's `position` has.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: unit, y: -unit)

    func fill(_ rect: CGRect, _ colour: (CGFloat, CGFloat, CGFloat)) {
        context.setFillColor(CGColor(srgbRed: colour.0, green: colour.1, blue: colour.2, alpha: 1))
        context.fill(rect)
    }
    func rounded(_ rect: CGRect, radius: CGFloat, _ colour: (CGFloat, CGFloat, CGFloat)) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.addPath(path)
        context.setFillColor(CGColor(srgbRed: colour.0, green: colour.1, blue: colour.2, alpha: 1))
        context.fillPath()
    }

    let page = CGFloat(points)
    // The app's own pane and control colours: `Theme`'s `#1E1E1E` pane, `#2B2B2B` control.
    fill(CGRect(x: 0, y: 0, width: page, height: page), (0x1E / 255, 0x1E / 255, 0x1E / 255))

    // A flat page is the *measurement*: the same pane, with nothing on it, so the body's centre can be
    // compared with the backdrop it covers as a number. The busy page below is the *evidence*: it is
    // what makes a bend visible.
    if let flat {
        fill(CGRect(x: 0, y: 0, width: page, height: page), flat)
    } else {
        // A control block, upper left — the mid-grey the app's rows and buttons use.
        rounded(CGRect(x: page * 0.06, y: page * 0.07, width: page * 0.46, height: page * 0.17),
                radius: page * 0.012, (0x2B / 255, 0x2B / 255, 0x2B / 255))
        // …and one lower right, so the body's bottom shoulder has an edge to bend too.
        rounded(CGRect(x: page * 0.60, y: page * 0.74, width: page * 0.32, height: page * 0.13),
                radius: page * 0.010, (0x2B / 255, 0x2B / 255, 0x2B / 255))

        // Text: five rows of bars through the band the body covers, two weights, ragged right edges —
        // what a chat's message text looks like from a body's width away.
        let rows: [(CGFloat, CGFloat, CGFloat)] = [   // y, width fraction, brightness
            (0.36, 0.80, 0.86), (0.415, 0.70, 0.78), (0.47, 0.84, 0.86),
            (0.525, 0.62, 0.72), (0.58, 0.74, 0.80),
        ]
        for (y, fraction, brightness) in rows {
            let x = page * 0.09
            let barWidth = page * (1 - 2 * 0.09) * fraction
            fill(CGRect(x: x, y: page * y, width: barWidth, height: page * 0.016),
                 (brightness * 0.92, brightness * 0.92, brightness))
        }
        // Two vertical rules through the body's middle. A horizontal bar can only be *shifted* by a
        // displacement that is mostly vertical; a vertical edge across the body shows the lateral part of
        // the bend too, which is the half of the lens an eye reads first. They are the proof's own
        // device, not something the app draws.
        for x in [CGFloat(0.45), CGFloat(0.55)] {
            fill(CGRect(x: page * x, y: 0, width: max(1 / unit, page * 0.0018), height: page * 0.74),
                 (0xDF / 255, 0xDF / 255, 0xE2 / 255))
        }
        // A hairline and an accent square: the two features narrow enough to read as a line through the
        // wall, and the only saturated colour on the page.
        fill(CGRect(x: 0, y: page * 0.665, width: page, height: max(1 / unit, page * 0.0016)),
             (0x3A / 255, 0x3A / 255, 0x3C / 255))
        fill(CGRect(x: page * 0.09, y: page * 0.70, width: page * 0.030, height: page * 0.030),
             (0x3B / 255, 0x82 / 255, 0xF6 / 255))
    }

    guard let filled = context.data else { return nil }
    // `CGContext`'s own buffer is the image already (premultiplied, opaque), so copy it out once.
    let byteCount = width * height * 4
    var rgba = [UInt8](repeating: 0, count: byteCount)
    rgba.withUnsafeMutableBytes { destination in
        destination.copyMemory(from: UnsafeRawBufferPointer(start: filled, count: byteCount))
    }
    return PageImage(rgba: rgba, width: width, height: height,
                     origin: CGPoint(x: -side, y: -side),
                     pointsPerTexel: CGFloat(points) / CGFloat(width))
}

// MARK: - The app's own pieces

let engine = HermeyGlassEngine.shared
guard engine.isReady,
      let device = engine.device,
      let pipeline = engine.pipeline,
      let sampler = engine.sampler,
      let queue = engine.queue else {
    // Say *why*, not just that. The engine logs Metal's own error to the unified log, which a shell
    // cannot read; compiling the same string again here and printing the error is the difference
    // between a diagnosis and a shrug.
    if let device = MTLCreateSystemDefaultDevice() {
        do {
            _ = try device.makeLibrary(source: HermeyGlassSource.msl, options: nil)
        } catch {
            FileHandle.standardError.write(Data("glass-proof: the MSL did not compile:\n\(error)\n".utf8))
        }
    }
    FileHandle.standardError.write(Data("glass-proof: the glass shader is not available on this Mac\n".utf8))
    exit(2)
}

/// The same MSL with one or more of its compile-time switches changed, and a pipeline built from it.
///
/// The app's engine is untouched: it compiles `HermeyGlassSource.msl` once per process and these are
/// extra libraries in the *proof tool*, for pictures the app never draws. Every substitution is a
/// `#define` this same string carries, so each picture is this pass with one constant different — not
/// an illustration of it.
func variantPipeline(_ substitutions: [(String, String)], label: String) -> MTLRenderPipelineState? {
    var source = HermeyGlassSource.msl
    for (from, to) in substitutions {
        guard source.contains(from) else {
            FileHandle.standardError.write(Data("glass-proof: \(label) found no '\(from)' to change\n".utf8))
            return nil
        }
        source = source.replacingOccurrences(of: from, with: to)
    }
    guard let library = try? device.makeLibrary(source: source, options: nil),
          let vertex = library.makeFunction(name: "hermeyGlassVertex"),
          let fragment = library.makeFunction(name: "hermeyGlassBody") else {
        FileHandle.standardError.write(Data("glass-proof: the \(label) variant did not compile\n".utf8))
        return nil
    }
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.label = "HermeyGlassProof.\(label)"
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
}

/// The refraction proof: the studio plate is a coarse checkerboard, so the ray's own transform is what
/// the picture shows.
let patternPipeline = variantPipeline([("#define kPlatePattern 0", "#define kPlatePattern 1")],
                                      label: "pattern")

/// The fallback proof: the app's pass with **no page at all** — no snapshot and no surface colour, which
/// is the desktop pet's path and the body 0.1.683 shipped. Same string, same uniforms, same page behind
/// it, so the pair of pictures is "with the page" against "the studio plate", nothing else changed.
let studioPipeline = variantPipeline([("#define kBackdropPage 1", "#define kBackdropPage 0"),
                                     ("float pageKnown = uniforms.page.w;", "float pageKnown = 0.0;")],
                                     label: "studio")

/// The coordinate map: the same pass writing the page coordinate each pixel samples, so the
/// displacement can be subtracted rather than eyeballed.
let debugPipeline = variantPipeline([("#define kPageDebug 0", "#define kPageDebug 1")],
                                    label: "pagedebug")

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

/// The masks this run has already built, keyed by the drawable's pixel size and the body's points.
///
/// The mask is the one expensive CPU step (7 s at 800×800 under `-Onone`), and a case is now rendered
/// several times — over the canvas, the surface, a busy page, a flat pane, the fallback — all with the
/// same silhouette. Building it once per case is what keeps the tool usable while it is being judged.
var maskCache: [String: MTLTexture] = [:]

/// One black texel, bound where a render has no page — the shader tests `backdrop.w` before it samples,
/// so this is never read; the slot still has to hold something.
let blackTexel: MTLTexture? = {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1,
                                                             height: 1, mipmapped: false)
    descriptor.usage = .shaderRead
    guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
    let texel: [UInt8] = [0, 0, 0, 255]
    texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: texel, bytesPerRow: 4)
    return texture
}()

/// The page as the fragment's second texture — through the app's own upload, so the picture is of the
/// same texture the app binds (sRGB bytes, row 0 at the top, with its mip chain).
func pageTexture(_ page: PageImage) -> MTLTexture? {
    var made: MTLTexture?
    page.rgba.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        made = GlassBackdrop.texture(rgba: base, width: page.width, height: page.height, device: device)
    }
    return made
}

/// One case at `supersample` times the resolution, box-filtered down to `width` × `height`.
///
/// `page` is the app's own surface behind the body: bound and framed when it is given, left at
/// `backdrop.w == 0` when it is not (which is the studio plate, the shader's named fallback).
func render(side: Double, state: OpenBotAvatarState, pipeline: MTLRenderPipelineState,
            page: PageImage?, dark: Bool = true) -> Rendered? {
    let (points, pixels, finalPixels) = drawableSize(side: side)
    let width = Int(finalPixels.width), height = Int(finalPixels.height)
    let sampleWidth = Int(pixels.width), sampleHeight = Int(pixels.height)

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
    // than guessed. A second render of the same case reuses it.
    let maskKey = "\(side)-\(sampleWidth)-\(sampleHeight)"
    let mask: MTLTexture
    if let cached = maskCache[maskKey] {
        mask = cached
    } else {
        let maskStart = CFAbsoluteTimeGetCurrent()
        guard let built = BotAvatarGlassDrawer.makeMask(path: model.silhouette.applying(face),
                                                        points: points, pixels: pixels,
                                                        device: device) else { return nil }
        lastMaskMilliseconds = (CFAbsoluteTimeGetCurrent() - maskStart) * 1000
        maskCache[maskKey] = built
        mask = built
    }

    var uniforms = surface.uniforms
    uniforms.size = SIMD4<Float>(Float(points.width), Float(points.height),
                                 Float(sampleWidth), Float(sampleHeight))
    // The page, in the body's own points: its corner, and the points one texel covers. `w` is what the
    // fragment reads to choose between the page and the studio plate — 0 here is the named fallback.
    var backdropTexture = blackTexel
    if let page, let bound = pageTexture(page) {
        uniforms.backdrop = SIMD4<Float>(Float(page.origin.x), Float(page.origin.y),
                                        Float(page.pointsPerTexel), 1)
        backdropTexture = bound
    }

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
    encoder.setFragmentTexture(backdropTexture, index: 1)
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

/// WCAG relative luminance of one sRGB triple 0…1, and the contrast ratio between two.
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

/// The frame over an image — `image` is the page the body was drawn on, at the frame's own size.
func composite(_ frame: Rendered, over image: [UInt8]) -> [UInt8] {
    precondition(image.count == frame.rgba.count, "the page and the frame must be the same size")
    var out = frame.rgba
    for i in stride(from: 0, to: out.count, by: 4) {
        let a = Double(out[i + 3]) / 255
        for channel in 0..<3 {
            out[i + channel] = UInt8(max(0, min(255,
                (Double(out[i + channel]) + Double(image[i + channel]) * (1 - a)).rounded())))
        }
        out[i + 3] = 255
    }
    return out
}

/// The mean luminance of a square of `rgba`, in the sRGB units a person's eye uses for "how bright is
/// this" — the number the translucency claim is actually about.
func meanLuminance(_ rgba: [UInt8], width: Int, height: Int, centre: (Int, Int), side: Int) -> Double {
    var sum = 0.0, count = 0
    for y in max(0, centre.1 - side / 2)..<min(height, centre.1 + side / 2) {
        for x in max(0, centre.0 - side / 2)..<min(width, centre.0 + side / 2) {
            let i = (y * width + x) * 4
            sum += 0.2126 * Double(rgba[i]) + 0.7152 * Double(rgba[i + 1]) + 0.0722 * Double(rgba[i + 2])
            count += 1
        }
    }
    return count > 0 ? sum / Double(count) / 255.0 : 0
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
        // The page the body stands on, at the drawable's resolution: the app's own pane and control
        // colours with text-like rows through the middle. `nil` here is the studio plate.
        let pixels = drawableSize(side: side)
        let page = makePage(side: side, pixels: pixels.sample)
        let pane = makePage(side: side, pixels: pixels.sample, flat: (0x1E / 255, 0x1E / 255, 0x1E / 255))
        let control = makePage(side: side, pixels: pixels.sample, flat: (0x2B / 255, 0x2B / 255, 0x2B / 255))
        func final(_ page: PageImage?) -> Rendered? {
            guard let page else { return nil }
            return Rendered(rgba: downsampled(page.rgba, width: page.width, height: page.height),
                            width: Int(pixels.final.width), height: Int(pixels.final.height))
        }
        let pageFinal = final(page), paneFinal = final(pane), controlFinal = final(control)
        // The app's own pass, with the page behind it.
        guard let frame = render(side: side, state: state, pipeline: pipeline, page: page) else {
            FileHandle.standardError.write(Data("glass-proof: \(name) at \(side) pt did not render\n".utf8))
            continue
        }
        let stem = "cat-\(name)-\(Int(side))pt"

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

        // The page picture — the acceptance test for this round. The same body, the same pass, over a
        // page with text and controls on it: what a person sees when the avatar sits on the app's own
        // surface. Edges inside the body that do not line up with the edges outside it are the bend.
        if let pageFinal {
            writePNG(composite(frame, over: pageFinal.rgba), width: frame.width, height: frame.height,
                     to: outDirectory.appendingPathComponent("\(stem)-page.png"))
            // And the same frame over the same page with the page *switched off* — the studio plate,
            // i.e. the picture a host that cannot snapshot still gets.
            if let studio = studioPipeline,
               let studioFrame = render(side: side, state: state, pipeline: studio, page: nil) {
                writePNG(composite(studioFrame, over: pageFinal.rgba),
                         width: frame.width, height: frame.height,
                         to: outDirectory.appendingPathComponent("\(stem)-page-studio.png"))
            }
        }
        // The light theme's surface: the same body, drawn with the light scheme's own page, over
        // `#F2F2F2` — the case the owner's "brighter" is judged on, and the one where a washed-out face
        // would show first.
        if let lit = render(side: side, state: state, pipeline: pipeline, page: nil, dark: false) {
            writePNG(composite(lit, over: litBackground), width: lit.width, height: lit.height,
                     to: outDirectory.appendingPathComponent("\(stem)-lit.png"))
        }

        // The flat pane: the same body over `#1E1E1E`, which is what the app's surface actually is
        // behind an avatar. It is the picture the translucency number is measured on, and the one a
        // person would see in a list.
        if let paneFinal {
            writePNG(composite(frame, over: paneFinal.rgba), width: frame.width, height: frame.height,
                     to: outDirectory.appendingPathComponent("\(stem)-pane.png"))
            if let studio = studioPipeline,
               let studioFrame = render(side: side, state: state, pipeline: studio, page: nil) {
                writePNG(composite(studioFrame, over: paneFinal.rgba),
                         width: frame.width, height: frame.height,
                         to: outDirectory.appendingPathComponent("\(stem)-pane-studio.png"))
            }
        }

        // The coordinate map, for `bend.py --uv`: red is the page's x, green its y, at the place the
        // traced ray landed. Everything inside the silhouette is a displacement measurement.
        if let debugPipeline,
           let debugFrame = render(side: side, state: state, pipeline: debugPipeline, page: page) {
            writePNG(composite(debugFrame, over: canvasBackground),
                     width: debugFrame.width, height: debugFrame.height,
                     to: outDirectory.appendingPathComponent("\(stem)-uv.png"))
        }

        // The refraction proof: the same body over a studio that has edges in it.
        if let patternPipeline,
           let patternFrame = render(side: side, state: state, pipeline: patternPipeline, page: nil) {
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

        // The translucency claim, as a number: the body's centre against the page it covers. A body
        // that transmits reads within a fifth of its page; an opaque one reads at three times it.
        // Measured on the flat pane and the flat control — the app's own two surface colours — because
        // that is the claim; the busy page is measured too, and reported as what it is (a page with
        // text on it is brighter, and a tinted body cannot match a page it absorbs).
        // A patch a twenty-fourth of the body wide: wide enough to average the dither, narrow enough
        // that it cannot reach the dark features either side of the centre.
        let centre = (frame.width / 2, frame.height / 2)
        let square = max(6, frame.width / 24)
        let ink = relativeLuminance((0.082, 0.082, 0.082))
        var numbers = "  centre:"
        for (label, surface) in [("pane", paneFinal), ("control", controlFinal), ("page", pageFinal)] {
            guard let surface else { continue }
            let onPage = meanLuminance(surface.rgba, width: frame.width, height: frame.height,
                                       centre: centre, side: square)
            let body = meanLuminance(composite(frame, over: surface.rgba),
                                     width: frame.width, height: frame.height,
                                     centre: centre, side: square)
            let eyes = contrastRatio(relativeLuminance((body, body, body)), ink)
            numbers += String(format: "  %@ %.3f→%.3f (%+.0f%%) eyes %.1f:1", label, onPage, body,
                              (body / max(onPage, 0.0001) - 1) * 100, eyes)
        }
        if let studio = studioPipeline, let paneFinal,
           let studioFrame = render(side: side, state: state, pipeline: studio, page: nil) {
            let onPage = meanLuminance(paneFinal.rgba, width: frame.width, height: frame.height,
                                       centre: centre, side: square)
            let studioBody = meanLuminance(composite(studioFrame, over: paneFinal.rgba),
                                           width: frame.width, height: frame.height,
                                           centre: centre, side: square)
            numbers += String(format: "  | fallback on pane %.3f (%+.0f%%)", studioBody,
                              (studioBody / max(onPage, 0.0001) - 1) * 100)
        }
        print(numbers)
    }
}

print("glass-proof: wrote \(outDirectory.path)")
