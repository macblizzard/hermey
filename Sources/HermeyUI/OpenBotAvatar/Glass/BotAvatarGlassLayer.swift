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
//  `float4`s and one texture — the body's flat fill, which is the `SwiftUI::Layer` a runtime library
//  cannot be handed.
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
/// because nothing here mutates after init. The drawer, which does mutate (the texture cache), is
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

/// Draws one glass body: the body's flat fill as a texture, and the runtime shader over it.
///
/// One drawer per view. The texture is rebuilt only when the drawn pixels change size; a frame that
/// moves the pose re-uploads six `float4`s and nothing else.
final class BotAvatarGlassDrawer: NSObject, MTKViewDelegate {

    private var surface: BotAvatarGlassSurface?
    private var path: Path?
    private var texture: MTLTexture?

    /// The view the drawer paints into: transparent, paused, and redrawn only when SwiftUI hands it
    /// a new frame. No display link of its own — the avatar's own 10 Hz timeline is the clock.
    func makeView() -> MTKView? {
        guard let device = HermeyGlassEngine.shared.device else { return nil }
        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = HermeyGlassEngine.pixelFormat
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        // Not `framebufferOnly`: the drawable is presented only, but leaving it off keeps the view
        // usable if anything ever needs to read it, and costs nothing here.
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = self
        #if canImport(UIKit)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        #else
        view.layer?.isOpaque = false
        #endif
        return view
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

        // One texture per pixel size: the body's flat fill, drawn the way the Canvas drew it (same
        // path, same transform, same tint), at the drawable's own resolution.
        let pixels = view.drawableSize
        if texture == nil || texture?.width != Int(pixels.width) || texture?.height != Int(pixels.height) {
            texture = Self.makeTexture(path: path, tint: surface.tint,
                                       points: surface.size, pixels: pixels, device: device)
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

    /// The body's silhouette, filled flat in its own tint, into an RGBA texture whose first row is
    /// the top of the view — the orientation `[[position]]` uses.
    ///
    /// This is the only drawing the pass needs: the shader reads its alpha as the true silhouette and
    /// its colour as the refracted sample, which is exactly what `layer.sample` returned under the
    /// `.layerEffect` version.
    private static func makeTexture(path: Path,
                                    tint: MaterialColor,
                                    points: CGSize,
                                    pixels: CGSize,
                                    device: MTLDevice) -> MTLTexture? {
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
        context.setFillColor(CGColor(srgbRed: CGFloat(tint.red), green: CGFloat(tint.green),
                                     blue: CGFloat(tint.blue), alpha: 1))
        context.fillPath()

        guard let data = context.data else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: data, bytesPerRow: context.bytesPerRow)
        return texture
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
