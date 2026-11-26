//  The glass body's Metal pass: a runtime-compiled shader, one library per process, drawn into a
//  `MetalKit` view that sits over the avatar's own box.
//
//  Why it is not a `.layerEffect` any more: a `SwiftUI.Shader` can only look a function up in this
//  bundle's `default.metallib`, and building that file needs Xcode's Metal step, which needs the
//  Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`) — a 1–2 GB download the
//  owner's Mac does not have and CI cannot install. So the shader is a string
//  (`HermeyGlassSource.msl`) compiled at run time by Metal itself, and drawn by a `MetalKit` view
//  instead of by SwiftUI.
//
//  What that costs, and what it must not: the library, both functions, the pipeline state and the
//  sampler are built **once per process** in `HermeyGlassEngine.shared` and held; the per-frame path
//  builds no objects at all except the command buffer the drawable needs. A frame uploads six
//  `float4`s and one texture — the body's silhouette, which is all a runtime library can be handed of
//  a `SwiftUI::Layer`.
//
//  ## The view has to be transparent, all the way down
//
//  The glass is a translucent surface: what shows through it is the ribbons' `Canvas` and the page
//  behind them. Every layer between the drawable and the screen therefore has to keep its alpha —
//  the clear colour, the view, the backing layer and the blend — or an opaque black card is what the
//  person sees, with the glass painted on it. `BotAvatarGlassMTKView` and `transparent(_:)` are that
//  requirement in one place, and the blend below is premultiplied over, as the fragment writes.
//
//  ## The texture is a mask, not a fill
//
//  It holds the body's outline filled **white**. Its alpha is the silhouette the shader masks itself
//  with; its colour is deliberately *not* the body's, because the shader must never read a flat fill
//  back as "what is behind the glass" — that is what made the body an opaque coloured blob. See
//  `HermeyGlassSource.msl`'s prologue.
//
//  What happens when it will not compile: `HermeyGlassEngine` logs Metal's own error once, stays
//  not-ready, and `BotAvatarGlassRoute.decide` answers `.canvas` for the life of the process. The
//  painted glass draws; nothing crashes and nothing retries per frame.
//
//  The Live Activity is out of this file entirely (`!HERMEY_LIVE_ACTIVITY`, set by that target only):
//  its sources carry no MSL string and it never builds a `MetalKit` view.
#if canImport(Metal) && !HERMEY_LIVE_ACTIVITY
import Foundation
import SwiftUI
import Metal
import MetalKit
import os
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Once, not per avatar and not per frame.
private let glassLog = Logger(subsystem: "dev.hermey.app", category: "glass")

/// The one place the glass shader is compiled, and the only place that knows whether it worked.
///
/// A singleton on purpose: `device.makeLibrary(source:)` runs the Metal compiler, which costs tens of
/// milliseconds and must happen once per process — never per frame and never per avatar.
///
/// Thread confinement: every stored property is a `let` written once in `init` and `shared` is a
/// `static let`, so Swift's once-only initialisation is the whole of the synchronisation — any thread
/// may read the library or the pipeline and never sees a half-built engine, and no lock is needed
/// because nothing here mutates after init. The drawer, which does mutate (the mask cache), is
/// only ever touched from the main thread by `MTKView`'s own delegate calls.
final class HermeyGlassEngine {

    static let shared = HermeyGlassEngine()

    /// The process's GPU, or nil on a machine that has none.
    let device: MTLDevice?
    /// The shader, compiled from `HermeyGlassSource.msl`. Nil means the compile failed.
    let library: MTLLibrary?
    /// The body pass, built from that library for the drawable format below.
    let pipeline: MTLRenderPipelineState?
    let sampler: MTLSamplerState?
    let queue: MTLCommandQueue?

    /// The pipeline's colour attachment format: what a `MetalKit` view presents by default.
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    /// Samples per pixel on the body's pass.
    ///
    /// The edge is the material: a one-pixel line of Fresnel at a silhouette is the whole difference
    /// between glass and a tinted shape, and at one sample it snaps to the pixel grid — the rim
    /// staircase and the broken highlight that made the edge read as a cut-out. Four samples are
    /// resolved by the drawable itself (`MTKView` allocates the multisample texture when its own
    /// `sampleCount` is set), so this is coverage the *app* draws with, not a proof-only filter, and it
    /// costs three extra fragment invocations on a view that is at most 200 pt square — no pass, no
    /// allocation, no loop, and the 10 Hz timeline is unchanged.
    static let sampleCount = 4

