import Foundation
import SwiftUI

/// Sierra's six layers, painted from a `BotAvatarMaterialSpec`.
///
/// Everything here is in **canvas points**. The silhouette arrives already transformed (the
/// renderer applies the view rotation, the body's squash and the viewport before calling), so every
/// fraction a spec names — 0.04 of the side, 0.6 of the bounds — is a fraction of what is on screen,
/// and every blur is the point value the spec names. Nothing here allocates geometry that the
/// definition could have given us: the only paths built per frame are a capsule, a band and a
/// rectangle, and the gradients' stops.
///
/// ## The layers, bottom to top
///
/// 1. **halo** — the silhouette in the tint, offset down and blurred, inside the box only;
/// 2. **fill** — a vertical ramp (the volume illusion), a horizoned ramp (metal) or a flat tint;
/// 3. **sheens** — a soft radial highlight, clipped to the shape, added light;
/// 4. **streaks** — a rotated capsule of white, faded along its short axis, added light;
/// 5. **rim** — the silhouette stroked with a gradient; this is what reads as glass in 2-D;
/// 6. **contact** — a dark band along the bottom inside edge, clipped to the shape.
///
/// A material that names none of 1, 3, 4, 5 and 6 is a flat fill, and a flat fill is not painted
/// here at all: the renderer draws it through the volume's own slice stack, which is the 0.1.648
/// face. That is the whole reason Solid is a row with an empty spec.
enum OpenBotAvatarMaterialPaint {

