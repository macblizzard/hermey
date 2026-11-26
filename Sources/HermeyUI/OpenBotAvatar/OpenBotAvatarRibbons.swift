import Foundation
import SwiftUI

/// The ribbons that circle the body: a port of `packages/core/src/effects.ts` in
/// open-bot-avatar 0.5.1.
///
/// A working bot's turn lets out three to five ribbons on one hoop; a celebration — `done` — lets out
/// three on each of three crossing hoops, nine in all, a cage of them round the body. Each hoop is a
/// ring tipped out of the screen so it shows as a flat ellipse, and its near side is the top: a
/// ribbon crosses in front of the body along the top and behind it along the bottom. A ribbon starts
/// at the top of its hoop and goes round with the body's turn (`sweep`), each at its own share of it
/// plus a drift of its own, so the ribbons on one hoop part as they go; its ring widens as it goes,
/// and its tail trails behind its head. Ribbons are drawn as filled outlines, round at both ends, a
/// little narrower at the tail than at the head and narrower behind the body, and split where a
/// ribbon passes from behind the body to in front of it.
///
/// Every length below is the demo's, measured from the Grok Bot demo at one size for every avatar
/// (upstream's PR #14): in the demo's 228.541-unit space that its bot fills, which here is a body of
/// the typical size, `BODY` units across — so one design unit is `BODY / DESIGN` avatar units
/// whatever the avatar (effects.ts:59-70).
///
/// The numbers are upstream's, quoted where each is used. What differs, and why: upstream hands each
/// piece a hue from an OKLCH ramp of the body's own colour (`render.ts` `ribbonPalette`); here a
/// ribbon is a gradient of the body's colour mixed toward white at its tail and toward black at its
/// head, which is the same "lighter and warmer, or darker and cooler" read in sRGB instead of OKLCH.
/// And the rim of a body is found by testing every edge of the outline against the direction asked
/// for, rather than through upstream's fan index — the same answer, without the index.
public enum OpenBotAvatarRibbons {

    // MARK: - One piece

    /// One piece of a ribbon: the part of it in front of the body, or the part behind.
    public struct Piece {
        public var path: Path
        /// Bounds of the piece in viewBox units.
        public var box: CGRect
        public var front: Bool
        /// Which ribbon the piece belongs to: 0…8 in a celebration (hoop `ribbon / lanes`, lane
        /// `ribbon % lanes` from the inner ring out), 0…4 in a working turn.
        public var ribbon: Int
        /// The stretch of its ribbon the piece covers, 0 (tail) to 1 (head) …
        public var along: (Double, Double)
        /// … and the centre of the ribbon at either end of that stretch, for a gradient along it.
        public var from: CGPoint
        public var to: CGPoint

        public init(path: Path, box: CGRect, front: Bool, ribbon: Int,
                    along: (Double, Double), from: CGPoint, to: CGPoint) {
            self.path = path
            self.box = box
            self.front = front
            self.ribbon = ribbon
            self.along = along
            self.from = from
            self.to = to
        }
    }

    // MARK: - The hoop measurements

    /// The demo's own unit space, and the typical body across its larger side (the median of the
    /// starters and gallery). `effects.ts:59-62`.
    static let design = 228.541
    static let body = 80.0
    static let unit = body / design

    /// A hoop's inner ring stands this far outside the body along the hoop's own direction.
    /// `effects.ts:69`.
    static let rimMargin = 2.0
    /// The typical body's half-width, × 116/114.2705, for a caller that gives no outline.
    /// `effects.ts:70`.
    static let ring = 38.8 * (116 / 114.2705)

    /// A hoop is a ring of this radius tipped `hoopTilt` out of the screen and rolled in the picture.
    /// `effects.ts:159-162`.
    static let hoopTilt = 0.386
    static let hoopRoll = 0.157
    static let hoopJitter = 0.24
    /// The ribbons on one hoop share its roll and tilt exactly, so which of them lies on top never
    /// flips where they pass behind the body. `effects.ts:168`.
    static let hoopTiltJitter = 0.08

    /// A hoop's rings are `ladder` apart, in design units. `effects.ts:169`.
    static let ladder = 38.0
    /// How far behind its head a ribbon's tail trails, radians. `effects.ts:170`.
    static let arc: (Double, Double) = (2.2, 3.4)
    /// Each ribbon's share of the body's turn. `effects.ts:171`.
    static let follow: (Double, Double) = (0.74, 0.94)
    /// Radians per second a ribbon drifts on by itself, and design units per second its ring widens.
    /// `effects.ts:173-174`.
    static let drift: (Double, Double) = (0.5, 1.1)
    static let widen = 2.5
    /// How far behind the turn a ribbon starts, at most, radians. `effects.ts:176`.
    static let start = 0.18

