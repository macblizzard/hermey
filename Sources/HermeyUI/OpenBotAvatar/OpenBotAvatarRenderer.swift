import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// One drawing of one avatar frame, into a `GraphicsContext`.
///
/// ## What it draws
///
/// The body is painted as the stack of cross-sections the volume inferred, back to front, each plane
/// projected through the view rotation: that is what gives the silhouette depth without a 3-D model.
/// The eyes are painted on the tangent plane under their own position, so they turn and tip with the
/// face instead of floating above it. Around the body, and only behind it, sits the state's ribbons.
///
/// ## One body, one pair of eyes, no marks
///
/// Every state is drawn at the one resting size with the one pair of eyes: the eyes are drawn once
/// per frame, after the body, unconditionally. There is no mark and no give-way gate any more —
/// upstream's `blocked` handed the body and the face over to an exclamation mark, which at 24 pt
/// read as a smaller, eyeless bot in exactly the state that most needed the bot to still look like
/// itself. A state now says what it is doing with its motion (`OpenBotAvatarState`), and the only
/// things that may change how an eye looks are the mood's arc and the shared frame's blink and
/// squint. Nothing is drawn over the face: the ribbons are drawn behind the body, the catchlight is
/// inside the eye it belongs to, and there is nothing else.
///
/// ## Materials
///
/// A face is made of a material, and the material is data (`BotAvatarMaterialSpec.all`): a fill
/// treatment, then whatever highlights its row names. A `.flat` fill is the slice stack above and
/// nothing else — the 0.1.648 solid; a `.ramp` fill is one silhouette painted from the spec
/// (`OpenBotAvatarMaterialPaint`), which is glass. The renderer never asks which material it is
/// drawing, only what the spec holds, so a third material is a row in the table.
///
/// ## Cost
///
/// Every path this draws is built once, when the definition is first seen (`OpenBotAvatarModel`), and
/// held in the definition's own coordinates: per frame the renderer only mutates the graphics
/// context's transform and fills those paths. The two exceptions are the eyes, whose *shape* depends
/// on the blink and the state — two small paths per frame, which is the whole animation budget.
/// Nothing here reads a clock, allocates a bitmap or starts a timer; the view feeds it a time.
public enum OpenBotAvatarRenderer {

    /// The default body colour: the app's own forge orange, the same ink the reference uses.
    public static let defaultColor = Color(red: 1.0, green: 0.416, blue: 0.102)
    /// The default eye ink.
    public static let defaultInk = Color(red: 0.082, green: 0.082, blue: 0.082)

