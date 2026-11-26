import Foundation
import SwiftUI

/// The outline of one eye, for any look.
///
/// Upstream 0.3.0 stopped swapping an eye's shape inside a blink and started *morphing* it: the plain
/// pill, the happy arc and the flat slit of a waiting bot are each walked as a closed outline from the
/// top centre, clockwise, at even steps, and mixing them point by point gives every shape in between
/// (`packages/core/src/eyes.ts`). A change of state or mood therefore moves the eyes from one shape to
/// the next instead of cutting.
///
/// The plain pill and the plain happy arc keep the drawings they always had — a rounded rect and a
/// stroked arc — because those two are exact and cheap, and every built-in state of ours is exactly
/// one of them (`arch` is 0 or 1 from the mood, `slit` is never set). Everything in between is the
/// filled outline below.
public struct OpenBotAvatarEyeLook: Hashable, Sendable {
    /// 0 = the plain pill, 1 = the happy arc.
    public var arc: Double
    /// 0 = the plain pill, 1 = the flat slit. Never more than `1 - arc`.
    public var slit: Double

    public init(arc: Double = 0, slit: Double = 0) {
        self.arc = arc
        self.slit = slit
    }
}

public enum OpenBotAvatarEyes {

    /// Points per outline. `eyes.ts:25`.
    static let steps = 40

    /// The slit: as long as the happy arc is wide, this thick (both shares of the eye's width),
    /// tipped this far. `eyes.ts:27`.
    static let slitLength = 1.9
    static let slitThickness = 0.5
    static let slitTip = 0.2

    /// The happy arc's own numbers — half its width, its base below the eye's centre, its peak above
    /// it, and its stroke, all shares of the eye's box. Upstream `validate.ts:24` (`HAPPY_ARC`); the
    /// validator keeps that much room inside the body for the arc, which is why the arc is drawn at
    /// these fractions and not at the pill's.
    public enum Arc {
        public static let halfWidth = 0.72
        public static let base = 0.10
        public static let peak = 0.42
        public static let stroke = 0.60
    }

    /// Where one eye is drawn this frame, in viewBox units and its face plane.
    public struct Spot: Hashable, Sendable {
        /// Centre, gaze included.
        public var x: Double
        public var y: Double
        /// Neutral size.
        public var w: Double
        public var h: Double
        /// Height of the pill after blink and squint, and how far that moves it down.
        public var open: Double
        public var shift: Double
    }

    /// Which plain drawing a look is, if it is exactly one: those two are drawn as they always were.
    /// `eyes.ts:113`.
    public enum Plain: Hashable, Sendable {
        case pill
        case arc
    }

    public static func plain(_ look: OpenBotAvatarEyeLook) -> Plain? {
        if look.arc >= 1 { return .arc }
        return look.arc <= 0 && look.slit <= 0 ? .pill : nil
    }

    /// The happy arc's centre line, as a path to stroke with round caps: from the left end, through
    /// the control point above the eye's centre, to the right end. Upstream's `happyArc`, render.ts.
    public static func arcPath(_ spot: Spot) -> Path {
        let halfWidth = spot.w * Arc.halfWidth
        let base = spot.y + spot.h * Arc.base
        var path = Path()
        path.move(to: CGPoint(x: spot.x - halfWidth, y: base))
        path.addQuadCurve(to: CGPoint(x: spot.x + halfWidth, y: base),
                          control: CGPoint(x: spot.x, y: spot.y - spot.h * Arc.peak))
        return path
    }

    /// The arc's stroke width in the eye's own units.
    public static func arcStroke(_ spot: Spot) -> Double { spot.w * Arc.stroke }

    // MARK: - The outline

    /// An arc of a circle as points, from angle `from` to `to` (radians, y down), ends included.
    static func sweep(cx: Double, cy: Double, r: Double, from: Double, to: Double,
                      steps: Int) -> [OpenBotAvatarGeometry.Point] {
        (0...steps).map { index in
            let a = from + (to - from) * Double(index) / Double(steps)
            return OpenBotAvatarGeometry.Point(cx + cos(a) * r, cy + sin(a) * r)
        }
    }

    /// The pill: a stadium `w` wide and `h` tall about (cx, cy), from the top centre, clockwise.
    /// `eyes.ts:63`.
    static func pill(cx: Double, cy: Double, w: Double, h: Double) -> [OpenBotAvatarGeometry.Point] {
        let r = min(w, h) / 2
        let fx = w / 2 - r, fy = h / 2 - r
        let q = Double.pi / 2
        return [OpenBotAvatarGeometry.Point(cx, cy - h / 2)]
            + sweep(cx: cx + fx, cy: cy - fy, r: r, from: -q, to: 0, steps: 6)
            + sweep(cx: cx + fx, cy: cy + fy, r: r, from: 0, to: q, steps: 6)
            + sweep(cx: cx - fx, cy: cy + fy, r: r, from: q, to: 2 * q, steps: 6)
            + sweep(cx: cx - fx, cy: cy - fy, r: r, from: 2 * q, to: 3 * q, steps: 6)
    }