    /// A ribbon's width: a size per ribbon in design units (wider when there are only three, narrower
    /// among nine), times `brush`; never wider than a third of its own length on screen, and it runs
    /// from half that width at its tail to the full width at its head. `effects.ts:183-191`.
    static let sizeFew: (Double, Double) = (8, 10.5)
    static let sizeFour: (Double, Double) = (6.6, 8.6)
    static let sizeMany: (Double, Double) = (5.6, 7.4)
    static let brush = 1.7 * 1.98
    static let far = 0.72
    static let growSeconds = 0.34

    /// A working turn's lanes, per avatar. `effects.ts:187`.
    static let workLanes: (Double, Double) = (3, 5)
    static func sizeFor(_ count: Int) -> (Double, Double) {
        count <= 3 ? sizeFew : count == 4 ? sizeFour : sizeMany
    }

    /// The ribbons on a turn are let out one after another, this long apart (seconds).
    /// `effects.ts:193`.
    static let stagger: (Double, Double) = (0.055, 0.105)

    /// How fast the sweep goes on average, radians per second. `effects.ts:198-200`.
    static let sweepRate: (Double, Double) = (6.3, 15)
    static let sweepLongest = 4.0

    /// Three ribbons to a hoop, three hoops to a cage: nine in a celebration. `effects.ts:201-202`.
    public static let lanes = 3
    public static let hoops = 3

    /// A ribbon is cut into stretches this many samples long, each with a gradient of its own.
    /// `effects.ts:203-209`.
    static let samples = 24
    static let stretch = 6
    static let sliver = 0.02
    static let capPoints = 7

    static func mix(_ range: (Double, Double), _ u: Double) -> Double {
        range.0 + (range.1 - range.0) * u
    }