    /// Paint one frame.
    ///
    /// `material` and `backdrop` are the face's material and where it is drawn. The material is
    /// looked up in `BotAvatarMaterialSpec.all` and the drawing follows the spec; a spec whose fill
    /// is `.flat` takes the slice-stack path below, untouched since 0.1.648, which is what keeps
    /// Solid exactly the face a bot already had.
    public static func draw(_ model: OpenBotAvatarModel,
                            pose: OpenBotAvatarPose,
                            material: BotAvatarMaterial = .solid,
                            backdrop: OpenBotAvatarBackdrop = .themed(dark: true),
                            into context: inout GraphicsContext,
                            size: CGSize,
                            color: Color,
                            ink: Color) {
        let volume = model.volume
        let side = min(size.width, size.height)
        guard side > 0 else { return }
        let unit = side / 100
        let viewport = CGAffineTransform(translationX: (size.width - side) / 2, y: (size.height - side) / 2)
            .scaledBy(x: unit, y: unit)

        let spec = BotAvatarMaterialSpec.spec(for: material)
        // What this size draws of the material. Derived from the side and the backdrop, never from
        // the call site: a surface gets the right layers because it says how big it is.
        let plan = MaterialPlan.plan(for: spec, side: Double(side), backdrop: backdrop)

        let basis = ViewBasis(yaw: pose.yaw, pitch: pose.pitch)
        let pivot = volume.pivot
        let base = CGPoint(x: volume.box.center.x, y: volume.box.maxY)
        let root = rootTransform(pose: pose, base: base)

        // Ribbons sit behind the body: a halo that sweeps round it. Drawing them behind (rather than
        // split in front and behind) keeps them off the face at every angle, which is the one place
        // they would read as scribble at 24 pt.
        if pose.ribbons > 0.01 {
            drawRibbons(model: model, pose: pose, into: &context, viewport: viewport, root: root,
                        color: color, pivot: pivot)
        }

        switch spec.fill {
        case .flat:
            // The 0.1.648 body: the inferred volume's cross-sections, back to front, each filled
            // flat. Nothing below this line changed when materials arrived.
            var bodyContext = context
            for slice in drawnSlices(volume: volume, basis: basis) {
                let plane = planeTransform(basis: basis, z: slice.z, pivot: pivot)
                bodyContext.transform = plane
                    .concatenating(root)
                    .concatenating(viewport)
                bodyContext.fill(slice.path,
                                 with: .color(color),
                                 style: FillStyle(eoFill: slice.evenOdd, antialiased: true))
            }
        case .ramp:
            // One silhouette, painted from the material's spec. The front plane (z = 0) is the
            // outline the slice stack draws its core from, so the shape is the same one Solid
            // shows; the layers over it are what make it glass.
            let face = planeTransform(basis: basis, z: 0, pivot: pivot)
                .concatenating(root)
                .concatenating(viewport)
            let box = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2,
                             width: side, height: side)
            OpenBotAvatarMaterialPaint.paint(spec,
                                             light: pose.light,
                                             backdrop: backdrop,
                                             silhouette: model.silhouette.applying(face),
                                             tint: color,
                                             side: side,
                                             box: box,
                                             plan: plan,
                                             into: &context)
        }
        // The eyes ride the surface, so they are drawn over the body: one pair, once per frame, for
        // every state — there is no gate here that a state could reach to take its face away.
        drawEyes(model: model, pose: pose, basis: basis, into: &context, viewport: viewport,
                 root: root, ink: ink, pivot: pivot, catchlight: plan.catchlight)
    }

    // MARK: - View maths

    struct ViewBasis {
        let cosYaw: Double
        let sinYaw: Double
        let cosPitch: Double
        let sinPitch: Double
        /// cos(yaw)·cos(pitch): > 0 when the front faces the viewer.
        var facing: Double { cosYaw * cosPitch }

        init(yaw: Double, pitch: Double) {
            cosYaw = cos(yaw); sinYaw = sin(yaw)
            cosPitch = cos(pitch); sinPitch = sin(pitch)
        }
    }

    /// Orthographic projection of the plane at depth `z`, pivoting on `pivot` at z = 0 — the same
    /// matrix upstream's `planeMatrix` builds, expressed as a `CGAffineTransform` (a b c d tx ty).
    static func planeTransform(basis: ViewBasis, z: Double, pivot: OpenBotAvatarGeometry.Point) -> CGAffineTransform {
        CGAffineTransform(
            a: CGFloat(basis.cosYaw),
            b: CGFloat(basis.sinYaw * basis.sinPitch),
            c: 0,
            d: CGFloat(basis.cosPitch),
            tx: CGFloat(pivot.x - basis.cosYaw * pivot.x + basis.sinYaw * z),
            ty: CGFloat(pivot.y - basis.cosPitch * pivot.y - basis.sinYaw * basis.sinPitch * pivot.x - basis.cosYaw * basis.sinPitch * z)
        )
    }

    /// Hop, roll and squash about the base of the body.
    ///
    /// `concatenating` applies the receiver first, so the chain reads bottom-up: move the base to the
    /// origin, scale, spin, put it back, then hop.
    static func rootTransform(pose: OpenBotAvatarPose, base: CGPoint) -> CGAffineTransform {
        let spin = CGAffineTransform(rotationAngle: CGFloat(pose.roll * .pi / 180))
        let scale = CGAffineTransform(scaleX: CGFloat(pose.sx), y: CGFloat(pose.sy))
        return CGAffineTransform(translationX: -base.x, y: -base.y)
            .concatenating(scale)
            .concatenating(spin)
            .concatenating(CGAffineTransform(translationX: base.x, y: base.y))
            .concatenating(CGAffineTransform(translationX: 0, y: CGFloat(pose.lift)))
    }

    /// The slices this view can show, back to front.
    ///
    /// A contour slice behind the core at rest adds nothing to the silhouette, and at small yaw it
    /// adds nothing at all: it is skipped by the same rule upstream uses.
    static func drawnSlices(volume: OpenBotAvatarVolume, basis: ViewBasis) -> [OpenBotAvatarVolume.Slice] {
        let sweep = (basis.sinYaw * basis.sinYaw + pow(basis.cosYaw * basis.sinPitch, 2)).squareRoot()
        let insetScale = min(abs(basis.cosYaw), abs(basis.cosPitch))
        var slices: [OpenBotAvatarVolume.Slice] = []
        for part in volume.parts {
            for slice in part.slices {
                if slice.inset > 0, abs(slice.z) * sweep > slice.inset * insetScale { continue }
                slices.append(slice)
            }
        }
        // Parallel planes keep their order along every view ray; the sign of the depth is all that
        // decides who paints first.
        return slices.sorted { $0.z < $1.z }
    }

    // MARK: - Eyes

    /// One pair of eyes, on the tangent plane under each eye's own position.
    ///
    /// One chain, one shape per eye: the mood's arc or the ordinary pill. There is no third shape
    /// and no give-way transform — the body is always the resting body, so an eye can never be
    /// drawn at a size that does not belong to it.
    static func drawEyes(model: OpenBotAvatarModel,
                         pose: OpenBotAvatarPose,
                         basis: ViewBasis,
                         into context: inout GraphicsContext,
                         viewport: CGAffineTransform,
                         root: CGAffineTransform,
                         ink: Color,
                         pivot: OpenBotAvatarGeometry.Point,
                         catchlight: Bool = false) {
        guard basis.facing > 0.05 else { return }
        let eyes = model.definition.eyes
        let scale = model.volume.eyeScale
        let width = OpenBotAvatarGeometry.eyeWidth * scale
        let height = OpenBotAvatarGeometry.eyeHeight * scale
        let open = max(height * max(0.09, (1 - pose.blink) * (1 - pose.squint * 0.4)), width * 0.55)
        let shift = (height - open) * 0.18
        let centers = OpenBotAvatarGeometry.eyeCenters(eyes)
        let gazeX = max(-1, min(1, pose.gazeX)) * OpenBotAvatarGeometry.gazeX * scale
        let gazeY = max(-1, min(1, pose.gazeY)) * OpenBotAvatarGeometry.gazeY * scale

        for (index, center) in centers.enumerated() {
            let plane = model.volume.eyePlanes.indices.contains(index) ? model.volume.eyePlanes[index] : .init(z: 0, dzdx: 0, dzdy: 0)
            let z = plane.z + gazeX * plane.dzdx + gazeY * plane.dzdy
            let eyePoint = OpenBotAvatarGeometry.Point(center.x + gazeX, center.y + gazeY)
            let hip = OpenBotAvatarGeometry.Point(center.x, center.y + shift)

            var layer = context
            var transform = planeTransform(basis: basis, z: z, pivot: pivot)
            // The tangent plane: slope in x and y so an eye on a curved face tips with it.
            transform.a += CGFloat(basis.sinYaw * plane.dzdx)
            transform.b -= CGFloat(basis.cosYaw * basis.sinPitch * plane.dzdx)
            transform.c += CGFloat(basis.sinYaw * plane.dzdy)
            transform.d -= CGFloat(basis.cosYaw * basis.sinPitch * plane.dzdy)
            // The eye's own plane, then the body's motion, then the view — the same chain the body
            // takes, so an eye is always drawn on the body it belongs to.
            layer.transform = transform
                .concatenating(root)
                .concatenating(viewport)

            if pose.arch >= 0.5 {
                // The happy arc: a quadratic stroked with round caps, as upstream draws it.
                let halfWidth = width * 0.72
                let baseY = eyePoint.y + height * 0.10
                var arc = Path()
                arc.move(to: CGPoint(x: eyePoint.x - halfWidth, y: baseY))
                arc.addQuadCurve(to: CGPoint(x: eyePoint.x + halfWidth, y: baseY),
                                 control: CGPoint(x: eyePoint.x, y: eyePoint.y - height * 0.42))
                layer.stroke(arc, with: .color(ink),
                             style: StrokeStyle(lineWidth: CGFloat(width * 0.6), lineCap: .round))
            } else {
                let rect = CGRect(x: hip.x - width / 2, y: hip.y - open / 2, width: width, height: open)
                let pill = Path(roundedRect: rect, cornerRadius: min(width, open) / 2)
                layer.fill(pill, with: .color(ink))
            }

            // The one reflection the spec allows on the eye, and only above 64 pt: a 1 pt dot at
            // 30 % white, in the pupil's upper left. Below that size it is mud, so it is not drawn.
            if catchlight {
                // A point in the eye's own units: the layer's scale is how many points one unit is,
                // so a 1 pt dot is `0.5 / pointsPerUnit` units in radius.
                let pointsPerUnit = max(0.0001, (abs(layer.transform.a) * abs(layer.transform.d)).squareRoot())
                let radius = 0.5 / pointsPerUnit
                let centre = CGPoint(x: eyePoint.x - width * 0.22, y: eyePoint.y - height * 0.22)
                let dot = CGRect(x: centre.x - radius, y: centre.y - radius,
                                 width: radius * 2, height: radius * 2)
                layer.fill(Path(ellipseIn: dot), with: .color(Color.white.opacity(0.30)))
            }
        }
    }

    // MARK: - Ribbons

    static func drawRibbons(model: OpenBotAvatarModel,
                            pose: OpenBotAvatarPose,
                            into context: inout GraphicsContext,
                            viewport: CGAffineTransform,
                            root: CGAffineTransform,
                            color: Color,
                            pivot: OpenBotAvatarGeometry.Point) {
        let radiusX = model.volume.box.width / 2 + 6
        let radiusY = model.volume.box.height / 2 + 5
        let presence = max(0, min(1, pose.ribbons))
        for index in 0..<3 {
            var layer = context
            let turn = pose.sweep + Double(index) * 2 * .pi / 3
            // Unit circle → the body's ellipse → turned about the pivot → the body's own motion.
            let transform = CGAffineTransform(scaleX: CGFloat(radiusX), y: CGFloat(radiusY))
                .concatenating(CGAffineTransform(rotationAngle: CGFloat(turn)))
                .concatenating(CGAffineTransform(translationX: CGFloat(pivot.x), y: CGFloat(pivot.y)))
                .concatenating(root)
                .concatenating(viewport)
            layer.transform = transform
            // A third of the hoop, drawn at unit radius and stretched by the transform above.
            layer.stroke(model.ribbonArc,
                         with: .color(color.opacity(0.55 + 0.25 * presence)),
                         style: StrokeStyle(lineWidth: 3.2 / max(radiusX, radiusY),
                                            lineCap: .round))
        }
    }
}