    static func paint(_ spec: BotAvatarMaterialSpec,
                      light: OpenBotAvatarLight,
                      backdrop: OpenBotAvatarBackdrop,
                      silhouette: Path,
                      tint: Color,
                      side: CGFloat,
                      box: CGRect,
                      plan: MaterialPlan,
                      into context: inout GraphicsContext) {
        let bounds = silhouette.boundingRect
        guard bounds.width > 0, bounds.height > 0 else { return }

        // The bot's own colour, calmed on `blocked` when the material says a state may do that.
        // No new colour inputs: the tint *is* the palette the bot already chose.
        let raw = MaterialColor(tint)
        let base = spec.desaturatesWhenBlocked && light.desaturate > 0
            ? raw.desaturated(by: light.desaturate)
            : raw

        // 1 — halo: the silhouette in the tint, a little low, blurred, inside the box only.
        if plan.halo, let halo = spec.halo {
            var boxed = context
            boxed.clip(to: Path(box))
            // Blur inside, clip outside: the box edge is what stops the light spilling over the
            // row beside it, and clipping *after* the blur is what keeps that edge soft instead of
            // a cut. The pet's own window is a 96 pt square with a 12 pt clear margin, so its blur
            // is capped (`MaterialDetail.petHaloBlurCap`) rather than allowed to smear at 200 %.
            boxed.drawLayer { layer in
                layer.addFilter(.blur(radius: haloRadius(halo, side: side, backdrop: backdrop)))
                let offset = silhouette.applying(CGAffineTransform(translationX: 0,
                                                                  y: CGFloat(halo.offset) * side))
                layer.fill(offset, with: .color(base.resolved(halo.tone, opacity: light.halo)))
            }
        }

        // 2 — the body: a vertical ramp through the tint. This is the whole volume illusion.
        switch spec.fill {
        case .flat:
            context.fill(silhouette, with: .color(base.color))
        case .ramp(let lightness, let mid, let darkness, let step):
            context.fill(silhouette, with: .linearGradient(
                Gradient(stops: rampStops(lightness: lightness, mid: mid, darkness: darkness,
                                          step: step, base: base)),
                startPoint: CGPoint(x: bounds.midX, y: bounds.minY),
                endPoint: CGPoint(x: bounds.midX, y: bounds.maxY)))
        }

        // 3 — the form sheen: soft light from the upper left, clipped to the shape, no blur needed.
        if plan.details {
            for sheen in spec.sheens {
                var layer = context
                layer.clip(to: silhouette)
                layer.blendMode = sheen.blend.graphics
                let centre = CGPoint(x: bounds.minX + CGFloat(sheen.center.x) * bounds.width,
                                     y: bounds.minY + CGFloat(sheen.center.y) * bounds.height)
                let radius = CGFloat(sheen.radius) * max(bounds.width, bounds.height)
                layer.fill(Path(bounds), with: .radialGradient(
                    Gradient(stops: [
                        .init(color: Color.white.opacity(sheen.opacity), location: 0),
                        .init(color: Color.white.opacity(0), location: 1),
                    ]),
                    center: centre, startRadius: 0, endRadius: radius))
            }

            // 4 — the specular streak: one capsule in the upper left, white fading to clear across
            // its short axis, clipped to the shape.
            for streak in spec.streaks {
                var layer = context
                layer.clip(to: silhouette)
                layer.blendMode = streak.blend.graphics
                layer.addFilter(.blur(radius: CGFloat(streak.blur)))
                let length = CGFloat(streak.length) * bounds.width
                let thickness = max(1, CGFloat(streak.thickness) * bounds.width)
                let anchor = CGPoint(x: bounds.minX + CGFloat(streak.anchor.x) * bounds.width,
                                     y: bounds.minY + CGFloat(streak.anchor.y) * bounds.height)
                let capsule = Path(roundedRect: CGRect(x: -length / 2, y: -thickness / 2,
                                                       width: length, height: thickness),
                                   cornerRadius: thickness / 2)
                    .applying(CGAffineTransform(rotationAngle: CGFloat(streak.angle))
                        .concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y)))
                // The gradient runs across the capsule's thickness, not along it: bright at one long
                // edge, clear at the other, which is what a reflection on a curved surface looks
                // like. Two points on the short axis through the anchor.
                let across = CGVector(dx: CGFloat(-sin(streak.angle)), dy: CGFloat(cos(streak.angle)))
                layer.fill(capsule, with: .linearGradient(
                    Gradient(stops: [
                        .init(color: Color.white.opacity(streak.opacity), location: 0),
                        .init(color: Color.white.opacity(0), location: 1),
                    ]),
                    startPoint: CGPoint(x: anchor.x - across.dx * thickness / 2,
                                        y: anchor.y - across.dy * thickness / 2),
                    endPoint: CGPoint(x: anchor.x + across.dx * thickness / 2,
                                      y: anchor.y + across.dy * thickness / 2)))
            }
        }

        // 5 — the Fresnel rim. This is the layer that makes it read as glass, and the first to go
        // when a surface is too small to carry it: it must survive at 26 pt.
        if plan.rim, let rim = spec.rim {
            var layer = context
            layer.blendMode = rim.blend.graphics
            // The pet can never know its wallpaper, so it always takes the two-tone rim; a themed
            // surface swaps to the light gradient, where a white rim would vanish into paper.
            let twoTone = backdrop.forcesTwoToneRim || !backdrop.isLight
            let stops: [Gradient.Stop] = (twoTone ? rim.stops : (rim.lightStops ?? rim.stops))
                .map { Gradient.Stop(color: base.resolved($0.tone, opacity: $0.opacity),
                                     location: CGFloat($0.location)) }
            layer.stroke(silhouette, with: .linearGradient(
                Gradient(stops: stops),
                startPoint: CGPoint(x: bounds.minX, y: bounds.minY),
                endPoint: CGPoint(x: bounds.maxX, y: bounds.maxY)),
                style: StrokeStyle(lineWidth: max(CGFloat(rim.minimumWidth), side * CGFloat(rim.width)),
                                   lineJoin: .round))
            // A light backdrop's dark hairline, outside the rim, so the silhouette holds on paper.
            if !twoTone, let hairline = rim.outerHairline {
                layer.blendMode = .normal
                layer.stroke(silhouette,
                             with: .color(base.resolved(hairline.tone, opacity: hairline.opacity)),
                             style: StrokeStyle(lineWidth: CGFloat(rim.hairlineWidth)))
            }
        }

        // 6 — the contact band. Without it the shape looks pasted on the page.
        if plan.contact, let contact = spec.contact {
            var layer = context
            layer.clip(to: silhouette)
            layer.blendMode = contact.blend.graphics
            layer.addFilter(.blur(radius: CGFloat(contact.blur)))
            let height = CGFloat(contact.height) * bounds.height
            // The band starts inside the bottom edge and runs past it, so the blur's darkest part is
            // the edge itself and it falls off upward, inside the shape.
            let band = CGRect(x: bounds.minX - 2, y: bounds.maxY - height,
                              width: bounds.width + 4, height: height + 4)
            layer.fill(Path(band), with: .color(base.resolved(contact.tone, opacity: contact.opacity)))
        }

        if plan.texture, let texture = spec.texture {
            paintTexture(texture, in: &context, silhouette: silhouette, bounds: bounds, base: base)
        }
    }

    /// The body's vertical gradient, from the material's own four numbers.
    ///
    /// Three stops is the reference's glass ramp: white-mixed, the tint at `mid`, black-mixed. A
    /// material that names a `step` gets four: the light half falls to the tint at `mid`, the dark
    /// half starts `step` of the height later, and the crossing between them is that narrow — a
    /// metal's horizon — before the dark half deepens once more at the foot. Glass passes nil and its
    /// three stops are exactly the three it always had.
    static func rampStops(lightness: Double,
                          mid: Double,
                          darkness: Double,
                          step: Double?,
                          base: MaterialColor) -> [Gradient.Stop] {
        let light = base.mixed(with: .white, lightness).color
        let dark = base.mixed(with: .black, darkness).color
        guard let step else {
            return [
                .init(color: light, location: 0),
                .init(color: base.color, location: CGFloat(mid)),
                .init(color: dark, location: 1),
            ]
        }
        let seam = CGFloat(max(0, min(1, mid)))
        let width = CGFloat(max(0, min(1, step)))
        // The dark half keeps a little form: it deepens toward the bottom instead of sitting flat.
        let foot = base.mixed(with: .black, min(1, darkness * 1.35)).color
        return [
            .init(color: light, location: 0),
            .init(color: base.color, location: seam),
            .init(color: dark, location: min(1, seam + width)),
            .init(color: foot, location: 1),
        ]
    }

    /// The halo's blur in points, capped for the pet. A glow that is bigger than the pet's clear
    /// margin is cut by the window and shows as a hard edge on the wallpaper.
    static func haloRadius(_ halo: MaterialHalo, side: CGFloat, backdrop: OpenBotAvatarBackdrop) -> CGFloat {
        let radius = CGFloat(halo.blur) * side
        return backdrop == .pet ? min(radius, CGFloat(MaterialDetail.petHaloBlurCap)) : radius
    }

    /// A pattern over the fill. Matte is the one shipped material that asks for one (its grain); the
    /// row below is what a fabric would add.
    static func paintTexture(_ texture: MaterialTexture,
                             in context: inout GraphicsContext,
                             silhouette: Path,
                             bounds: CGRect,
                             base: MaterialColor) {
        var layer = context
        layer.clip(to: silhouette)
        let cells = max(2, texture.cells)
        let step = max(bounds.width, bounds.height) / CGFloat(cells)
        // Grain is the same lattice at half the spacing and a finer dot: one drawing, two densities,
        // so the pattern a spec names is the pattern that is drawn.
        let spacing = texture.pattern == .grain ? step / 2 : step
        let dot = spacing * (texture.pattern == .grain ? 0.10 : 0.18)
        var dots = Path()
        var y = bounds.minY
        while y <= bounds.maxY {
            var x = bounds.minX
            while x <= bounds.maxX {
                dots.addEllipse(in: CGRect(x: x, y: y, width: dot, height: dot))
                x += spacing
            }
            y += spacing
        }
        layer.fill(dots, with: .color(base.resolved(texture.tone, opacity: texture.opacity)))
    }
}

