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
/// face instead of floating above it. Around the body sit the state's ribbons: the pieces that pass
/// behind it, and the pieces that pass in front of it along the top.
///
/// ## One body, one pair of eyes, no marks in the eight
///
/// Every built-in state is drawn at the one resting size with the one pair of eyes: the eyes are
/// drawn once per frame, after the body, unconditionally. Upstream's `blocked` handed the body and the
/// face over to an exclamation mark, which at 24 pt read as a smaller, eyeless bot in exactly the
/// state that most needed the bot to still look like itself; `thinking` did the same with three dots.
/// So no built-in state carries a mark, and nothing here shrinks the body for one: that is a
/// deliberate difference from upstream, and `Tests/test_open_bot_avatar.py` refuses it coming back.
///
/// The machinery still exists, because a host may define a state of its own (`AvatarStateDefinition`)
/// and ask it to give way to a mark. Then the pose carries `marks`, the body shrinks as they grow
/// (upstream's `bodyScale`), and the material draws them — one entry point, `BotAvatarMaterialRender`,
/// for the body and every part of every mark, so a solid bot's marks are solid and a glass bot's are
/// glass. A blend between two such definitions can carry two marks at once, each part way in.
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
/// context's transform and fills those paths. The exceptions are the eyes, whose *shape* depends on
/// the blink and the state, and the ribbons, whose outline moves with the turn — small paths either
/// way, and the whole animation budget. Nothing here reads a clock, allocates a bitmap or starts a
/// timer; the view feeds it a time.
public enum OpenBotAvatarRenderer {

    /// The default body colour: the app's own forge orange, the same ink the reference uses.
    public static let defaultColor = Color(red: 1.0, green: 0.416, blue: 0.102)
    /// The default eye ink.
    public static let defaultInk = Color(red: 0.082, green: 0.082, blue: 0.082)

    /// Which of the three things one frame draws, for a surface that has to composite them apart.
    ///
    /// A `Canvas` is one pass, and `.all` is that pass. The glass shader needs the body on its own —
    /// a `.layerEffect` covers everything in the layer it is applied to, and the shader must not touch
    /// an eye or a ribbon — so the view draws the body's `Canvas` between the ribbons' and the
    /// eyes'. Three passes, in the renderer's own paint order, so a shader surface composes exactly
    /// the frame the one-pass drawing would.
    public enum Pass: Hashable, Sendable {
        case all
        case behind
        case body
        case over

        var drawsBehind: Bool { self == .all || self == .behind }
        var drawsBody: Bool { self == .all || self == .body }
        var drawsOver: Bool { self == .all || self == .over }
    }