    /// The shader compiled, the pipeline built and a queue exists — the whole of "available".
    var isReady: Bool { pipeline != nil && queue != nil }

    private init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device

        var library: MTLLibrary?
        var pipeline: MTLRenderPipelineState?
        var sampler: MTLSamplerState?
        var queue: MTLCommandQueue?

        if let device {
            do {
                library = try device.makeLibrary(source: HermeyGlassSource.msl, options: nil)
            } catch {
                // Metal's own text, once: this line is the whole diagnosis of a glass body that is
                // painted instead of lit, and it must not repeat for every avatar.
                glassLog.error("glass shader did not compile, the painted material draws instead: \(String(describing: error), privacy: .public)")
                library = nil
            }

            if let library {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.label = "HermeyGlassBody"
                descriptor.vertexFunction = library.makeFunction(name: "hermeyGlassVertex")
                descriptor.fragmentFunction = library.makeFunction(name: "hermeyGlassBody")
                descriptor.rasterSampleCount = Self.sampleCount
                if let attachment = descriptor.colorAttachments[0] {
                    attachment.pixelFormat = Self.pixelFormat
                    // Premultiplied over what is behind the body, which is the ribbons' `Canvas`:
                    // the fragment returns `rgb * a, a`, exactly as `.layerEffect` composited it.
                    attachment.isBlendingEnabled = true
                    attachment.rgbBlendOperation = .add
                    attachment.alphaBlendOperation = .add
                    attachment.sourceRGBBlendFactor = .one
                    attachment.sourceAlphaBlendFactor = .one
                    attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
                do {
                    pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
                } catch {
                    glassLog.error("glass shader compiled but its pipeline did not build, the painted material draws instead: \(String(describing: error), privacy: .public)")
                    pipeline = nil
                }
            }

            let samplerDescriptor = MTLSamplerDescriptor()
            samplerDescriptor.minFilter = .linear
            samplerDescriptor.magFilter = .linear
            samplerDescriptor.sAddressMode = .clampToEdge
            samplerDescriptor.tAddressMode = .clampToEdge
            sampler = device.makeSamplerState(descriptor: samplerDescriptor)
            queue = device.makeCommandQueue()
        }

        self.library = library
        self.pipeline = pipeline
        self.sampler = sampler
        self.queue = queue
    }
}

/// A `MetalKit` view that cannot be opaque.
///
/// `MTKView` inherits `NSView`'s default `isOpaque == true`, and AppKit's compositor then throws away
/// the alpha of every pixel the drawable was presented with — the glass is drawn, and a black card is
/// what shows. `isOpaque` is a read-only property on `NSView`, so it can only be answered by a
/// subclass; on iOS the same flag is a settable property, set in `makeView`.
final class BotAvatarGlassMTKView: MTKView {
    #if !canImport(UIKit)
    override var isOpaque: Bool { false }
    #endif
}

/// Draws one glass body: the body's silhouette mask as a texture, and the runtime shader over it.
///
/// One drawer per view. The mask is rebuilt only when the drawn pixels change size; a frame that
/// moves the pose re-uploads six `float4`s and nothing else.
final class BotAvatarGlassDrawer: NSObject, MTKViewDelegate {

    private var surface: BotAvatarGlassSurface?
    private var path: Path?
    private var texture: MTLTexture?

    /// The view the drawer paints into: transparent, paused, and redrawn only when SwiftUI hands it
    /// a new frame. No display link of its own — the avatar's own 10 Hz timeline is the clock.
    func makeView() -> MTKView? {
        guard let device = HermeyGlassEngine.shared.device else { return nil }
        let view = BotAvatarGlassMTKView(frame: .zero, device: device)
        view.colorPixelFormat = HermeyGlassEngine.pixelFormat
        // The same coverage the pipeline is built for; MetalKit allocates the multisample target and
        // resolves it into the drawable on present.
        view.sampleCount = HermeyGlassEngine.sampleCount
        // A zero-alpha clear: every pixel the body does not cover is *nothing*, not black.
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = self
        Self.transparent(view)
        return view
    }