// MARK: - The one entry point a material has

/// What a material paints, and the only function that paints it.
///
/// Upstream's 0.5.0 collapsed a material's `paintMark` into its `render`, so a material is one
/// function that draws the body *and every part of a mark*: that is what makes a mark a mark of the
/// material rather than a second painter laid over it (`dom/materials/material.ts`). Ours has the same
/// single entry, `render(_:…)`, and it is handed the body's cross-sections, the body's silhouette and
/// a mark's parts as the same kind of value — a shape with a colour note and a transform — so there is
/// no path by which a mark could be drawn by something that is not the material.
///
/// Glass draws a mark in glass: each part goes through `OpenBotAvatarMaterialPaint.paint` exactly as
/// the body does — the same ramp, the same rim, the same contact band — so a glass bot's dots look
/// like pieces of the glass bot. Solid fills a part flat in the body's own tint, the way it fills its
/// slices. Upstream renders each part once into a sprite because its glass material is a WebGL pass
/// over a distance field; a `GraphicsContext` fill is cheap enough that we paint per frame, and a part
/// keeps its `shape` name so a retained renderer could still cache it.
///
/// The painter calls this once for the body and once for the marks (which paint last, over the face),
/// as upstream's `paintCanvas` asks its material per shape in paint order.
enum BotAvatarMaterialRender {

