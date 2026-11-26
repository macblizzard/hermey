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
            // The band: past this inset the bevel's height and the body's local absorption have both
            // saturated, so the field's value there cannot change a pixel.
            let reach = 1.15 * max(surface.profile.x, surface.shape.w)
            texture = Self.makeMask(path: path, points: surface.size, pixels: pixels,
                                    reach: reach, device: device)
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
    /// Why the field is *analytic*: the two channels below used to come from a chamfer transform of
    /// the filled raster, which measures pixel centre to pixel centre — every value a whole number of
    /// pixels, biased by half a pixel and drifting with the edge's angle. The fragment reads the field
    /// as the argument of the bevel and differentiates it for the normal, so a fixed step per pixel
    /// became a step in the shading, and because a distance field's iso-lines run *parallel to the
    /// outline*, on a near-vertical edge those steps were vertical: the body was banded. `analyticField`
    /// measures point to segment instead, so there is no grid in the value at all; the gradient the
    /// shader reads is the outline's own normal, to the flattening's tolerance.

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
    /// - Parameter reach: the inset, in points, past which every term of the fragment has saturated —
    ///   the band the distance field is computed over. The lens passes `1.15 × max(rxy, halfDepth)`.
    static func makeMask(path: Path,
                         points: CGSize,
                         pixels: CGSize,
                         reach: Float,
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

        // The field, measured against the outline itself rather than against a raster of it: a
        // signed distance in points, normalised to half the view's short side — the one unit the
        // shader can read back from `size`, so no seventh uniform is needed. Positive is inside.
        let field = Self.analyticField(path: path, coverage: coverage, points: points,
                                       width: width, height: height, reach: reach)

        var packed = [UInt16](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            packed[i * 4] = Self.halfBits(1)
            packed[i * 4 + 1] = Self.halfBits(max(0, field[i]))
            packed[i * 4 + 2] = Self.halfBits(max(0, -field[i]))
            packed[i * 4 + 3] = Self.halfBits(Float(coverage[i]) / 255)
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

    /// IEEE-754 binary16 bits for a value in 0…1, rounded to nearest.
    ///
    /// Written out rather than `Float16(value).bitPattern`: the release binary is universal, and
    /// `Float16`'s conversions are not available to the x86_64 slice in every toolchain we build with
    /// — the build failed there and only there. This is arithmetic over a range already clamped to
    /// 0…1: a subnormal branch (2⁻²⁴ steps) and an exponent-plus-mantissa branch, which is exact to
    /// half's own precision.
    private static func halfBits(_ value: Float) -> UInt16 {
        let clamped = max(0, min(value, 1))
        if clamped < 6.1035156e-5 {                       // below half's smallest normal, 2⁻¹⁴
            return UInt16((clamped / 5.9604645e-8).rounded())
        }
        let exponent = Int(floor(log2(clamped)))          // -14…0
        let mantissa = Int(((clamped / pow(2, Float(exponent))) - 1) * 1024 + 0.5)
        if mantissa >= 1024 {
            return UInt16((exponent + 16) << 10)          // rounded up into the next binade
        }
        return UInt16(((exponent + 15) << 10) | mantissa)
    }

    /// One straight piece of the outline, with the vector it runs along kept beside it.
    ///
    /// The flattening's own scratch type: a `Path` is curves, and a point-to-*segment* distance needs
    /// segments, so the curves are cut into chords once per rebuild and the field's loop only ever does
    /// `a + e·t`. The box is there so each segment can visit the pixels it can possibly be nearest to.
    private struct GlassSegment {
        var ax: Float, ay: Float      // the start
        var ex: Float, ey: Float      // end − start
        var minX: Float, minY: Float  // the segment's own box, which bounds the pixels it visits
        var maxX: Float, maxY: Float
    }

    /// Every pixel's distance to the outline, computed from the path — not from a raster of it.
    ///
    /// The value is the true distance from the pixel's centre to the nearest point of the outline,
    /// in points, normalised to half the view's short side — the shader's own unit — and signed by
    /// the drawn silhouette: positive inside, negative outside. Nothing in it is a whole pixel, so the
    /// fragment's finite difference of it is the outline's normal rather than the grid's.
    ///
    /// Cost, and why it is shaped this way: a point-to-segment test per pixel per segment is
    /// 640 000 × 64 at the proof's 800 px mask, which measured seven seconds in an unoptimised build.
    /// So the field is computed as a *band* instead: `reach` is the inset past which every term in the
    /// fragment has saturated (the bevel's height stops at `rxy * 1.08`, the body's local absorption at
    /// `0.85` of the half depth), the array starts at that value, and each segment only visits the
    /// pixels inside its own box grown by the band. Pixels nobody visits keep the saturated value,
    /// which is the value the shader would have clamped to anyway — so the change is exact, not an
    /// approximation, and it is nine times less work.
    private static func analyticField(path: Path, coverage: [UInt8], points: CGSize,
                                      width: Int, height: Int, reach: Float) -> [Float] {
        let span = Float(0.5 * min(points.width, points.height))
        // A zero-sized or not-yet-laid-out surface would divide by zero, and a non-finite value in
        // the texture is a normal that is not a direction.
        guard span.isFinite, span > 0, width > 0, height > 0 else {
            return [Float](repeating: 0, count: max(0, width * height))
        }
        let segments = Self.segments(of: path)
        guard !segments.isEmpty else { return [Float](repeating: 0, count: width * height) }

        // The band: the lens' own numbers where it has them, and never more than the texture holds.
        let band = min(max(reach.isFinite ? reach : span, 0.75), span)
        // One sample per pixel centre, in the path's own points.
        let stepX = Float(points.width) / Float(width)
        let stepY = Float(points.height) / Float(height)

        var best = [Float](repeating: band * band, count: width * height)
        for segment in segments {
            let ex = segment.ex, ey = segment.ey
            let length2 = ex * ex + ey * ey
            let invLength2 = length2 > 1e-9 ? 1 / length2 : 0
            // This segment's pixels: its box, grown by the band, clipped to the texture.
            let x0 = max(0, Int(((min(segment.minX, segment.maxX) - band) / stepX).rounded(.down)))
            let x1 = min(width, Int(((max(segment.minX, segment.maxX) + band) / stepX).rounded(.up)) + 1)
            let y0 = max(0, Int(((min(segment.minY, segment.maxY) - band) / stepY).rounded(.down)))
            let y1 = min(height, Int(((max(segment.minY, segment.maxY) + band) / stepY).rounded(.up)) + 1)
            guard x0 < x1, y0 < y1 else { continue }
            for y in y0..<y1 {
                let sampleY = (Float(y) + 0.5) * stepY
                let wy = sampleY - segment.ay
                let row = y * width
                for x in x0..<x1 {
                    let wx = (Float(x) + 0.5) * stepX - segment.ax
                    let t = length2 > 1e-9 ? max(0, min(1, (wx * ex + wy * ey) * invLength2)) : 0
                    let qx = wx - ex * t, qy = wy - ey * t
                    let distance2 = qx * qx + qy * qy
                    if distance2 < best[row + x] { best[row + x] = distance2 }
                }
            }
        }

        var field = [Float](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            let distance = min(best[index].squareRoot(), band)
            // The sign is the drawn silhouette's own: the raster is the authority on which side of
            // the outline a pixel is, because it is the same fill the Canvas draws.
            let inside = coverage[index] > 127
            field[index] = (inside ? distance : -distance) / span
        }
        return field
    }

    /// The outline as line segments, in the points the path was built in.
    ///
    /// Curves are cut until the control polygon is within the tolerance of the chord — 0.06 pt, a
    /// tenth of the smallest pixel this material is drawn at — so the polyline is the outline for
    /// every purpose below and a corner stays a corner.
    private static func segments(of path: Path, tolerance: Float = 0.06) -> [GlassSegment] {
        // The path's own elements, in the order and the coordinate space they were built in. The
        // block only appends: `applyWithBlock` is escaping, so nothing that has to look ahead lives
        // inside it.
        enum Element {
            case move(CGPoint)
            case line(CGPoint)
            case quad(CGPoint, CGPoint)                  // end, control
            case curve(CGPoint, CGPoint, CGPoint)        // end, control 1, control 2
            case close
        }
        var elements: [Element] = []
        path.cgPath.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint: elements.append(.move(points[0]))
            case .addLineToPoint: elements.append(.line(points[0]))
            case .addQuadCurveToPoint: elements.append(.quad(points[1], points[0]))
            case .addCurveToPoint: elements.append(.curve(points[2], points[0], points[1]))
            case .closeSubpath: elements.append(.close)
            @unknown default: break
            }
        }

        var out: [GlassSegment] = []
        var current = CGPoint.zero
        var start = CGPoint.zero

        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        func append(_ a: CGPoint, _ b: CGPoint) {
            let ax = Float(a.x), ay = Float(a.y), bx = Float(b.x), by = Float(b.y)
            out.append(GlassSegment(ax: ax, ay: ay, ex: bx - ax, ey: by - ay,
                                    minX: min(ax, bx), minY: min(ay, by),
                                    maxX: max(ax, bx), maxY: max(ay, by)))
        }
        func cubic(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, depth: Int) {
            let dx = p3.x - p0.x, dy = p3.y - p0.y
            let chord = (dx * dx + dy * dy).squareRoot()
            func away(_ p: CGPoint) -> CGFloat {
                if chord < 1e-6 {
                    return ((p.x - p0.x) * (p.x - p0.x) + (p.y - p0.y) * (p.y - p0.y)).squareRoot()
                }
                return abs((p.x - p0.x) * dy - (p.y - p0.y) * dx) / chord
            }
            if depth >= 12 || max(away(p1), away(p2)) <= CGFloat(tolerance) {
                append(p0, p3)
                return
            }
            let p01 = mid(p0, p1), p12 = mid(p1, p2), p23 = mid(p2, p3)
            let p012 = mid(p01, p12), p123 = mid(p12, p23), middle = mid(p012, p123)
            cubic(p0, p01, p012, middle, depth: depth + 1)
            cubic(middle, p123, p23, p3, depth: depth + 1)
        }

        for element in elements {
            switch element {
            case .move(let point):
                current = point
                start = point
            case .line(let point):
                append(current, point)
                current = point
            case .quad(let end, let control):
                // The same curve as a cubic, with its controls at the control point's thirds.
                cubic(current,
                      CGPoint(x: current.x + 2.0 / 3.0 * (control.x - current.x),
                              y: current.y + 2.0 / 3.0 * (control.y - current.y)),
                      CGPoint(x: end.x + 2.0 / 3.0 * (control.x - end.x),
                              y: end.y + 2.0 / 3.0 * (control.y - end.y)),
                      end, depth: 0)
                current = end
            case .curve(let end, let control1, let control2):
                cubic(current, control1, control2, end, depth: 0)
                current = end
            case .close:
                if current != start { append(current, start) }
                current = start
            }
        }
        return out
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
