import Foundation
import SwiftUI
#if canImport(Metal)
import Metal
#endif

/// What draws one frame of a glass body — decided once, in one function, from the surface.
///
/// ## Why there is a decision at all
///
/// The painted glass (`OpenBotAvatarMaterialPaint`) is six `Canvas` layers: a glow, a ramp, a sheen,
/// a streak, a rim and a contact band. It is honest, and it is flat — every one of those layers is a
/// gradient over the silhouette, so nothing on the body is ever lit from a direction, nothing bends,
/// and nothing refracts. That is exactly what reads as cartoonish next to the reference, whose glass
/// is a raymarched surface: a Fresnel reflection of a studio, a refracted path through the body with
/// Beer-Lambert absorption, and a tone map.
///
/// So glass has a second drawing: `HermeyGlassSource.msl` — upstream's fragment pass, kept as source
/// and compiled by Metal at run time — over the silhouette the `Canvas` fills. This file is the only
/// place that chooses between them.
///
/// ## The rule
///
/// Shader **when all four hold**: the material is glass; the surface is an app surface (the process
/// has a Metal device *and* the MSL source compiled into a library in it); Reduce Transparency is
/// off; and the body is at least `BotAvatarGlassShader.minimumSide` points across.
///
/// Canvas otherwise — and "otherwise" is not an error path. It is the drawing the Live Activity
/// compiles (its bundle carries neither the shader's source nor a library, so `isAvailable` is false
/// there without a `#if` at the call site); the drawing a preview, a test process, an older Mac, a
/// Mac whose Metal compiler refuses the source, and Reduce Transparency get; and the drawing a list
/// row gets, because below 24 pt a Fresnel term and two softboxes land inside the same pixel as the
/// rim and the compact plan's three layers are the legible drawing.
///
/// There is no third route, and no call site chooses: a surface passes its material and its size and
/// gets what that surface should draw (`OpenBotAvatarView`), and the renderer follows the route it is
/// handed (`OpenBotAvatarRenderer.draw(_:pass:route:…)`). A surface with no view to ask — the avatar
/// editor's material row, which has to say what Glass really is — asks `drawn`, which is `decide`
/// under a name that says what it answers. `Tests/test_bot_avatar_glass.py` holds the single decision
/// point and the single fallback to exactly that shape.
public enum BotAvatarGlassRoute: Hashable, Sendable {

    /// The painted material: the six `Canvas` layers. The fallback, and the only drawing for Solid,
    /// Matte and Metal, for the Live Activity, for previews, for Reduce Transparency, for a process
    /// whose Metal compiler refused the source, and for a body under the shader's floor.
    case canvas

    /// One Metal pass over the body: the reference's lit, refracting surface.
    case metal

    /// **The one shader-versus-Canvas decision.** Everything above and below reads its answer.
    ///
    /// `side` is the drawn side of the body in points, `material` its stored material, and
    /// `reduceTransparency` the accessibility setting — a person who has asked for less transparency
    /// gets the calm painted surface and no refraction at all, whatever their Mac can do.
    public static func decide(material: BotAvatarMaterial,
                              side: Double,
                              reduceTransparency: Bool) -> BotAvatarGlassRoute {
        // Solid is a flat fill drawn by the volume's own slices, and matte and metal are paints, not
        // glass: the shader is glass's surface and nothing else may reach it.
        guard material == .glass else { return .canvas }
        // A calm surface, asked for: the painted glass, never a refracting one.
        guard !reduceTransparency else { return .canvas }
        // Below this the shader's speculars are sub-pixel and its refraction is one pixel of tint.
        guard side >= BotAvatarGlassShader.minimumSide else { return .canvas }
        // The process itself: a Metal device, the shader compiled in it, and not a preview.
        guard BotAvatarGlassShader.isAvailable else { return .canvas }
        return .metal
    }

    /// What a surface of this size draws in this process — `decide`, under a name that says what it
    /// answers, for a caller that has no view to ask.
    ///
    /// The avatar editor's material row is that caller: it has to tell a person whether the Glass
    /// they are about to save will be a lit surface here or the painted one, and it must not answer
    /// that with its own copy of the four guards. There is still one decision — this calls it.
    public static func drawn(material: BotAvatarMaterial,
                             side: Double,
                             reduceTransparency: Bool) -> BotAvatarGlassRoute {
        decide(material: material, side: side, reduceTransparency: reduceTransparency)
    }
}

