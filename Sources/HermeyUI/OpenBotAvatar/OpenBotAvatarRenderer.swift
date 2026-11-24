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
/// face instead of floating above it. Around and in front of that sit the state's marks — a band of
/// ribbons for `working` and `done`, three dots for `thinking`, an exclamation for `blocked`.
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
    public static func draw(_ model: OpenBotAvatarModel,
                            pose: OpenBotAvatarPose,
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

        let bodyScale = max(0, min(1, pose.bodyScale))
        if bodyScale > 0.01 {
            var bodyContext = context
            let shrink = CGAffineTransform(translationX: pivot.x, y: pivot.y)
                .scaledBy(x: bodyScale, y: bodyScale)
                .translatedBy(x: -pivot.x, y: -pivot.y)
            for slice in drawnSlices(volume: volume, basis: basis) {
                let plane = planeTransform(basis: basis, z: slice.z, pivot: pivot)
                bodyContext.transform = plane
                    .concatenating(shrink)
                    .concatenating(root)
                    .concatenating(viewport)
                bodyContext.fill(slice.path,
                                 with: .color(color),
                                 style: FillStyle(eoFill: slice.evenOdd, antialiased: true))
            }
            // The eyes ride the surface, so they are drawn over the body but under the marks.
            drawEyes(model: model, pose: pose, basis: basis, into: &context, viewport: viewport,
                     root: root, ink: ink, pivot: pivot, bodyScale: bodyScale)
        }

        if let mark = pose.mark {
            drawMark(mark, model: model, pose: pose, into: &context, viewport: viewport, ink: ink)
        }
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

    static func drawEyes(model: OpenBotAvatarModel,
                         pose: OpenBotAvatarPose,
                         basis: ViewBasis,
                         into context: inout GraphicsContext,
                         viewport: CGAffineTransform,
                         root: CGAffineTransform,
                         ink: Color,
                         pivot: OpenBotAvatarGeometry.Point,
                         bodyScale: Double) {
        guard basis.facing > 0.05 else { return }
        let eyes = model.definition.eyes
        let scale = model.volume.eyeScale
        let drawnScale = scale * bodyScale
        let width = OpenBotAvatarGeometry.eyeWidth * drawnScale
        let height = OpenBotAvatarGeometry.eyeHeight * drawnScale
        let open = max(height * max(0.09, (1 - pose.blink) * (1 - pose.squint * 0.4)), width * 0.55)
        let shift = (height - open) * 0.18
        let centers = OpenBotAvatarGeometry.eyeCenters(eyes)
        let gazeX = max(-1, min(1, pose.gazeX)) * OpenBotAvatarGeometry.gazeX * drawnScale
        let gazeY = max(-1, min(1, pose.gazeY)) * OpenBotAvatarGeometry.gazeY * drawnScale

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
            layer.transform = transform.concatenating(root).concatenating(viewport)

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
            } else if pose.slit >= 0.5 {
                // The waiting slit: a thin capsule lying almost flat, both eyes tipped one way.
                let length = width * 1.9
                let thickness = max(width * 0.5, open * 0.35)
                let rect = CGRect(x: -length / 2, y: -thickness / 2, width: length, height: thickness)
                let capsule = Path(roundedRect: rect, cornerRadius: thickness / 2)
                var tilted = layer
                let tip = CGAffineTransform(rotationAngle: 0.2)
                    .concatenating(CGAffineTransform(translationX: CGFloat(eyePoint.x), y: CGFloat(eyePoint.y)))
                tilted.transform = tilted.transform.concatenating(tip)
                tilted.fill(capsule, with: .color(ink))
            } else {
                let rect = CGRect(x: hip.x - width / 2, y: hip.y - open / 2, width: width, height: open)
                let pill = Path(roundedRect: rect, cornerRadius: min(width, open) / 2)
                layer.fill(pill, with: .color(ink))
            }
        }
    }

    // MARK: - Ribbons and marks

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

    static func drawMark(_ mark: OpenBotAvatarMark,
                         model: OpenBotAvatarModel,
                         pose: OpenBotAvatarPose,
                         into context: inout GraphicsContext,
                         viewport: CGAffineTransform,
                         ink: Color) {
        let pivot = model.volume.pivot
        var layer = context
        let scale = max(0.1, pose.markScale)
        layer.transform = CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale))
            .concatenating(CGAffineTransform(translationX: CGFloat(pivot.x), y: CGFloat(pivot.y - 4)))
            .concatenating(viewport)
        switch mark {
        case .dots:
            layer.fill(model.dots, with: .color(ink))
        case .bang:
            layer.fill(model.bang, with: .color(ink))
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

    /// Unit shapes, drawn through a transform: a ribbon hoop, the three dots, the exclamation mark.
    /// Held here so no frame builds a path for them.
    let ribbonArc: Path
    let dots: Path
    let bang: Path

    private static let lock = NSLock()
    private static var cache: [String: OpenBotAvatarModel] = [:]
    private static let cacheLimit = 64

    private init(definition: BotAvatarDefinition, volume: OpenBotAvatarVolume) {
        self.definition = definition
        self.volume = volume
        var arc = Path()
        arc.addArc(center: .zero, radius: 1, startAngle: .degrees(-52), endAngle: .degrees(52), clockwise: false)
        ribbonArc = arc
        var dotsPath = Path()
        for (index, x) in [-7.0, 0, 7].enumerated() {
            let lift = index == 1 ? -1.6 : 0
            dotsPath.addEllipse(in: CGRect(x: x - 2.1, y: lift - 2.1, width: 4.2, height: 4.2))
        }
        dots = dotsPath
        var bangPath = Path()
        bangPath.addRoundedRect(in: CGRect(x: -1.9, y: -14, width: 3.8, height: 13), cornerSize: CGSize(width: 1.9, height: 1.9))
        bangPath.addEllipse(in: CGRect(x: -2.2, y: 1.4, width: 4.4, height: 4.4))
        bang = bangPath
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