    static func clamp(_ value: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, value)) }

    static func smooth(_ u: Double) -> Double {
        let x = clamp(u, 0, 1)
        return x * x * (3 - 2 * x)
    }

    // MARK: - Rim

    /// Where a body's hoops are centred, and how far the body reaches from there.
    public struct Rim {
        public var cx: Double
        public var cy: Double
        /// How far the outline reaches from the centre along a direction (radians), either way.
        public var at: (Double) -> Double
        /// The farthest over all directions.
        public var reach: Double
    }

    /// How far `polygons` reach from (cx, cy) along a direction, either way, exactly: the farthest
    /// crossing of a line through the centre with any edge. `effects.ts:91`.
    static func reachFinder(_ polygons: [[OpenBotAvatarGeometry.Point]],
                            cx: Double,
                            cy: Double) -> (Double) -> Double {
        let edges = polygons.flatMap { polygon in
            polygon.indices.map { index in
                let p = polygon[index], q = polygon[(index + 1) % polygon.count]
                return (p, q)
            }
        }
        return { angle in
            let ux = cos(angle), uy = sin(angle)
            var far = 0.0
            for (p, q) in edges {
                let ex = q.x - p.x, ey = q.y - p.y
                let den = ux * ey - uy * ex
                if abs(den) < 1e-12 { continue }
                // Where the line through the centre crosses this edge: t along the line, s along it.
                let t = ((p.x - cx) * ey - (p.y - cy) * ex) / den
                let s = ((p.x - cx) * uy - (p.y - cy) * ux) / den
                if s >= 0, s <= 1 { far = max(far, abs(t)) }
            }
            return far
        }
    }

    /// Steps a half turn is cut into to find the farthest reach. `effects.ts:77`.
    static let rimSteps = 180

    public static func rim(of polygons: [[OpenBotAvatarGeometry.Point]],
                           cx: Double,
                           cy: Double) -> Rim {
        let at = reachFinder(polygons, cx: cx, cy: cy)
        var farthest = 0.0
        for step in 0..<rimSteps { farthest = max(farthest, at(Double(step) * .pi / Double(rimSteps))) }
        // A spike between two samples can reach a little further than either: allow for a degree's
        // sweep. `effects.ts:155-157`.
        return Rim(cx: cx, cy: cy, at: at, reach: farthest * 1.02)
    }

    /// How each hoop is rolled in the picture, for an avatar's seed: hoop 0 is a working turn's.
    /// `effects.ts:142`.
    static func hoopRolls(_ seed: UInt32) -> [Double] {
        (0..<hoops).map { index in
            hoopRoll + Double(index) * .pi / Double(hoops)
                + (OpenBotAvatarState.noise(seed, 450 + index) - 0.5) * hoopJitter
        }
    }

    /// How far the body reaches from the middle of its box, for a working turn's hoop and for a
    /// celebration's cage. The hoops' centre hops and stretches with the body but does not lean or
    /// sway with it, so each is measured over the leans its state takes: a working bot leans 2.4° to
    /// 6.6° and squashes to 98 %; a celebrating one sways ±1.7° and stretches up to 5.5 %.
    /// `render.ts` `ribbonRims`.
    public static func rims(polygons: [[OpenBotAvatarGeometry.Point]],
                            box: OpenBotAvatarGeometry.Box) -> (work: Rim, cage: Rim) {
        let centre = box.center
        let bx = (box.minX + box.maxX) / 2, by = box.maxY
        func posed(_ rolls: [Double], _ stretches: [Double]) -> [[OpenBotAvatarGeometry.Point]] {
            var out: [[OpenBotAvatarGeometry.Point]] = []
            for roll in rolls {
                let r = roll * .pi / 180, c = cos(r), s = sin(r)
                for k in stretches {
                    out.append(contentsOf: polygons.map { polygon in
                        polygon.map { point in
                            let lx = bx + c * (point.x - bx) - s * (point.y - by)
                            let ly = by + s * (point.x - bx) + c * (point.y - by)
                            return OpenBotAvatarGeometry.Point(centre.x + 1.01 * (lx - centre.x),
                                                               centre.y + k * (ly - centre.y))
                        }
                    })
                }
            }
            return out
        }
        return (rim(of: posed([2.4, 4.5, 6.6], [0.98, 1]), cx: centre.x, cy: centre.y),
                rim(of: posed([-1.7, 0, 1.7], [0.99, 1.055]), cx: centre.x, cy: centre.y))
    }

    /// The rim moved to where the hoops' centre is in this pose: it hops and stretches with the body
    /// (the root motion's lift and scale about the base) but does not lean or sway with it.
    /// `render.ts` `ribbonsFollow`.
    public static func follow(_ rim: Rim,
                              lift: Double,
                              sx: Double,
                              sy: Double,
                              box: OpenBotAvatarGeometry.Box) -> Rim {
        let bx = (box.minX + box.maxX) / 2, by = box.maxY
        return Rim(cx: bx + sx * (rim.cx - bx),
                   cy: by + sy * (rim.cy - by) + lift,
                   at: rim.at,
                   reach: rim.reach)
    }

    /// The radius of the farthest ring a ribbon can ride round a body whose outline reaches `rimMax`
    /// from its centre at most, the widest a ribbon gets, and how far a ribbon reaches out from its
    /// ring (half that). `effects.ts:218`.
    public static func reach(rimMax: Double? = nil) -> (radius: Double, width: Double, band: Double) {
        let width = sizeFew.1 * brush * unit
        let ring = rimMax.map { $0 + rimMargin } ?? Self.ring
        return (ring + (ladder + widen * sweepLongest) * unit, width, width / 2)
    }

    // MARK: - The ribbons at one moment

    /// The ribbons at one moment, as filled outlines. `presence` 0…1 draws them out and back in.
    /// `cage` picks the layout: a working turn's three to five ribbons on one hoop (below 0.5), or a
    /// celebration's three on each of three hoops. `sweep` (radians, signed) is how far the body's
    /// turn has carried them; between turns they are not drawn. `effects.ts:237`.
    public static func pieces(box: OpenBotAvatarGeometry.Box,
                              presence: Double,
                              seed: UInt32,
                              sweep: Double = 0,
                              cage: Double = 0,
                              rim: Rim? = nil) -> [Piece] {
        let k = clamp(presence, 0, 1)
        let more = cage >= 0.5 ? 1.0 : 0.0
        if k <= 0.01 { return [] }
        let cx = rim?.cx ?? (box.minX + box.maxX) / 2
        let cy = rim?.cy ?? (box.minY + box.maxY) / 2
        let rolls = hoopRolls(seed)
        func rollOf(_ index: Int) -> Double { rolls[index] }
        let cageRing = rim.map { r in
            (0..<hoops).map { r.at(rollOf($0)) }.max().map { $0 + rimMargin } ?? ring
        } ?? ring
        let dir = sweep < 0 ? -1.0 : 1.0
        // How long the sweep has been going, from how far it has got.
        let since = abs(sweep) / mix(sweepRate, more)
        var pieces: [Piece] = []
        let hoopCount = more > 0 ? hoops : 1
        for i in 0..<hoopCount {
            let hoopRoll = rollOf(i)
            let hoopTilt = self.hoopTilt + (OpenBotAvatarState.noise(seed, 460 + i) - 0.5) * hoopTiltJitter
            let ring = more > 0 ? cageRing : (rim.map { $0.at(hoopRoll) + rimMargin } ?? Self.ring)
            let lanes = (i != 0 || more > 0)
                ? self.lanes
                : Int(mix(workLanes, OpenBotAvatarState.noise(seed, 47)).rounded())
            guard lanes > 1 else { continue }
            for l in 0..<lanes {
                func n(_ m: Int) -> Double {
                    OpenBotAvatarState.noise(seed, 500 + (i * self.lanes + l) * 11 + m)
                }
                // Let out in turn, lane by lane across the hoops: how long ago this one was, and how
                // far the turn had got by then.
                let order = more > 0 ? Double(l * hoops + i) : Double(l)
                let at = order * mix(stagger, n(7))
                let life = since - at
                if life <= 0 { continue }
                let before = since > 0 ? abs(sweep) * (at / since) : 0
                let roll = hoopRoll
                let tilt = hoopTilt
                let flat = sin(tilt), depth = cos(tilt)
                let cr = cos(roll), sr = sin(roll)
                let r = ring + (Double(l) * ladder * unit) / Double(lanes - 1)
                    + mix((0, widen), n(2)) * unit * life
                // The orbit angle (0 = the top of the hoop) of the head: it starts where the turn was
                // when it was let out, a little behind, and goes its own share of the rest. Its tail
                // trails it as far as it has gone, up to its arc; drawing back in shortens and thins it.
                let travel = (abs(sweep) - before) * mix(follow, n(3)) + mix(drift, n(4)) * life
                let head = dir * (before + travel - start * n(5))
                let ret = 1 - clamp(k * 1.25, 0, 1)
                let length = min(mix(arc, n(6)), travel) * (1 - ret * ret * (3 - 2 * ret))
                if length <= 0.02 { continue }
                let size = mix(sizeFor(lanes), n(8)) * (1 - more) + mix(sizeMany, n(8)) * more
                let nearHead = clamp(cos(head) * depth, 0, 1)
                var full = size * brush * unit * (far + (1 - far) * nearHead)
                    * smooth(life / growSeconds) * (1 - 0.72 * ret * ret)
                // A point of the ribbon is in front of the body on the near half of its hoop.
                func lamAt(_ u: Double) -> Double { head - dir * length * (1 - u) }
                func point(_ lam: Double) -> CGPoint {
                    let a = sin(lam), y = -cos(lam) * flat
                    return CGPoint(x: cx + r * (a * cr - y * sr), y: cy + r * (a * sr + y * cr))
                }
                // Where along the ribbon (0 tail … 1 head) to sample it: evenly, plus exactly where it
                // passes from one layer to the other (the hoop's sides, where its depth is 0) and a
                // sliver either side, so every ribbon on a hoop changes layer along the same line.
                func along(_ lam: Double) -> Double { 1 - (head - lam) / (dir * length) }
                let sliver = self.sliver / length
                var ss: [Double] = (0...samples).map { Double($0) / Double(samples) }
                let lo = min(head, head - dir * length), hi = max(head, head - dir * length)
                guard lo.isFinite, hi.isFinite else { continue }
                var side = Int(((lo - .pi / 2) / .pi).rounded(.up))
                while .pi / 2 + Double(side) * .pi < hi {
                    let u = along(.pi / 2 + Double(side) * .pi)
                    for d in [-sliver, 0, sliver] where u + d > 0 && u + d < 1 { ss.append(u + d) }
                    side += 1
                }
                ss.sort()
                // A sample exactly on a side belongs with the stretch after it.
                let near = ss.map { cos(lamAt($0) + dir * 1e-6) > 0 }
                // Centre, half width, unit normal (on screen) and bend at each sample, tail to head.
                var mid: [CGPoint] = [], halfs: [Double] = [], norm: [CGPoint] = [], bend: [Double] = []
                for u in ss {
                    let lam = lamAt(u)
                    // On the hoop before its roll: the ellipse's normal.
                    let nx = sin(lam) * flat, ny = -cos(lam)
                    let nl = (nx * nx + ny * ny).squareRoot()
                    let ux = nx / (nl == 0 ? 1 : nl), uy = ny / (nl == 0 ? 1 : nl)
                    mid.append(point(lam))
                    norm.append(CGPoint(x: ux * cr - uy * sr, y: ux * sr + uy * cr))
                    halfs.append(0.5 + 0.5 * u)
                    // How tightly the hoop curves here, as a radius: a ribbon wider than it would fold.
                    let c = cos(lam), sn = sin(lam)
                    let spread = c * c + flat * flat * sn * sn
                    bend.append(flat == 0 ? .infinity : (r * pow(spread, 1.5)) / flat)
                }
                let last = ss.count - 1
                guard last > 0 else { continue }
                // Never wider than a third of its own length on screen.
                var onScreen = 0.0
                for j in 1...last {
                    onScreen += (pow(mid[j].x - mid[j - 1].x, 2) + pow(mid[j].y - mid[j - 1].y, 2)).squareRoot()
                }
                full = min(full, 0.34 * onScreen)
                for j in 0...last { halfs[j] = min(halfs[j] * (full / 2), 0.9 * bend[j]) }
                func sidePoint(_ j: Int, _ sign: Double) -> CGPoint {
                    CGPoint(x: mid[j].x + sign * norm[j].x * halfs[j],
                            y: mid[j].y + sign * norm[j].y * halfs[j])
                }
                // A half circle round an end, from one edge to the other through the point ahead of it
                // (or behind).
                func cap(_ j: Int, ahead: Bool) -> [CGPoint] {
                    let o = ahead ? mid[j - 1] : mid[j + 1]
                    var tx = ahead ? mid[j].x - o.x : o.x - mid[j].x
                    var ty = ahead ? mid[j].y - o.y : o.y - mid[j].y
                    let tl = (tx * tx + ty * ty).squareRoot()
                    tx /= tl == 0 ? 1 : tl
                    ty /= tl == 0 ? 1 : tl
                    let nx = norm[j].x, ny = norm[j].y, h = halfs[j]
                    return (1..<capPoints).map { c in
                        let t = Double.pi * Double(c) / Double(capPoints)
                        // Ahead: from the + edge forward round to the - edge; behind: the other way.
                        let e = ahead ? cos(t) : -cos(t), g = ahead ? sin(t) : -sin(t)
                        return CGPoint(x: mid[j].x + (nx * e + tx * g) * h,
                                       y: mid[j].y + (ny * e + ty * g) * h)
                    }
                }
                // Runs of samples on one side, and at most a stretch long, each become a piece. Pieces
                // overlap by a sample where they meet, the one drawn first running on under the other.
                var from = 0
                var j = 1
                while j <= last {
                    let turns = j < last && near[j] != near[from]
                    if j < last && !turns && j - from < stretch {
                        j += 1
                        continue
                    }
                    let to = j
                    let behind = !near[from]
                    let end = to < last && (!turns || behind) ? to + 1 : to
                    let startIndex = from > 0 && behind && near[from - 1] ? from - 1 : from
                    var pts: [CGPoint] = []
                    if startIndex <= end {
                        for q in startIndex...end { pts.append(sidePoint(q, 1)) }
                    }
                    if end == last { pts.append(contentsOf: cap(last, ahead: true)) }
                    var q = end
                    while q >= startIndex {
                        pts.append(sidePoint(q, -1))
                        q -= 1
                    }
                    if startIndex == 0 { pts.append(contentsOf: cap(0, ahead: false)) }
                    if pts.count > 2 {
                        let xs = pts.map { $0.x }, ys = pts.map { $0.y }
                        let x0 = xs.min() ?? 0, y0 = ys.min() ?? 0
                        var path = Path()
                        path.move(to: pts[0])
                        for index in 1..<pts.count { path.addLine(to: pts[index]) }
                        path.closeSubpath()
                        pieces.append(Piece(path: path,
                                            box: CGRect(x: x0, y: y0,
                                                        width: (xs.max() ?? 0) - x0,
                                                        height: (ys.max() ?? 0) - y0),
                                            front: near[from],
                                            ribbon: i * lanes + l,
                                            along: (ss[from], ss[to]),
                                            from: mid[from],
                                            to: mid[to]))
                    }
                    from = j
                    j += 1
                }
            }
        }
        return pieces
    }
}