/// Everything one definition needs to be drawn, built once.
///
/// The cache is keyed by the definition's own contents (id, name, path and eyes) so two surfaces
/// showing the same bot share one volume, and a definition edited in the settings tab builds a new
/// one and leaves the old behind. It is bounded because a paste box can be typed into repeatedly.
public final class OpenBotAvatarModel {
    public let definition: BotAvatarDefinition
    public let volume: OpenBotAvatarVolume

    /// The whole outline, as one path, in the definition's own coordinates: every part's core
    /// contour. The slice stack paints the volume; this is what a material paints over — the same
    /// silhouette, flat, so glass and solid wear the same shape.
    public let silhouette: Path

    /// Unit shapes, drawn through a transform: the ribbon hoop. Held here so no frame builds a path
    /// for it.
    let ribbonArc: Path

    private static let lock = NSLock()
    private static var cache: [String: OpenBotAvatarModel] = [:]
    private static let cacheLimit = 64

    private init(definition: BotAvatarDefinition, volume: OpenBotAvatarVolume) {
        self.definition = definition
        self.volume = volume
        var silhouette = Path()
        for part in volume.parts { silhouette.addPath(part.core.path) }
        self.silhouette = silhouette
        var arc = Path()
        arc.addArc(center: .zero, radius: 1, startAngle: .degrees(-52), endAngle: .degrees(52), clockwise: false)
        ribbonArc = arc
    }

