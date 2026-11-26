//  The page behind a glass body: a snapshot of the host's own region, taken when the body's place on
//  the page changes — never per frame — so the refracting pass has the app's real surface to bend
//  instead of a studio plate.
//
//  ## Why a snapshot and not the studio
//
//  The body is a lens. Until this file existed, the only thing for its traced ray to land on was a
//  studio painted inside the shader: bright, warm and *nowhere*, so a body over an app surface showed
//  a lit cyclorama that the page had never contained. Two independent reviews of the shipped render
//  named the same thing — "the body is only translucent at the very outer edges" — and they were
//  right: a body that shows a studio shows nothing the person can recognise, and an unrecognisable
//  transmission reads as density.
//
//  So the host hands over what is actually there. `GlassBackdrop.capture` renders the region of the
//  window's content view the body covers (plus a margin, so the refracted ray has somewhere to land)
//  into an 8-bit image; `BotAvatarGlassDrawer` uploads it once per capture and the fragment samples it
//  at the coordinate the traced ray leaves the glass at. An edge in that page — a row's, a control's,
//  a line of text — then arrives inside the body displaced, compressed and, at the wall, folded. That
//  displacement is the whole effect. A gradient could not show it, which is why this is a picture of
//  the page and not a tint.
//
//  ## When there is no page, and where that is said
//
//  Snapshotting is a platform call that can fail, and three of the app's five surfaces have no page to
//  snapshot at all. `GlassBackdrop.capture` answers nil for every one of them and the shader's
//  `sampleBehind` falls back to the studio plate — the exact picture the previous round shipped:
//
//  * **the Live Activity** — `HERMEY_LIVE_ACTIVITY` compiles neither this file nor the engine, and the
//    widget draws the painted material; there is no glass view to snapshot for;
//  * **Reduce Transparency** — `BotAvatarGlassRoute.decide` answers `.canvas` before a glass view is
//    built, so no drawer exists to ask;
//  * **a host that cannot snapshot** — no window yet (the first layout pass), a preview host, a view
//    whose layer the platform refuses to render, a zero-sized crop. The drawer simply keeps no page
//    and the body is drawn exactly as it was before this file.
//
//  The fourth is the offscreen proof: `Tools/glass-proof` renders the same fragment with a synthetic,
//  deliberately busy page — the app's own pane colours and rows of text-like bars — so the bend can be
//  judged without a device, and also renders the `kBackdropPage 0` fallback for comparison.
//
//  ## Cost
//
//  One capture per place-change, throttled to `refreshInterval` (0.5 s) so a scrolling list cannot ask
//  for one per frame; each is a crop of the content view, an 8-bit RGBA copy and one texture upload —
//  milliseconds, on the main thread, against a body that is redrawn ten times a second. Nothing here
//  runs while the body is merely turning: the pose is the shader's business, the page is the host's.
#if canImport(Metal) && !HERMEY_LIVE_ACTIVITY
import Foundation
import Metal
import MetalKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// One snapshot of the page behind a glass body, ready to bind as the fragment's second texture.
struct GlassBackdropPage {
    /// The snapshot: sRGB bytes, top row first, `rgba8Unorm` — the page as the app drew it.
    var texture: MTLTexture
    /// `(origin x, origin y, points per texel, 1)` — the uniform that maps the body's own points into
    /// the snapshot. `xy` is the image's top-left corner *in the body's points*, so it is negative when
    /// the snapshot reaches past the body's box, as it usually does.
    var frame: SIMD4<Float>
}

/// The host view a snapshot is taken of: the same thing on both platforms, named once so the capture
/// below is written once.
#if canImport(UIKit)
typealias GlassHostView = UIView
#else
typealias GlassHostView = NSView
#endif

/// The one place that takes a snapshot of the host's page, and the one place that decides there is
/// none to take.
enum GlassBackdrop {

    /// How far past the body's box a snapshot reaches, as a fraction of the box's larger side.
    ///
    /// A shoulder sends rays up to a body-width away; a snapshot that stopped at the box would clamp
    /// every one of them to its own edge — a bright ring, and a lie about what is behind the glass. A
    /// hair under one body-width of margin is enough for the fold `foldIntoPlate` applies.
    static let margin: CGFloat = 0.85

    /// The most often a page may be re-taken, in seconds.
    ///
    /// The page moves under a body that has not: a list scrolls, a sheet appears, a row changes height.
    /// Watching for that is not possible from inside a view, so a stale page is re-read on this
    /// interval instead — twice a second, against a body redrawn ten times a second, which is the
    /// difference between a snapshot cost nobody can measure and one paid every frame.
    static let refreshInterval: CFTimeInterval = 0.5