    /// Transparent end to end: the view, its backing layer, and — on iOS — the platform flag that
    /// short-circuits them both.
    ///
    /// The layer is the one that matters. A `CAMetalLayer` is opaque by default and composites its
    /// drawable as if every pixel were solid, whatever alpha the drawable holds; `backgroundColor`
    /// nil is what leaves an uncovered pixel of the layer showing what is behind it.
    private static func transparent(_ view: MTKView) {
        #if canImport(UIKit)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        #else
        // The backing layer has to exist before its flags mean anything, and `wantsLayer` is what
        // creates it — so this comes first, not after.
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        #endif
        #if canImport(UIKit)
        // `UIView.layer` is a non-optional `CALayer`, so optional chaining here is a compile error —
        // the two platforms need the flag written differently, which is the whole reason for the split.
        view.layer.isOpaque = false
        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.isOpaque = false
            metalLayer.backgroundColor = nil
        }
        #else
        view.layer?.isOpaque = false
        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.isOpaque = false
            metalLayer.backgroundColor = nil
        }
        #endif
    }

    /// The next frame's numbers and silhouette, from the surface the view decided on.
    func update(_ view: MTKView?, surface: BotAvatarGlassSurface, path: Path) {
        guard let view, HermeyGlassEngine.shared.isReady else { return }
        self.surface = surface
        self.path = path
        requestGlassFrame(view)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        texture = nil
        // A view that was re-hosted can come back with its own idea of whether it is opaque.
        Self.transparent(view)
        requestGlassFrame(view)
    }

    func draw(in view: MTKView) {
        let engine = HermeyGlassEngine.shared
        guard let surface,
              let path,
              let pipeline = engine.pipeline,
              let sampler = engine.sampler,
              let queue = engine.queue,
              let device = engine.device,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor else { return }

        // One mask per pixel size: the body's silhouette, drawn the way the Canvas draws it (same
        // path, same transform), at the drawable's own resolution.
        let pixels = view.drawableSize
        if texture == nil || texture?.width != Int(pixels.width) || texture?.height != Int(pixels.height) {
            texture = Self.makeMask(path: path, points: surface.size, pixels: pixels, device: device)
        }
        guard let texture else { return }

        var uniforms = surface.uniforms
        uniforms.size = SIMD4<Float>(Float(surface.size.width), Float(surface.size.height),
                                     Float(pixels.width), Float(pixels.height))

        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = "HermeyGlassBody"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BotAvatarGlassUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// The body's silhouette into a floating-point texture whose first row is the top of the view —
    /// the orientation `[[position]]` uses — **and** the distance field of that outline.
    ///
    /// Why half precision and not RGBA8: the field is the argument of the thickness profile, its
    /// gradient is the surface normal, and the rim's width is read off that normal. An 8-bit channel
    /// normalised to half the short side quantises the inset to 0.4 pt at 200 pt — coarser than the
    /// pixels the shader is drawing — so the normal stepped, the rim staircase'd along a diagonal,
    /// and every gradient in the body banded at a width the eye reads as dither. A half float
    /// resolves the same field to 0.02 pt at 200 pt, which is below one pixel at every size this
    /// material is drawn at. It costs twice the texture's memory and nothing per frame: the mask is
    /// rebuilt only when the drawable's pixel size changes.
    ///
    /// * `a` — the drawn silhouette, antialiased (what limits the shaded region);
    /// * `g` — how far inside the outline the pixel is, in points, normalised to half the view's
    ///   short side (the shader multiplies by `0.5 * min(size)`); `b` — the same outside it;
    /// * `r` — deliberately white, so a fragment that read the colour by mistake would come out
    ///   white and be obvious, rather than the body's own tint.
    ///
    /// The field is the fix for a real flaw in the first pass: the shader used to measure "how deep
    /// inside" against the body's *bounding box*, so a cat's ear — a thin fin inside a tall box — was
    /// shaded as if it were the middle of a slab: no rim, no thinness, no glass. With the drawn
    /// outline's own distance field, thin parts are thin, and the rim follows the silhouette the
    /// person can see.
    ///
    /// Cost: two chamfer passes per rebuild, and a rebuild only when the pixel size changes — never
    /// per frame.
    static func makeMask(path: Path,
                         points: CGSize,
                         pixels: CGSize,
                         device: MTLDevice) -> MTLTexture? {
        guard pixels.width.isFinite, pixels.height.isFinite,
              pixels.width >= 1, pixels.height >= 1,
              points.width > 0, points.height > 0, points.width.isFinite, points.height.isFinite
        else { return nil }
        let width = max(1, Int(pixels.width.rounded()))
        let height = max(1, Int(pixels.height.rounded()))
        guard points.width > 0, points.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        // y down from the top-left, in the points the path was built in, scaled to pixels: the
        // texture's first row is then the view's first row, which is where `[[position]]` starts.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / points.width, y: -CGFloat(height) / points.height)
        context.addPath(path.cgPath)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fillPath()

        guard let filled = context.data else { return nil }
        var coverage = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = filled.advanced(by: y * context.bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width { coverage[y * width + x] = row[x * 4 + 3] }
        }

        let inset = distanceField(coverage, width: width, height: height, inside: true)
        let outside = distanceField(coverage, width: width, height: height, inside: false)
        // One green/blue unit is half the view's short side, in points — what the shader can read
        // back from `size`, so no seventh uniform is needed.
        let scale = Float(pixels.width / points.width)
        let span = Float(0.5 * min(points.width, points.height))
        func unit(_ pixels: Float) -> Float {
            // A zero-sized or not-yet-laid-out surface divides by zero and the distance field turns
            // into NaN/inf, and a non-finite value in the texture is a normal that is not a direction.
            guard scale.isFinite, scale > 0, span.isFinite, span > 0 else { return 0 }
            let scaled = pixels / scale / span
            guard scaled.isFinite else { return 0 }
            return max(0, min(scaled, 1))
        }

        var packed = [UInt16](repeating: 0, count: width * height * 4)
        let white = Float16(1).bitPattern
        for i in 0..<(width * height) {
            packed[i * 4] = white
            packed[i * 4 + 1] = Float16(unit(inset[i])).bitPattern
            packed[i * 4 + 2] = Float16(unit(outside[i])).bitPattern
            packed[i * 4 + 3] = Float16(Float(coverage[i]) / 255).bitPattern
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                  width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: packed, bytesPerRow: width * 8)
        return texture
    }

    /// The distance, in pixels, from every pixel to the nearest pixel on the other side of the
    /// outline: a two-pass chamfer transform with unit steps across and `√2` diagonally.
    ///
    /// `inside` picks which side is measured — how deep into the body, or how far out of it. A
    /// 3×4 neighbourhood and two sweeps is the standard approximation: exact for axis-aligned
    /// edges, within a few per cent on a diagonal, which is far below one rim's width.
    private static func distanceField(_ coverage: [UInt8], width: Int, height: Int,
                                      inside: Bool) -> [Float] {
        let far: Float = 1e6
        let diagonal = Float(2.0).squareRoot()
        var field = [Float](repeating: far, count: width * height)
        for i in 0..<field.count where (coverage[i] > 127) != inside {
            field[i] = 0
        }
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                var distance = field[index]
                if distance == 0 { continue }
                if y > 0 {
                    distance = min(distance, field[index - width] + 1)
                    if x > 0 { distance = min(distance, field[index - width - 1] + diagonal) }
                    if x + 1 < width { distance = min(distance, field[index - width + 1] + diagonal) }
                }
                if x > 0 { distance = min(distance, field[index - 1] + 1) }
                field[index] = distance
            }
        }
        for y in stride(from: height - 1, through: 0, by: -1) {
            for x in stride(from: width - 1, through: 0, by: -1) {
                let index = y * width + x
                var distance = field[index]
                if distance == 0 { continue }
                if y + 1 < height {
                    distance = min(distance, field[index + width] + 1)
                    if x > 0 { distance = min(distance, field[index + width - 1] + diagonal) }
                    if x + 1 < width { distance = min(distance, field[index + width + 1] + diagonal) }
                }
                if x + 1 < width { distance = min(distance, field[index + 1] + 1) }
                field[index] = distance
            }
        }
        return field
    }
}