    /// The model for a definition, or nil when the contract refuses it (a caller that already
    /// validated never sees nil).
    public static func model(for definition: BotAvatarDefinition) -> OpenBotAvatarModel? {
        let key = "\(definition.id)|\(definition.name)|\(definition.body.path)|\(definition.eyes.x),\(definition.eyes.y),\(definition.eyes.spacing),\(definition.eyes.scale)"
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        guard let validated = try? definition.validated(),
              let polygons = try? validated.polygons(),
              !polygons.isEmpty else { return nil }
        let built = OpenBotAvatarModel(definition: validated,
                                       volume: OpenBotAvatarVolume(definition: validated, polygons: polygons))
        lock.lock()
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = built
        lock.unlock()
        return built
    }
}

/// `#RGB` / `#RRGGBB` as a colour, or nil.
public enum OpenBotAvatarColor {
    public static func color(hex: String) -> Color? {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }
        let digits = String(trimmed.dropFirst())
        guard digits.count == 3 || digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
        let expanded = digits.count == 3 ? digits.map { "\($0)\($0)" }.joined() : digits
        guard let value = UInt32(expanded, radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    /// A colour's `#RRGGBB`, for storing what a picker chose.
    public static func hex(of color: Color) -> String {
        #if canImport(UIKit)
        let resolved = UIColor(color)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #else
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.black
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #endif
        func byte(_ value: CGFloat) -> Int { Int((max(0, min(1, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}