    /// A snapshot of the region behind `view`, or nil when this host cannot give one.
    ///
    /// `points` is the body's own point space (what the shader's `position` uses), so the returned
    /// frame maps it into the image without a second conversion at the call site.
    ///
    /// The body's own layer is hidden for the length of one synchronous draw, so the snapshot cannot
    /// contain the glass it is going to be refracted through — a feedback loop that would paint the
    /// body inside the body. `isHidden` on the layer is restored before this function returns and
    /// nothing presents a frame in between, so the flicker a person might expect does not happen. What
    /// *does* land in the snapshot is the avatar's own sibling drawings — the ribbons the `Canvas`
    /// route passes behind and over the body. The ones behind it belong there; the ones over it are a
    /// small artifact, and unavoidable without a host that can name its own layers.
    static func capture(of view: MTKView, points: CGSize, device: MTLDevice) -> GlassBackdropPage? {
        #if canImport(UIKit)
        guard let container = view.superview ?? view.window else { return nil }
        #else
        guard let window = view.window, let container = window.contentView else { return nil }
        #endif
        guard points.width >= 1, points.height >= 1, view.bounds.width >= 1, view.bounds.height >= 1
        else { return nil }

        // The body's box in the container's coordinates, grown by the margin and clipped to what the
        // container actually covers. A crop that has collapsed is a host mid-layout: no page yet.
        let box = view.convert(view.bounds, to: container)
        let grown = box.insetBy(dx: -box.width * margin, dy: -box.height * margin)
        let crop = grown.intersection(container.bounds)
        guard crop.width >= 1, crop.height >= 1, crop.width.isFinite, crop.height.isFinite else {
            return nil
        }

        let wasHidden = view.layer?.isHidden ?? false
        view.layer?.isHidden = true
        defer { view.layer?.isHidden = wasHidden }

        guard let image = snapshot(of: container, crop: crop) else { return nil }
        guard let texture = texture(from: image, device: device) else { return nil }

        // The crop's top-left in the body's own points, and the points one texel covers. `box.minX` is
        // where the body's box starts in the container, so `crop.minX - box.minX` is the image's origin
        // in the body's space — negative when the margin reached outside it, as it does on most sides.
        let originX = Float(crop.minX - box.minX)
        let originY = Float(crop.minY - box.minY)
        let perTexel = Float(image.width) > 0 ? Float(crop.width) / Float(image.width) : 1
        return GlassBackdropPage(texture: texture,
                                 frame: SIMD4<Float>(originX, originY, max(perTexel, 0.01), 1))
    }

    /// One region of a host view, as an 8-bit RGBA image whose first row is its top.
    ///
    /// Two platform paths, both the documented way to render a view hierarchy into a bitmap: AppKit's
    /// `cacheDisplay(in:to:)` and, on iOS, the container's own layer. The layer path is what a
    /// `CAMetalLayer` sibling cannot contribute to — its contents are a drawable, not pixels it can
    /// draw — which is exactly what keeps a neighbouring avatar out of this one's snapshot.
    private static func snapshot(of container: GlassHostView, crop: CGRect) -> CGImage? {
        #if canImport(UIKit)
        let width = Int((crop.width * container.contentScaleFactor).rounded())
        let height = Int((crop.height * container.contentScaleFactor).rounded())
        guard width >= 1, height >= 1,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let scale = CGFloat(width) / max(crop.width, 1)
        context.scaleBy(x: scale, y: scale)
        // The layer's own origin is the container's top-left; `render(in:)` draws the subtree rooted
        // at that layer, clipped by the context's translation below.
        context.translateBy(x: -crop.minX, y: -crop.minY)
        container.layer.render(in: context)
        return context.makeImage()
        #else
        guard let rep = container.bitmapImageRepForCachingDisplay(in: crop) else { return nil }
        container.cacheDisplay(in: crop, to: rep)
        return rep.cgImage
        #endif
    }

    /// The image as the fragment's texture — sRGB bytes, with its mip chain, read-only.
    private static func texture(from image: CGImage, device: MTLDevice) -> MTLTexture? {
        let width = image.width, height = image.height
        guard width >= 1, height >= 1,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // `CGImage`'s own origin is bottom-left; the shader's `position.y` runs down from the top, so
        // the copy flips it here, once, rather than in every fragment.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        return texture(rgba: data, width: width, height: height, device: device)
    }

    /// RGBA bytes (sRGB, first row the top) as a texture with a full mip chain.
    ///
    /// The chain is the image's own filtering, and it is not a nicety: the bevel compresses the page by
    /// more than ten to one, so one pixel out there covers several texels. Without a chain the sampler
    /// point-samples that neighbourhood and the bend tears into stripes; with one, the compressed band
    /// blurs exactly as a camera's would and the fold reads as a caustic rather than as a glitch.
    ///
    /// Shared with `Tools/glass-proof`, which hands over a synthetic page through this same function —
    /// so a picture of the page path is a picture of *this* texture.
    static func texture(rgba: UnsafeRawPointer, width: Int, height: Int,
                        device: MTLDevice) -> MTLTexture? {
        guard width >= 1, height >= 1 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: width, height: height,
                                                                  mipmapped: true)
        descriptor.usage = .shaderRead
        descriptor.mipmapLevelCount = Int(log2(Double(max(width, height))).rounded(.down)) + 1
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: rgba, bytesPerRow: width * 4)
        if let queue = HermeyGlassEngine.shared.queue,
           let commandBuffer = queue.makeCommandBuffer(),
           let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            commandBuffer.commit()
        }
        return texture
    }
}
#endif