/// One frame, on request: UIKit's `setNeedsDisplay()` takes no argument, AppKit's takes a rect and
/// answers the same question through `needsDisplay`.
private func requestGlassFrame(_ view: MTKView) {
    #if canImport(UIKit)
    view.setNeedsDisplay()
    #else
    view.needsDisplay = true
    #endif
}

/// One glass body, over the avatar's box: the `MetalKit` view SwiftUI hosts in its place.
struct BotAvatarGlassCanvas {
    var surface: BotAvatarGlassSurface
    var path: Path
}

#if canImport(UIKit)
extension BotAvatarGlassCanvas: UIViewRepresentable {
    func makeCoordinator() -> BotAvatarGlassDrawer { BotAvatarGlassDrawer() }

    func makeUIView(context: Context) -> MTKView {
        context.coordinator.makeView() ?? MTKView(frame: .zero, device: nil)
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.update(view, surface: surface, path: path)
    }
}
#else
extension BotAvatarGlassCanvas: NSViewRepresentable {
    func makeCoordinator() -> BotAvatarGlassDrawer { BotAvatarGlassDrawer() }

    func makeNSView(context: Context) -> MTKView {
        context.coordinator.makeView() ?? MTKView(frame: .zero, device: nil)
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.update(view, surface: surface, path: path)
    }
}
#endif
#endif