    /// The happy arc as an outline: its stroke's two edges and round ends, from the top centre,
    /// clockwise. `eyes.ts:77`.
    static func arc(_ spot: Spot) -> [OpenBotAvatarGeometry.Point] {
        let halfWidth = spot.w * Arc.halfWidth
        let base = spot.y + spot.h * Arc.base, peak = spot.y - spot.h * Arc.peak
        let r = (spot.w * Arc.stroke) / 2
        func at(_ s: Double) -> (p: OpenBotAvatarGeometry.Point, n: OpenBotAvatarGeometry.Point) {
            let m = 1 - s
            let x = spot.x + halfWidth * (2 * s - 1)
            let y = (m * m + s * s) * base + 2 * m * s * peak
            let tx = 2 * halfWidth, ty = 2 * (2 * s - 1) * (base - peak)
            let length = (tx * tx + ty * ty).squareRoot()
            return (OpenBotAvatarGeometry.Point(x, y), OpenBotAvatarGeometry.Point(ty / length, -tx / length))
        }
        func edge(_ from: Double, _ to: Double, _ side: Double) -> [OpenBotAvatarGeometry.Point] {
            (0...8).map { index in
                let (p, n) = at(from + (to - from) * Double(index) / 8)
                return OpenBotAvatarGeometry.Point(p.x + n.x * r * side, p.y + n.y * r * side)
            }
        }
        func end(_ s: Double) -> [OpenBotAvatarGeometry.Point] {
            let (p, n) = at(s)
            let up = atan2(n.y, n.x)
            // Round the end from the upper edge to the lower one, the long way round its tip.
            return s == 1
                ? sweep(cx: p.x, cy: p.y, r: r, from: up, to: up + .pi, steps: 8)
                : sweep(cx: p.x, cy: p.y, r: r, from: up + .pi, to: up + 2 * .pi, steps: 8)
        }
        return edge(0.5, 1, 1) + end(1) + edge(1, 0, -1) + end(0) + edge(0, 0.5, 1)
    }

    /// The slit: a thin capsule lying almost flat, both eyes tipped the same way; a blink thins it.
    /// `eyes.ts:106`.
    static func slit(_ spot: Spot) -> [OpenBotAvatarGeometry.Point] {
        let length = spot.w * slitLength
        let thickness = spot.w * slitThickness * min(1, max(0.3, spot.open / spot.h))
        let c = cos(slitTip), s = sin(slitTip)
        return pill(cx: 0, cy: 0, w: length, h: thickness).map {
            OpenBotAvatarGeometry.Point(spot.x + $0.x * c - $0.y * s,
                                        spot.y + $0.x * s + $0.y * c)
        }
    }

    /// `count` points at even steps along a closed polyline, the first one at its first point.
    /// `eyes.ts:32`.
    static func resample(_ points: [OpenBotAvatarGeometry.Point],
                         count: Int) -> [OpenBotAvatarGeometry.Point] {
        let n = points.count
        guard n > 2 else { return points }
        var at = [0.0]
        for index in 0..<n {
            let a = points[index], b = points[(index + 1) % n]
            at.append(at[index] + a.distance(to: b))
        }
        let total = at[n]
        guard total > 0 else { return points }
        var out: [OpenBotAvatarGeometry.Point] = []
        var index = 0
        for k in 0..<count {
            let s = Double(k) / Double(count) * total
            while index < n - 1 && at[index + 1] < s { index += 1 }
            let a = points[index], b = points[(index + 1) % n]
            let u = at[index + 1] > at[index] ? (s - at[index]) / (at[index + 1] - at[index]) : 0
            out.append(OpenBotAvatarGeometry.Point(a.x + (b.x - a.x) * u,
                                                   a.y + (b.y - a.y) * u))
        }
        return out
    }

    /// The outline of one eye, closed, clockwise from the top: the pill, the arc and the slit mixed by
    /// the look. `eyes.ts:119`.
    public static func outline(_ look: OpenBotAvatarEyeLook, spot: Spot) -> [OpenBotAvatarGeometry.Point] {
        let a = min(1, max(0, look.arc))
        let s = min(1 - a, max(0, look.slit))
        let shapes: [(Double, [OpenBotAvatarGeometry.Point])] = [
            (1 - a - s, pill(cx: spot.x, cy: spot.y + spot.shift, w: spot.w, h: spot.open)),
            (a, arc(spot)),
            (s, slit(spot)),
        ]
        var out = [OpenBotAvatarGeometry.Point](repeating: .zero, count: steps)
        for (weight, shape) in shapes where weight > 0 {
            for (index, point) in resample(shape, count: steps).enumerated() {
                out[index].x += point.x * weight
                out[index].y += point.y * weight
            }
        }
        return out
    }

    /// A smooth closed path through an outline: a quadratic per point, joined at the midpoints — the
    /// same curve upstream's `outlinePath` writes as SVG (`eyes.ts:139`).
    public static func path(_ points: [OpenBotAvatarGeometry.Point]) -> Path {
        let n = points.count
        guard n > 2 else { return Path() }
        func mid(_ index: Int) -> OpenBotAvatarGeometry.Point {
            let a = points[index % n], b = points[(index + 1) % n]
            return OpenBotAvatarGeometry.Point((a.x + b.x) / 2, (a.y + b.y) / 2)
        }
        var path = Path()
        let start = mid(n - 1)
        path.move(to: CGPoint(x: start.x, y: start.y))
        for index in 0..<n {
            let m = mid(index)
            path.addQuadCurve(to: CGPoint(x: m.x, y: m.y),
                              control: CGPoint(x: points[index].x, y: points[index].y))
        }
        path.closeSubpath()
        return path
    }

    /// The path of one eye for a look that is neither the plain pill nor the plain arc.
    public static func eyePath(_ look: OpenBotAvatarEyeLook, spot: Spot) -> Path {
        path(outline(look, spot: spot))
    }
}