    /// One thing to paint. A cross-section and a silhouette are the body; a mark part is a mark.
    enum Shape {
        /// One of the flat material's cross-sections, in its own plane.
        case slice(path: Path, transform: CGAffineTransform, evenOdd: Bool)
        /// The one outline a ramp material fills.
        case silhouette(Path)
        /// One part of a mark: its outline in its own units, where it goes, and whether it is a ball
        /// or a capsule (which a material draws from a ready ball).
        case mark(path: Path, transform: CGAffineTransform, round: Bool)
    }

    static func render(_ shapes: [Shape],
                       spec: BotAvatarMaterialSpec,
                       plan: MaterialPlan,
                       light: OpenBotAvatarLight,
                       backdrop: OpenBotAvatarBackdrop,
                       tint: Color,
                       side: CGFloat,
                       box: CGRect,
                       into context: inout GraphicsContext) {
        for shape in shapes {
            switch shape {
            case .slice(let path, let transform, let evenOdd):
                // The 0.1.648 drawing: each cross-section filled flat, in its own plane.
                var layer = context
                layer.transform = transform
                layer.fill(path, with: .color(tint),
                           style: FillStyle(eoFill: evenOdd, antialiased: true))
            case .silhouette(let path):
                guard !path.isEmpty else { break }
                OpenBotAvatarMaterialPaint.paint(spec, light: light, backdrop: backdrop, silhouette: path,
                                                 tint: tint, side: side, box: box, plan: plan, into: &context)
            case .mark(let path, let transform, _):
                let outline = path.applying(transform)
                guard !outline.isEmpty else { break }
                switch spec.fill {
                case .flat: context.fill(outline, with: .color(tint))
                case .ramp:
                    OpenBotAvatarMaterialPaint.paint(spec, light: light, backdrop: backdrop,
                                                     silhouette: outline, tint: tint, side: side,
                                                     box: box, plan: plan, into: &context)
                }
            }
        }
    }
}

// MARK: - The plan: what this size draws

/// What a material draws at one size. A decision made from the side and the backdrop, never from a
/// call site: a new surface gets the right layers because it passes a size, not because it
/// remembered to ask for them.
struct MaterialPlan: Hashable, Sendable {
    /// Layer 1, the halo.
    var halo: Bool
    /// Layers 3 and 4, the sheen and the streak.
    var details: Bool
    /// Layer 5.
    var rim: Bool
    /// Layer 6.
    var contact: Bool
    /// A pattern over the fill, when the material has one.
    var texture: Bool
    /// The eye's catchlight, which is only honest above its own size.
    var catchlight: Bool