    /// Paint one frame.
    ///
    /// `material` and `backdrop` are the face's material and where it is drawn. The material is
    /// looked up in `BotAvatarMaterialSpec.all` and the drawing follows the spec; a spec whose fill
    /// is `.flat` takes the slice-stack path below, untouched since 0.1.648, which is what keeps
    /// Solid exactly the face a bot already had.
    ///
    /// `still` freezes the things that would otherwise move on their own inside a frame that is
    /// holding still (the marks of a definition of a host's own, which a reduced-motion surface must
    /// hold at rest). The pose has already dropped the ribbons and the celebration's turn by then;
    /// this is the one part the pose cannot express. `time` is the animation clock the marks are laid
    /// out on — the same clock the pose was computed from, so a mark and its body agree.
    ///
    /// `pass` splits one frame into the pieces a shader surface has to composite separately: the
    /// ribbons that pass behind the body, the body, and everything drawn over it (the eyes, the front
    /// of the ribbons, the marks). `.all` is one pass, which is what every surface but the glass
    /// shader draws. `route` is the caller's answer from `BotAvatarGlassRoute.decide` — this function
    /// does not choose, it follows: `.metal` draws the body as the flat silhouette the fragment pass
    /// replaces, `.canvas` paints the material's six layers.
    public static func draw(_ model: OpenBotAvatarModel,
                            pose: OpenBotAvatarPose,
                            material: BotAvatarMaterial = .solid,
                            backdrop: OpenBotAvatarBackdrop = .themed(dark: true),
                            into context: inout GraphicsContext,
                            size: CGSize,
                            color: Color,
                            ink: Color,
                            still: Bool = false,
                            time: Double = 0,
                            pass: Pass = .all,
                            route: BotAvatarGlassRoute = .canvas) {
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
        // How much of its size the body keeps while it gives way to its marks: 1 unless a pose
        // carries a mark, which none of the eight built-in states ever does (see `bodyScale`).
        let bodyScale = OpenBotAvatarMarks.bodyScale(pose.marks)
        let shrink = bodyScale < 1 ? scaleAbout(pivot: pivot, by: bodyScale) : CGAffineTransform.identity
        let seed = BotAvatarHash.shippedHash(model.definition.id)

        // Ribbons behind the body: they stay where the turn carried them while the body hops, and
        // they pass behind it along the bottom and in front of it along the top of their hoop.
        let rim = OpenBotAvatarRibbons.follow(pose.cage >= 0.5 ? model.ribbonRims.cage
                                                               : model.ribbonRims.work,
                                              lift: pose.lift, sx: pose.sx, sy: pose.sy, box: volume.box)
        // Only the passes that draw a ribbon build one: a body-only pass (the glass shader's) must not
        // pay for the hoops it will never see.
        let showsRibbons = pass.drawsBehind || pass.drawsOver
        let ribbons = showsRibbons && pose.ribbons > 0.01
            ? OpenBotAvatarRibbons.pieces(box: volume.box, presence: pose.ribbons, seed: seed,
                                          sweep: pose.sweep, cage: pose.cage, rim: rim)
            : []
        // Upstream grows its canvas to whatever the ribbons reach (`avatarExtent`); our canvas is the
        // view's own frame, so a band or a cage that would reach past the 100-unit box is fitted
        // inside it instead of being cut off by the edge. Counts, angles, easings and proportions
        // among the ribbons are upstream's; only their distance from the body gives way, and only on
        // a body wide enough to need it.
        let fit = ribbonFit(rim)
        if pass.drawsBehind {
            draw(ribbons: ribbons.filter { !$0.front }, into: &context, viewport: viewport,
                 color: color, fit: fit, about: rim)
        }

        if pass.drawsBody, route == .metal {
            // The glass shader's base: the silhouette filled flat, in the same tint every layer of the
            // painted material starts from. Nothing of the material is painted here — the fragment
            // pass replaces every pixel inside this fill — which is why this is not a call through
            // `BotAvatarMaterialRender.render`: there is no layer to paint, only a shape to cover.
            let face = bodyTransform(model, pose: pose, size: size)
            var layer = context
            layer.fill(model.silhouette.applying(face),
                       with: .color(OpenBotAvatarMaterialPaint.bodyColor(spec, light: pose.light,
                                                                        tint: color).color))
        } else if pass.drawsBody {
            switch spec.fill {
            case .flat:
                // The 0.1.648 body: the inferred volume's cross-sections, back to front, each filled
                // flat. Nothing below this line changed when materials arrived.
                var shapes: [BotAvatarMaterialRender.Shape] = []
                if bodyScale > 0.001 {
                    for slice in drawnSlices(volume: volume, basis: basis) {
                        let plane = planeTransform(basis: basis, z: slice.z, pivot: pivot)
                        shapes.append(.slice(path: slice.path,
                                             transform: shrink.concatenating(plane)
                                                 .concatenating(root)
                                                 .concatenating(viewport),
                                             evenOdd: slice.evenOdd))
                    }
                }
                var bodyContext = context
                BotAvatarMaterialRender.render(shapes, spec: spec, plan: plan, light: pose.light,
                                               backdrop: backdrop, tint: color, side: side,
                                               box: CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2,
                                                           width: side, height: side),
                                               into: &bodyContext)
            case .ramp:
                // One silhouette, painted from the material's spec. The front plane (z = 0) is the
                // outline the slice stack draws its core from, so the shape is the same one Solid
                // shows; the layers over it are what make it glass.
                let face = bodyTransform(model, pose: pose, size: size)
                let box = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2,
                                 width: side, height: side)
                BotAvatarMaterialRender.render([.silhouette(bodyScale > 0.001 ? model.silhouette.applying(face) : Path())],
                                               spec: spec, plan: plan, light: pose.light, backdrop: backdrop,
                                               tint: color, side: side, box: box, into: &context)
            }
        }

        guard pass.drawsOver else { return }
        // The eyes ride the surface, so they are drawn over the body: one pair, once per frame, for
        // every state — there is no gate here that a state could reach to take its face away.
        if bodyScale > 0.001 {
            drawEyes(model: model, pose: pose, basis: basis, into: &context, viewport: viewport,
                     root: root, ink: ink, pivot: pivot, catchlight: plan.catchlight,
                     shrink: shrink)
        }

        // The pieces of ribbon that pass in front of the body along the top of their hoop, then the
        // marks — both over the face, as upstream paints them (`render.ts` `flatFrame`: ribbons
        // behind, body, ribbons in front, marks last). For the eight built-in states both lists are
        // empty, and both calls draw nothing.
        draw(ribbons: ribbons.filter { $0.front }, into: &context, viewport: viewport, color: color,
             fit: fit, about: rim)
        BotAvatarMaterialRender.render(markShapes(pose.marks, model: model, seed: seed, still: still,
                                                  time: time, transform: viewport),
                                       spec: spec, plan: plan, light: pose.light, backdrop: backdrop,
                                       tint: color, side: side,
                                       box: CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2,
                                                   width: side, height: side),
                                       into: &context)
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

    /// The whole transform the body's front plane is drawn with: the plane at z = 0, the body's own
    /// motion, and the viewport.
    ///
    /// One place, three readers — the painted ramp's silhouette, the glass shader's coverage fill, and
    /// the numbers that fill describes itself with (`BotAvatarGlassSurface.make`) — so the surface the
    /// shader lights is the surface the `Canvas` filled, whichever way the pose has turned it.
    static func bodyTransform(_ model: OpenBotAvatarModel, pose: OpenBotAvatarPose,
                              size: CGSize) -> CGAffineTransform {
        let side = min(size.width, size.height)
        let unit = side / 100
        let viewport = CGAffineTransform(translationX: (size.width - side) / 2,
                                         y: (size.height - side) / 2)
            .scaledBy(x: unit, y: unit)
        let basis = ViewBasis(yaw: pose.yaw, pitch: pose.pitch)
        let base = CGPoint(x: model.volume.box.center.x, y: model.volume.box.maxY)
        return planeTransform(basis: basis, z: 0, pivot: model.volume.pivot)
            .concatenating(rootTransform(pose: pose, base: base))
            .concatenating(viewport)
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

    /// A scale of `by` about `pivot`, in the body's own coordinates: how the body shrinks toward its
    /// centre as it gives way to a mark (upstream's `shrink`, `render.ts` `flatFrame`).
    static func scaleAbout(pivot: OpenBotAvatarGeometry.Point, by scale: Double) -> CGAffineTransform {
        CGAffineTransform(translationX: -pivot.x, y: -pivot.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: pivot.x, y: pivot.y))
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
    /// One chain, one shape per eye. The plain pill and the plain arc are drawn as they always were —
    /// they are exact, and every built-in state is exactly one of them. Every look in between (a
    /// blend of the two, or a definition that asked for the slit) is one filled outline, morphed point
    /// by point, so a change of mood or state moves the eyes from one shape to the next instead of
    /// cutting inside a blink (`OpenBotAvatarEyes`, upstream's `eyes.ts`).
    static func drawEyes(model: OpenBotAvatarModel,
                         pose: OpenBotAvatarPose,
                         basis: ViewBasis,
                         into context: inout GraphicsContext,
                         viewport: CGAffineTransform,
                         root: CGAffineTransform,
                         ink: Color,
                         pivot: OpenBotAvatarGeometry.Point,
                         catchlight: Bool = false,
                         shrink: CGAffineTransform = .identity) {
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
        // What the mood and the state asked the eye's shape to be, as numbers that blend.
        let look = OpenBotAvatarEyeLook(arc: pose.arch, slit: pose.slit)
        let plain = OpenBotAvatarEyes.plain(look)

        for (index, center) in centers.enumerated() {
            let plane = model.volume.eyePlanes.indices.contains(index) ? model.volume.eyePlanes[index] : .init(z: 0, dzdx: 0, dzdy: 0)
            let z = plane.z + gazeX * plane.dzdx + gazeY * plane.dzdy
            let eyePoint = OpenBotAvatarGeometry.Point(center.x + gazeX, center.y + gazeY)
            let hip = OpenBotAvatarGeometry.Point(center.x, center.y + shift)
            let spot = OpenBotAvatarEyes.Spot(x: eyePoint.x, y: eyePoint.y,
                                              w: width, h: height, open: open, shift: shift)

            var layer = context
            var transform = planeTransform(basis: basis, z: z, pivot: pivot)
            // The tangent plane: slope in x and y so an eye on a curved face tips with it.
            transform.a += CGFloat(basis.sinYaw * plane.dzdx)
            transform.b -= CGFloat(basis.cosYaw * basis.sinPitch * plane.dzdx)
            transform.c += CGFloat(basis.sinYaw * plane.dzdy)
            transform.d -= CGFloat(basis.cosYaw * basis.sinPitch * plane.dzdy)
            // The eye's own plane, then the body's motion, then the view — the same chain the body
            // takes, so an eye is always drawn on the body it belongs to. The body's give-way to a
            // mark is inside that chain, so the eyes shrink with it.
            layer.transform = shrink
                .concatenating(transform)
                .concatenating(root)
                .concatenating(viewport)

            if let plain {
                switch plain {
                case .arc:
                    // The happy arc: a quadratic stroked with round caps, as upstream draws it, at
                    // the fractions the validator keeps room for (`HAPPY_ARC`).
                    layer.stroke(OpenBotAvatarEyes.arcPath(spot), with: .color(ink),
                                 style: StrokeStyle(lineWidth: CGFloat(OpenBotAvatarEyes.arcStroke(spot)),
                                                    lineCap: .round))
                case .pill:
                    let rect = CGRect(x: hip.x - width / 2, y: hip.y - open / 2, width: width, height: open)
                    let pill = Path(roundedRect: rect, cornerRadius: min(width, open) / 2)
                    layer.fill(pill, with: .color(ink))
                }
            } else {
                // Every look in between: one filled outline, morphed point by point.
                layer.fill(OpenBotAvatarEyes.eyePath(look, spot: spot), with: .color(ink))
            }

            // The one reflection the spec allows on the eye, and only above 64 pt: a 1 pt dot at
            // 30 % white, in the pupil's upper left. Below that size it is mud, so it is not drawn.
            if catchlight, plain != nil {
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

    // MARK: - Marks

    /// The parts of the pose's marks, placed on the body and handed to the material.
    ///
    /// A mark is drawn *by the material*, not by a second painter — glass draws them in glass, a
    /// solid body in its own flat tint, through the one entry point `BotAvatarMaterialRender.render`.
    /// Marks stay put while the body hops and turns: upstream paints them with the root's motion
    /// undone (`fixed = invert(root)`, `render.ts` `flatFrame`), and the ribbons the same way, so only
    /// the viewport places them — a cage that hopped with the body would not be a cage. An empty
    /// list — which is every built-in state — draws nothing.
    static func markShapes(_ marks: [PoseMark],
                           model: OpenBotAvatarModel,
                           seed: UInt32,
                           still: Bool,
                           time: Double,
                           transform: CGAffineTransform) -> [BotAvatarMaterialRender.Shape] {
        OpenBotAvatarMarks.placed(marks,
                                  in: model.volume.box,
                                  seed: seed,
                                  time: time,
                                  still: still)
            .map { part in
                // Scale, move to the part's place in the mark, then turn about the mark's centre —
                // upstream's `about(cx, cy, turn) · translate(x, y) · scale` (`render.ts`
                // `effectsOf`).
                let turn = part.turn
                let cosTurn = cos(turn), sinTurn = sin(turn)
                let aboutCentre = CGAffineTransform(
                    a: CGFloat(cosTurn), b: CGFloat(sinTurn),
                    c: CGFloat(-sinTurn), d: CGFloat(cosTurn),
                    tx: CGFloat(part.x - cosTurn * part.x + sinTurn * part.y),
                    ty: CGFloat(part.y - sinTurn * part.x - cosTurn * part.y)
                )
                let placed = CGAffineTransform(scaleX: CGFloat(part.scale), y: CGFloat(part.scale))
                    .concatenating(CGAffineTransform(translationX: CGFloat(part.x), y: CGFloat(part.y)))
                    .concatenating(aboutCentre)
                return BotAvatarMaterialRender.Shape.mark(path: part.path,
                                                          transform: placed.concatenating(transform),
                                                          round: part.round)
            }
    }

    // MARK: - Ribbons

    /// How much the ribbons are drawn down to sit inside the 100-unit box, 1 when they already do.
    ///
    /// Upstream grows its canvas to whatever the ribbons reach (`avatarExtent`, and `fitSquare` laying
    /// the bitmap over it), so its cage can stand well off the body and simply overflow the element.
    /// Our canvas *is* the element's frame and clips. So a band that would reach past the box is
    /// fitted about the hoops' centre instead of being cut by the edge — and never further than the
    /// point where its inner ring touches the body, so a cage can wrap the bot but can never be drawn
    /// through it. Counts, angles, easings and the proportions among the ribbons are upstream's; what
    /// gives way on a body with no room round it is how far they stand off it.
    ///
    /// The farthest any ribbon reaches is the outermost ring (`OpenBotAvatarRibbons.reach`) plus half a
    /// ribbon's width, from the centre. `50` keeps a hair of margin inside the box, so the outermost
    /// ribbon's edge is not on the frame's own edge where antialiasing would trim it.
    static func ribbonFit(_ rim: OpenBotAvatarRibbons.Rim) -> Double {
        let reach = OpenBotAvatarRibbons.reach(rimMax: rim.reach)
        guard reach.radius > 0 else { return 1 }
        let farthest = max(max(rim.cx, 100 - rim.cx), max(rim.cy, 100 - rim.cy))
        let extent = farthest + reach.radius + reach.band
        guard extent > 50 else { return 1 }
        // The cage's inner ring stands `rimMargin` outside the body: no fit may put it inside that.
        let floor = (rim.reach + OpenBotAvatarRibbons.rimMargin) / reach.radius
        return min(1, max(floor, 50 / extent))
    }

    /// The ribbon pieces, as filled outlines with a gradient along each one: lighter at the tail,
    /// darker at the head, in the body's own colour.
    ///
    /// Upstream gives each ribbon a hue from an OKLCH ramp of the body's colour (`render.ts`
    /// `ribbonPalette`); mixing toward white and black in sRGB is that read with a shorter table, and
    /// at 26 pt it is the same "shades of the body's own colour" the reference has.
    static func draw(ribbons: [OpenBotAvatarRibbons.Piece],
                     into context: inout GraphicsContext,
                     viewport: CGAffineTransform,
                     color: Color,
                     fit: Double = 1,
                     about rim: OpenBotAvatarRibbons.Rim? = nil) {
        guard !ribbons.isEmpty else { return }
        let base = MaterialColor(color)
        // The fit is about the hoops' centre, so the band keeps its shape and only its reach changes.
        let scale: CGAffineTransform
        if fit < 1, let rim {
            scale = CGAffineTransform(translationX: CGFloat(-rim.cx), y: CGFloat(-rim.cy))
                .concatenating(CGAffineTransform(scaleX: CGFloat(fit), y: CGFloat(fit)))
                .concatenating(CGAffineTransform(translationX: CGFloat(rim.cx), y: CGFloat(rim.cy)))
        } else {
            scale = .identity
        }
        for piece in ribbons {
            var layer = context
            layer.transform = scale
                .concatenating(viewport)
            let lane = piece.ribbon % OpenBotAvatarRibbons.lanes
            let light = base.mixed(with: .white, 0.26 - 0.08 * Double(lane))
            let dark = base.mixed(with: .black, 0.06 + 0.10 * Double(lane))
            let long = (pow(piece.to.x - piece.from.x, 2) + pow(piece.to.y - piece.from.y, 2)).squareRoot() > 0.01
            if long {
                layer.fill(piece.path, with: .linearGradient(
                    Gradient(stops: [
                        .init(color: light.color, location: 0),
                        .init(color: base.color, location: 0.5),
                        .init(color: dark.color, location: 1),
                    ]),
                    startPoint: piece.from, endPoint: piece.to))
            } else {
                layer.fill(piece.path, with: .color(base.color))
            }
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

    /// How far the body reaches from the hoops' centre, for a working turn's hoop and for a
    /// celebration's cage — measured once, from the body's own outline, and never per frame.
    public var ribbonRims: (work: OpenBotAvatarRibbons.Rim, cage: OpenBotAvatarRibbons.Rim) {
        rimLock.lock()
        defer { rimLock.unlock() }
        if let cached = rims { return cached }
        let polygons = volume.parts.flatMap { $0.polygons }
        let built = OpenBotAvatarRibbons.rims(polygons: polygons, box: volume.box)
        rims = built
        return built
    }

    private let rimLock = NSLock()
    private var rims: (work: OpenBotAvatarRibbons.Rim, cage: OpenBotAvatarRibbons.Rim)?

    private static let lock = NSLock()
    private static var cache: [String: OpenBotAvatarModel] = [:]
    private static let cacheLimit = 64

    /// The body's own inflation numbers, for the glass shader: the deepest part's inset radius and
    /// rise, and its half depth, in the definition's units.
    ///
    /// Built once with the volume — the parts never change after that — so a frame reads three
    /// doubles instead of walking the parts, and nothing is allocated to ask. The shader scales them
    /// by the frame's own points-per-unit (`BotAvatarGlassSurface.make`).
    let glassProfile: (rxy: Double, rz: Double, halfDepth: Double)

    private init(definition: BotAvatarDefinition, volume: OpenBotAvatarVolume) {
        self.definition = definition
        self.volume = volume
        var silhouette = Path()
        for part in volume.parts { silhouette.addPath(part.core.path) }
        self.silhouette = silhouette
        var rxy = 0.0, rz = 0.0, halfDepth = 0.0
        for part in volume.parts {
            rxy = Swift.max(rxy, part.rxy)
            rz = Swift.max(rz, part.rz)
            halfDepth = Swift.max(halfDepth, part.depth / 2)
        }
        self.glassProfile = (rxy, rz, halfDepth)
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