/// Whether this process can run the glass shader, and the one size below which it should not.
///
/// Every probe here is read **once** and held: `MTLCreateSystemDefaultDevice()` walks the system's
/// GPU list, and asking it per frame would be a cost paid by every avatar in a list for an answer
/// that cannot change while the process lives. The library is compiled on first access for the same
/// reason — once per process, never per frame (`HermeyGlassEngine`).
enum BotAvatarGlassShader {

    /// The smallest body the shader draws, in points.
    ///
    /// 24 pt is the floor at which an app surface draws a face at all (`OpenBotAvatarView`'s own
    /// `animatingFrom`), so this is "every size the app uses, and nothing smaller". Below it the
    /// painted plan is already three layers, the rim is one point wide, and a Fresnel term plus two
    /// softboxes would land inside that same point: the shader would be softer, not sharper.
    static let minimumSide: Double = 24

    /// A Metal device, the shader compiled in this process, and not a preview.
    static let isAvailable: Bool = hasDevice && hasRuntimeShader && !isPreview

    /// Xcode's preview host compiles the app but draws outside a real render loop, and a preview is
    /// the one place a person is looking at the *drawing* rather than at the app: it takes the
    /// painted material, which is the reference the shader is checked against.
    static let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"

    /// The shader is a string now (`HermeyGlassSource.msl`), compiled by `device.makeLibrary(source:)`
    /// the first time anything asks — no `.metal` file, no `default.metallib`, and so no Xcode Metal
    /// toolchain on the machine that builds the app. This is that compile's answer, held for the life
    /// of the process: a failure here is the painted material, for good, rather than a retry per frame.
    ///
    /// The Live Activity compiles neither the source nor the engine (`project.yml` sets
    /// `HERMEY_LIVE_ACTIVITY` for that target alone), so there is nothing to compile there and the
    /// answer is false without the extension ever touching Metal.
    private static let hasRuntimeShader: Bool = {
        #if !HERMEY_LIVE_ACTIVITY
        return HermeyGlassEngine.shared.isReady
        #else
        return false
        #endif
    }()

    private static let hasDevice: Bool = {
        #if canImport(Metal)
        return MTLCreateSystemDefaultDevice() != nil
        #else
        return false
        #endif
    }()
}

/// One frame's numbers for the glass shader: everything the fragment function is fed, in the order
/// the MSL declares it.
///
/// Six `float4`s and nothing else: no texture, no buffer, no bitmap is built here. The frame's values
/// are already in hand (the body's box, the volume's profile, the pose), so the animating path
/// allocates nothing and uploads no image of the avatar; the one texture the pass reads is the
/// body's flat fill, which the Metal drawer builds from the same silhouette path.
struct BotAvatarGlassUniforms {
    /// `rgb` — the body's colour after the state's own desaturation (`blocked` calms the tint).
    var tint: SIMD4<Float>
    /// `(half width, half height, corner radius, half depth)` in points.
    var shape: SIMD4<Float>
    /// `(inset radius rxy, rise rz, centre x, centre y)` in points.
    var profile: SIMD4<Float>
    /// `(yaw, pitch, rim opacity, detail)`.
    var pose: SIMD4<Float>
    /// `(hairline, exposure, rim gain, absorption)`.
    var tone: SIMD4<Float>
    /// `(points x, points y, pixels x, pixels y)` — filled in at draw time, where the drawable's own
    /// size is the authority on the second pair.
    var size: SIMD4<Float> = .zero
}

/// One frame's numbers for the glass shader: the values themselves, and the uniforms built from them.
struct BotAvatarGlassSurface: Sendable {

    /// The layer's size in points — the shader's `position` space.
    var size: CGSize
    /// The body's colour, after the state's own desaturation (`blocked` calms the tint).
    var tint: MaterialColor
    /// `(half width, half height, corner radius, half depth)` in points.
    var shape: SIMD4<Float>
    /// `(inset radius rxy, rise rz, centre x, centre y)` in points.
    var profile: SIMD4<Float>
    /// `(yaw, pitch, rim opacity, detail)`.
    var pose: SIMD4<Float>
    /// `(hairline, exposure, rim gain, absorption)`.
    var tone: SIMD4<Float>