    /// 26 pt is a list row and 26–32 pt the chat header: at those sizes a glass body is layers
    /// **2, 5 and 6 only** — the ramp, the rim, the contact band. The halo, the sheen and the streak
    /// are noise there, and so is the catchlight.
    ///
    /// `backdrop` is here so the rule stays "the drawing decides from the surface", not "the caller
    /// chooses"; the size is the only thing that changes the answer today.
    static func plan(for spec: BotAvatarMaterialSpec,
                     side: Double,
                     backdrop: OpenBotAvatarBackdrop) -> MaterialPlan {
        let full = side >= MaterialDetail.fullStackFrom
        return MaterialPlan(halo: full,
                            details: full,
                            rim: true,
                            contact: true,
                            texture: full,
                            // The eye's catchlight belongs to a lit material, and only above its
                            // own size: 1 pt of white in a 3 pt eye is mud.
                            catchlight: spec.addsEyeCatchlight && side >= MaterialDetail.catchlightFrom)
    }
}

/// The sizes at which a material changes what it draws.
enum MaterialDetail {
    /// Below this, layers 2, 5 and 6 only: a list row (26 pt) and the chat header (26–32 pt) both
    /// sit under it, and both are too small for a streak to read as anything but a smudge. The
    /// pet (96 pt) and the editor's preview (200–320 pt) are well above it.
    static let fullStackFrom: Double = 48
    /// The catchlight. Below 64 pt a 1 pt dot inside a 3 pt eye turns to mud, so the eye is left
    /// solid ink and nothing else.
    static let catchlightFrom: Double = 64
    /// The pet's window is a 96 pt square with a 12 pt clear margin: past this the halo is cut by
    /// the box and reads as a hard edge on the wallpaper.
    static let petHaloBlurCap: Double = 6
}

// MARK: - The light

/// How lit a material is in one state: the rim's and the halo's opacity, and how far the tint is
/// desaturated. The pose carries one per frame, so a frame can be reproduced and tested.
public struct OpenBotAvatarLight: Hashable, Sendable {
    public var rim: Double
    public var halo: Double
    /// 0…1 of the tint's saturation removed. Glass takes 0.15 on `blocked`; a solid ignores it.
    public var desaturate: Double

    public init(rim: Double, halo: Double, desaturate: Double = 0) {
        self.rim = rim
        self.halo = halo
        self.desaturate = desaturate
    }
}

/// One state's light, and how it moves.
struct GlassPulse {
    /// The dim end of the rim; for a steady state this is the value.
    var rim: Double
    /// The bright end, when the state pulses or falls.
    var rimHigh: Double
    var halo: Double
    /// Seconds for one full pulse; 0 is steady.
    var period: Double
    /// Seconds for `done` to fall from `rimHigh` back to idle's `rim`; 0 is not a falling state.
    var fallSeconds: Double
    /// Saturation removed from the tint.
    var desaturate: Double

    init(rim: Double, rimHigh: Double? = nil, halo: Double, period: Double = 0,
         fallSeconds: Double = 0, desaturate: Double = 0) {
        self.rim = rim
        self.rimHigh = rimHigh ?? rim
        self.halo = halo
        self.period = period
        self.fallSeconds = fallSeconds
        self.desaturate = desaturate
    }
}

extension OpenBotAvatarState {

