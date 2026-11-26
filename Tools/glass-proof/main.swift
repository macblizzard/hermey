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
func render(side: Double, state: OpenBotAvatarState, pipeline: MTLRenderPipelineState) -> Rendered? {
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
                                             backdrop: .themed(dark: true), material: .glass)
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
        let name = stem.padding(toLength: 22, withPad: " ", startingAt: 0)
        print(String(format: "%@ %dx%d  cover=%d  mean=%.2f  max=%.2f  mask=%.0f ms",
                     name, frame.width, frame.height, covered, mean, Double(alphaMax) / 255,
                     lastMaskMilliseconds))
    }
}

print("glass-proof: wrote \(outDirectory.path)")