    /// The fragment function's bindings, ready for `setFragmentBytes`.
    ///
    /// `size` is left zero here and set from the drawable in `BotAvatarGlassDrawer.draw`: the pixel
    /// size is the drawable's, and it is only known once there is one.
    var uniforms: BotAvatarGlassUniforms {
        BotAvatarGlassUniforms(tint: SIMD4(Float(tint.red), Float(tint.green), Float(tint.blue), 1),
                               shape: shape, profile: profile, pose: pose, tone: tone)
    }

    /// The numbers for one frame, from the values the painter already computed.
    ///
    /// `face` is the transform the body's silhouette is drawn with (the plane's, the body's motion,
    /// the viewport) — the same matrix the `Canvas` fills the outline through, so the shader's box is
    /// the box that was drawn, whichever way the pose has turned it. It is also the transform the
    /// body's texture is filled through, so the silhouette the fragment masks itself with is the one
    /// the `Canvas` route draws.
    static func make(model: OpenBotAvatarModel,
                     pose: OpenBotAvatarPose,
                     size: CGSize,
                     face: CGAffineTransform,
                     color: Color,
                     backdrop: OpenBotAvatarBackdrop,
                     material: BotAvatarMaterial = .glass) -> BotAvatarGlassSurface {
        let spec = BotAvatarMaterialSpec.spec(for: material)
        let tint = OpenBotAvatarMaterialPaint.bodyColor(spec, light: pose.light, tint: color)

        // The drawn silhouette's box: the volume's box, through the frame's one affine. Four corners
        // and a min/max — no path is measured and no array is built, so nothing is allocated to ask.
        let box = model.volume.box
        let cornerA = CGPoint(x: box.minX, y: box.minY).applying(face)
        let cornerB = CGPoint(x: box.maxX, y: box.minY).applying(face)
        let cornerC = CGPoint(x: box.minX, y: box.maxY).applying(face)
        let cornerD = CGPoint(x: box.maxX, y: box.maxY).applying(face)
        let minX = Swift.min(Swift.min(cornerA.x, cornerB.x), Swift.min(cornerC.x, cornerD.x))
        let maxX = Swift.max(Swift.max(cornerA.x, cornerB.x), Swift.max(cornerC.x, cornerD.x))
        let minY = Swift.min(Swift.min(cornerA.y, cornerB.y), Swift.min(cornerC.y, cornerD.y))
        let maxY = Swift.max(Swift.max(cornerA.y, cornerB.y), Swift.max(cornerC.y, cornerD.y))

        // Points per definition unit: the viewport's `side / 100` times the body's own scale, read
        // off the transform's determinant so a squash and a turn both count.
        let pointsPerUnit = max(0.0001, (abs(face.a * face.d - face.b * face.c)).squareRoot())
        let profile = model.glassProfile
        // The shader's corner is the body's own inset radius; where it is wider than the box (a thin
        // fin), the box is the smaller form and wins.
        let corner = min(profile.rxy * pointsPerUnit, min((maxX - minX) / 2, (maxY - minY) / 2))

        let side = Double(min(size.width, size.height))
        let detail: Float = side >= MaterialDetail.fullStackFrom ? 1 : 0
        // The painted path's light-page rule, at the same place: a themed light page swaps the rim and
        // adds a dark hairline; the pet, which cannot know its page, always takes the two-tone rim.
        let twoTone = backdrop.forcesTwoToneRim || !backdrop.isLight
        let hairline = !twoTone ? (spec.rim?.outerHairline?.opacity ?? 0) : 0

        return BotAvatarGlassSurface(
            size: size,
            tint: tint,
            shape: SIMD4(Float((maxX - minX) / 2), Float((maxY - minY) / 2),
                         Float(max(0, corner)), Float(max(0, profile.halfDepth * pointsPerUnit))),
            profile: SIMD4(Float(max(0, profile.rxy * pointsPerUnit)),
                           Float(max(0, profile.rz * pointsPerUnit)),
                           Float((minX + maxX) / 2), Float((minY + maxY) / 2)),
            pose: SIMD4(Float(pose.yaw), Float(pose.pitch), Float(pose.light.rim), detail),
            tone: SIMD4(Float(hairline), 1, 1.25, 1))
    }
}