    /// The glass light for this state, from the reference's table: `rim/halo`.
    ///
    /// | state    | rim           | halo  | motion                       |
    /// |----------|---------------|-------|------------------------------|
    /// | idle     | 0.55          | 0.20  | steady                       |
    /// | thinking | 0.55 → 0.75   | 0.20  | pulse, 2.4 s                 |
    /// | reading  | 0.60          | 0.22  | steady                       |
    /// | working  | 0.60 → 0.85   | 0.20  | pulse, 1.2 s                 |
    /// | computer | 0.70          | 0.30  | steady                       |
    /// | waiting  | 0.65 → 0.75   | 0.35  | slow pulse, 3.2 s            |
    /// | blocked  | 0.50          | 0.15  | steady, tint −15 % saturation |
    /// | done     | 0.75 → 0.55   | 0.20  | falls to idle as it expires  |
    ///
    /// The material itself never changes with the state: only the rim and the halo move, which is
    /// the reference's own model — a state is an accent on one material, not a different look.
    var glassPulse: GlassPulse {
        switch self {
        case .idle:
            return GlassPulse(rim: 0.55, halo: 0.20)
        case .thinking:
            return GlassPulse(rim: 0.55, rimHigh: 0.75, halo: 0.20, period: 2.4)
        case .reading:
            return GlassPulse(rim: 0.60, halo: 0.22)
        case .working:
            return GlassPulse(rim: 0.60, rimHigh: 0.85, halo: 0.20, period: 1.2)
        case .computer:
            return GlassPulse(rim: 0.70, halo: 0.30)
        case .waiting:
            // Slow and shallow: half thinking's rise, over twice its period.
            return GlassPulse(rim: 0.65, rimHigh: 0.75, halo: 0.35, period: 3.2)
        case .blocked:
            // Calm, not alarmed: no red, a dimmer rim and a desaturated tint.
            return GlassPulse(rim: 0.50, halo: 0.15, desaturate: 0.15)
        case .done:
            // Peaks at 0.75 and falls back to idle's 0.55 as the state expires.
            return GlassPulse(rim: 0.55, rimHigh: 0.75, halo: 0.20, fallSeconds: 1.4)
        }
    }

}

public extension OpenBotAvatarState {

    /// The light at `time`, interpolated from the state's own clock.
    ///
    /// `time` is seconds on the same monotonic clock the pose uses. Under Reduce Motion every pulse
    /// is frozen **at its midpoint** rather than at its start: a still frame of a pulsing state
    /// should look like the state, not like the trough before it.
    func light(time: Double, reducedMotion: Bool) -> OpenBotAvatarLight {
        let pulse = glassPulse
        // The halo follows the rim by the same fraction: it is how lit the body is, not a second
        // clock with a second phase to keep in step.
        func halo(for rim: Double) -> Double {
            pulse.rim > 0 ? pulse.halo * (rim / pulse.rim) : pulse.halo
        }
        if reducedMotion {
            let rim = (pulse.rim + pulse.rimHigh) / 2
            return OpenBotAvatarLight(rim: rim, halo: halo(for: rim), desaturate: pulse.desaturate)
        }
        if pulse.fallSeconds > 0 {
            // `done`: one fall, then idle's rim for the rest of the state.
            let progress = min(1, max(0, time / pulse.fallSeconds))
            let rim = pulse.rimHigh + (pulse.rim - pulse.rimHigh) * progress
            return OpenBotAvatarLight(rim: rim, halo: halo(for: rim), desaturate: pulse.desaturate)
        }
        if pulse.period > 0 {
            // A sine, 0 at the trough and 1 at the peak: calm at the 10 Hz the face is sampled at,
            // where anything faster would strobe.
            let phase = (1 - cos(2 * .pi * time / pulse.period)) / 2
            let rim = pulse.rim + (pulse.rimHigh - pulse.rim) * phase
            return OpenBotAvatarLight(rim: rim, halo: halo(for: rim), desaturate: pulse.desaturate)
        }
        return OpenBotAvatarLight(rim: pulse.rim, halo: pulse.halo, desaturate: pulse.desaturate)
    }
}

// MARK: - Where a face is drawn

/// Where a face is being drawn, which decides how its rim reads.
///
/// The pet is the one surface that cannot know: it floats over a wallpaper the app never sees, so a
/// white rim that would vanish into Parchment still reads against a photograph, and the two-tone rim
/// is used there always. A themed surface knows its page, so a light one swaps the rim and adds a
/// dark hairline inside the silhouette's own edge.
public enum OpenBotAvatarBackdrop: Hashable, Sendable {
    /// A themed surface — a list row, the chat header, settings, the editor — on the given scheme.
    case themed(dark: Bool)
    /// The desktop pet: unknown wallpaper, always the two-tone rim.
    case pet

    /// Whether the light-scheme rim rule applies. Never for the pet.
    var isLight: Bool {
        if case .themed(dark: false) = self { return true }
        return false
    }

    /// The pet forces the two-tone rim whatever the scheme says.
    var forcesTwoToneRim: Bool { self == .pet }
}
