import Foundation

/// The corner-softening step: one transform, applied when a **preset** is loaded, and never to a
/// definition a person pasted.
///
/// ## Why it exists
///
/// The twelve starting shapes in `OpenBotAvatarPresets` are authored as plain SVG paths — a box is
/// four right angles, a star is ten hard points, an hourglass is ten knife edges. That is the right
/// way to *author* a silhouette (it is legible, it is reproducible, and it is the same text a person
/// can paste into <https://github.com/DominikScholz/open-bot-avatar>), but it is not the right way to
/// *draw* one: at 26 pt a right angle reads as a corner, and the contract asks for "recognizable,
/// soft, minimal object silhouettes". So the authored path stays in source and one transform walks
/// it once, on the way out of the preset table.
///
/// ## What it does, geometrically
///
/// 1. `OpenBotAvatarGeometry.parse` reads the path; the subpaths are flattened into polygons (the
///    same polygons the volume is inferred from — one reading of the artwork, not two).
/// 2. Every vertex whose outline turns by more than `cornerTurn` is cut: the two edges are walked
///    back by `t = r / tan(θ/2)` (`θ` the interior angle) and the gap is bridged by a **circular
///    arc**, emitted as a cubic with SVG's own `k = 4/3 · tan(φ/4)` (the same approximation
///    `OpenBotAvatarGeometry` uses for an `A` command). The arc is tangent to both edges, so there
///    is no new kink where the fillet meets the line.
/// 3. The radius is one number for every shape: `cornerFraction` (5%) of the shape's **longer**
///    side. Nothing is tuned per preset — a new preset gets the same proportion.
///
/// Cutting a convex corner removes a sliver of the body; cutting a concave one (a star's notch, an
/// hourglass's waist) rounds the bay and adds a sliver. Both are "softer", and both move the outline
/// by exactly `r / sin(θ/2) - r` — 1.4 radii at the sharpest corner in the twelve (the star's 49°
/// points), under a radius anywhere else.
///
/// The walk-back is bounded by `edgeShare` of the two edges it sits on, so a corner whose neighbour
/// is a curve — the droplet's tip, the sprout's leaf — keeps most of its point: a fillet may not
/// straighten the curve that begins there. (Drop the bound and the outline folds through itself,
/// which is what `test_no_softened_outline_crosses_itself` catches.)
///
/// ## Deliberately not Chaikin
///
/// Chaikin is the usual "smooth a polygon" answer and it is the wrong tool here: it subdivides
/// *every* edge, so it does not round a corner — it shrinks the whole outline toward its own
/// centroid, and it does that most where the feature is smallest. On the star it would cut all ten
/// points by a quarter of each adjacent edge and fill all five notches, on every pass, so the five
/// points retreat and the star becomes a rounded ten-gon; on the bottle it would thin the neck and
/// the cap. A fillet only moves the vertices that actually turn: a straight run keeps its ends, and
/// a curve is left alone (re-emitted as its own flattening, a chord under 0.1 units, only in a
/// subpath that had a corner to cut). Its cut is analytic (`r / sin(θ/2) - r` deep) rather than
/// emergent, so what it did to a shape can be stated. The only existing smoothing in this codebase
/// — `OpenBotAvatarGeometry.contours` — uses one Chaikin pass, and it is there for the opposite
/// job: a 0.5-unit marching-squares staircase that has no vertices worth keeping.
///
/// ## Cost
///
/// One parse, one flatten and one pass per path, cached by the path string (`PathCache`, bounded like
/// `OpenBotAvatarModel`'s). The preset table is twelve paths, softened once per process. The result
/// is idempotent: a softened path has no vertex that turns more than `cornerTurn` (the arcs carry
/// their turn in fourteen small steps), so rounding it again returns it unchanged — which is what
/// makes it safe that a softened preset is what the editor *stores*.
///
/// ## What it must never touch
///
/// A definition a person brings — pasted JSON (`BotAvatarDefinition.decode`), a draft in the editor,
/// a stored avatar — is their geometry. Nothing in the load path calls this: the only caller is
/// `OpenBotAvatarPresets.all`, on the app's own twelve. If a preset is already soft (the blob and the
/// egg are all Bézier), the transform finds no corner at all and returns the authored string
/// byte for byte.
public enum OpenBotAvatarSoften {

    /// The fillet radius as a share of the shape's longer side. 5%, the middle of the 4–6% the
    /// artwork asks for: at 26 pt it reads as a soft edge, and on the star it is a 5.3-unit cut at
    /// each of the five points — rounded, but still five points.
    public static let cornerFraction = 0.05

    /// A corner is a vertex whose outline turns by more than this, in radians (20°). Flattened curve
    /// steps turn by a fraction of that — a quarter circle in fourteen steps turns 6.4° each — so an
    /// authored curve is never mistaken for a corner.
    public static let cornerTurn = 0.35

    /// No cut may take more than this share of either edge it sits on, so two neighbouring fillets
    /// can never meet and a cut can never run past the curve that begins at the corner. (Half each
    /// would be exactly touching; 45% leaves a gap even after two decimals of rounding.)
    static let edgeShare = 0.45

    /// Two decimals is 1/5000 of the box, well under a pixel at any drawn size, and keeps a
    /// twelve-shape table small (the longest softened path is about 1.4 kB).
    static let precision = 100.0

    static let cacheLimit = 64

    // MARK: - Entry points

    /// A definition with its body path softened — id and eyes untouched, because the transform only
    /// moves the outline and the eyes were placed against a body whose interior it does not change
    /// by more than a fillet's width.
    public static func softened(_ definition: BotAvatarDefinition) -> BotAvatarDefinition {
        let path = softenedPath(definition.body.path)
        guard path != definition.body.path else { return definition }
        return BotAvatarDefinition(version: definition.version,
                                   id: definition.id,
                                   name: definition.name,
                                   body: .init(path: path),
                                   eyes: definition.eyes)
    }

    /// A path with every sharp corner cut, or the path itself when it has none (or cannot be read —
    /// the validator is the thing that reports a bad path, never this).
    public static func softenedPath(_ path: String) -> String {
        if let hit = cache.value(for: path) { return hit }
        let result = soften(path)
        cache.insert(result, for: path)
        return result
    }

    // MARK: - The transform

    static func soften(_ path: String) -> String {
        guard let segments = try? OpenBotAvatarGeometry.parse(path) else { return path }
        let subpaths = split(segments)
        let polygons = subpaths.map { OpenBotAvatarGeometry.polygons($0).first ?? [] }
        let points = polygons.flatMap { $0 }
        guard !points.isEmpty else { return path }
        let box = OpenBotAvatarGeometry.Box(points)
        let radius = cornerFraction * Swift.max(box.width, box.height)
        guard radius > 0 else { return path }

        var parts: [String] = []
        var changed = false
        for (index, subpath) in subpaths.enumerated() {
            let result = soften(polygon: polygons[index], radius: radius)
            if result.corners > 0, !result.segments.isEmpty {
                parts.append(emit(result.segments))
                changed = true
            } else {
                // Nothing to cut in this subpath: keep its own commands, curve for curve.
                parts.append(emit(subpath))
            }
        }
        guard changed else { return path }
        return parts.joined(separator: " ")
    }

    /// The path's segments grouped into subpaths, each starting at its own `M`.
    static func split(_ segments: [OpenBotAvatarGeometry.Segment]) -> [[OpenBotAvatarGeometry.Segment]] {
        var result: [[OpenBotAvatarGeometry.Segment]] = []
        var current: [OpenBotAvatarGeometry.Segment] = []
        for segment in segments {
            if case .move(_) = segment, !current.isEmpty {
                result.append(current)
                current = []
            }
            current.append(segment)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// What one vertex becomes: kept as it is, or replaced by a line-in, an arc and a line-out.
    enum Corner {
        case keep(OpenBotAvatarGeometry.Point)
        /// The two tangency points and the arc's two cubic controls.
        case cut(start: OpenBotAvatarGeometry.Point, control1: OpenBotAvatarGeometry.Point,
                 control2: OpenBotAvatarGeometry.Point, end: OpenBotAvatarGeometry.Point)
    }

    /// Cut every corner of one closed polygon sharper than `cornerTurn`, and count them.
    static func soften(polygon: [OpenBotAvatarGeometry.Point], radius: Double)
        -> (segments: [OpenBotAvatarGeometry.Segment], corners: Int) {
        let vertices = cleaned(polygon)
        let count = vertices.count
        guard count >= 3, radius > 0 else { return ([], 0) }

        var corners: [Corner] = []
        var cuts = 0
        corners.reserveCapacity(count)
        for index in 0..<count {
            let previous = vertices[(index + count - 1) % count]
            let vertex = vertices[index]
            let next = vertices[(index + 1) % count]
            if let cut = fillet(previous: previous, vertex: vertex, next: next, radius: radius) {
                corners.append(cut)
                cuts += 1
            } else {
                corners.append(.keep(vertex))
            }
        }
        guard cuts > 0, let first = corners.first else { return ([], 0) }

        // The path starts at the first corner's tangency point and draws that corner's arc at once,
        // so the closing edge is the plain remainder of the edge between the last vertex and this
        // one — never a chord across a fillet.
        var segments: [OpenBotAvatarGeometry.Segment] = []
        switch first {
        case .keep(let point):
            segments.append(.move(point))
        case .cut(let start, let control1, let control2, let end):
            segments.append(.move(start))
            segments.append(.cubic(control1: control1, control2: control2, to: end))
        }
        for corner in corners.dropFirst() {
            switch corner {
            case .keep(let point):
                segments.append(.line(point))
            case .cut(let start, let control1, let control2, let end):
                segments.append(.line(start))
                segments.append(.cubic(control1: control1, control2: control2, to: end))
            }
        }
        segments.append(.close)
        return (segments, cuts)
    }

    /// The outline's turn at a vertex, in radians: 0 on a straight run, `π/2` at a square corner,
    /// close to `π` where the outline doubles back on itself.
    static func turn(at vertex: OpenBotAvatarGeometry.Point,
                     from previous: OpenBotAvatarGeometry.Point,
                     to next: OpenBotAvatarGeometry.Point) -> Double {
        let incoming = OpenBotAvatarGeometry.Point(previous.x - vertex.x, previous.y - vertex.y)
        let outgoing = OpenBotAvatarGeometry.Point(next.x - vertex.x, next.y - vertex.y)
        let lengths = ((incoming.x * incoming.x + incoming.y * incoming.y)
                       * (outgoing.x * outgoing.x + outgoing.y * outgoing.y)).squareRoot()
        guard lengths > 1e-12 else { return 0 }  // a zero-length edge has no direction to turn from
        let cosine = (incoming.x * outgoing.x + incoming.y * outgoing.y) / lengths
        return Double.pi - acos(Swift.max(-1, Swift.min(1, cosine)))
    }

    /// The circular fillet at one vertex, or nil when the vertex does not turn enough to need one.
    static func fillet(previous: OpenBotAvatarGeometry.Point,
                       vertex: OpenBotAvatarGeometry.Point,
                       next: OpenBotAvatarGeometry.Point,
                       radius: Double) -> Corner? {
        let (inward, intoLength) = direction(from: vertex, to: previous)
        let (outward, outLength) = direction(from: vertex, to: next)
        guard intoLength > 1e-9, outLength > 1e-9 else { return nil }
        guard turn(at: vertex, from: previous, to: next) >= cornerTurn else { return nil }

        let cosine = Swift.max(-1, Swift.min(1, inward.x * outward.x + inward.y * outward.y))
        let interior = acos(cosine)
        let half = interior / 2
        let sine = sin(half)
        let tangentOfHalf = tan(half)
        guard sine > 1e-6, tangentOfHalf > 1e-9 else { return nil }

        // Walk back from the vertex along both edges: far enough for a circle of `radius` to sit
        // tangent to both, and never past `edgeShare` of either edge. That second bound is what
        // keeps two neighbouring cuts apart — and it is also what stops a cut from running past
        // the first step of a curve that starts right at the corner: a fillet may not straighten
        // the curve that follows it (try it without the bound and the outline folds through
        // itself, which is what `test_no_softened_outline_crosses_itself` catches).
        let tangent = Swift.min(radius / tangentOfHalf,
                                Swift.min(edgeShare * intoLength, edgeShare * outLength))
        guard tangent > 1e-6 else { return nil }
        // The arc's own radius, which is `radius` unless an edge clamped the walk-back.
        let filletRadius = tangent * tangentOfHalf
        guard filletRadius > 1e-9 else { return nil }

        let start = OpenBotAvatarGeometry.Point(vertex.x + inward.x * tangent,
                                                vertex.y + inward.y * tangent)
        let end = OpenBotAvatarGeometry.Point(vertex.x + outward.x * tangent,
                                              vertex.y + outward.y * tangent)

        // The centre sits on the interior bisector, `r / sin(θ/2)` from the vertex.
        let bisectorLength = ((inward.x + outward.x) * (inward.x + outward.x)
                              + (inward.y + outward.y) * (inward.y + outward.y)).squareRoot()
        guard bisectorLength > 1e-9 else { return nil }
        let bisector = OpenBotAvatarGeometry.Point((inward.x + outward.x) / bisectorLength,
                                                   (inward.y + outward.y) / bisectorLength)
        let distance = filletRadius / sine
        let centre = OpenBotAvatarGeometry.Point(vertex.x + bisector.x * distance,
                                                 vertex.y + bisector.y * distance)

        // The arc, as a cubic: SVG's `k = 4/3 · tan(φ/4)` for a sweep of `π - θ`. The tangent at
        // each end is perpendicular to its own radius, in the direction that reaches the other end.
        let sweep = Double.pi - interior
        let k = (4.0 / 3.0) * tan(sweep / 4)
        let normal1 = OpenBotAvatarGeometry.Point((start.x - centre.x) / filletRadius,
                                                  (start.y - centre.y) / filletRadius)
        let perpendicular1 = OpenBotAvatarGeometry.Point(-normal1.y, normal1.x)
        let cross = perpendicular1.x * (end.x - centre.x) + perpendicular1.y * (end.y - centre.y)
        let side: Double = cross > 0 ? 1 : -1
        let control1 = OpenBotAvatarGeometry.Point(start.x + side * perpendicular1.x * k * filletRadius,
                                                   start.y + side * perpendicular1.y * k * filletRadius)
        let normal2 = OpenBotAvatarGeometry.Point((end.x - centre.x) / filletRadius,
                                                  (end.y - centre.y) / filletRadius)
        let perpendicular2 = OpenBotAvatarGeometry.Point(-normal2.y, normal2.x)
        let control2 = OpenBotAvatarGeometry.Point(end.x - side * perpendicular2.x * k * filletRadius,
                                                   end.y - side * perpendicular2.y * k * filletRadius)
        return .cut(start: start, control1: control1, control2: control2, end: end)
    }

    /// The polygon without repeated points (and without a closing point that repeats the first):
    /// a zero-length edge has no direction, and a fillet needs two.
    static func cleaned(_ polygon: [OpenBotAvatarGeometry.Point]) -> [OpenBotAvatarGeometry.Point] {
        var vertices: [OpenBotAvatarGeometry.Point] = []
        for point in polygon {
            if let last = vertices.last, last.distance(to: point) <= 1e-6 { continue }
            vertices.append(point)
        }
        if vertices.count > 2, let first = vertices.first, let last = vertices.last,
           first.distance(to: last) <= 1e-6 {
            vertices.removeLast()
        }
        return vertices
    }

    static func direction(from origin: OpenBotAvatarGeometry.Point, to target: OpenBotAvatarGeometry.Point)
        -> (OpenBotAvatarGeometry.Point, Double) {
        let dx = target.x - origin.x, dy = target.y - origin.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return (.zero, 0) }
        return (OpenBotAvatarGeometry.Point(dx / length, dy / length), length)
    }

    // MARK: - Writing the path back

    static func emit(_ segments: [OpenBotAvatarGeometry.Segment]) -> String {
        var parts: [String] = []
        parts.reserveCapacity(segments.count)
        for segment in segments {
            switch segment {
            case .move(let point):
                parts.append("M\(number(point.x)) \(number(point.y))")
            case .line(let point):
                parts.append("L\(number(point.x)) \(number(point.y))")
            case .quad(let control, let point):
                parts.append("Q\(number(control.x)) \(number(control.y)) \(number(point.x)) \(number(point.y))")
            case .cubic(let control1, let control2, let point):
                parts.append("C\(number(control1.x)) \(number(control1.y)) "
                             + "\(number(control2.x)) \(number(control2.y)) "
                             + "\(number(point.x)) \(number(point.y))")
            case .close:
                parts.append("Z")
            }
        }
        return parts.joined(separator: " ")
    }

    /// Two decimals, trailing zeros dropped, never a locale's decimal comma — the string is geometry
    /// and has to read the same on every machine.
    static func number(_ value: Double) -> String {
        let hundredths = Int((value * precision).rounded())
        let sign = hundredths < 0 ? "-" : ""
        let magnitude = abs(hundredths)
        let whole = magnitude / 100
        let fraction = magnitude % 100
        if fraction == 0 { return sign + String(whole) }
        let text = fraction % 10 == 0 ? String(fraction / 10)
            : (fraction < 10 ? "0\(fraction)" : String(fraction))
        return sign + String(whole) + "." + text
    }

    // MARK: - Cache

    /// Path string in, path string out, one lock — the same shape as `OpenBotAvatarModel`'s cache and
    /// for the same reason: a view is built on the main thread but a definition can be validated
    /// anywhere, and the transform is a pure function of its key.
    private final class PathCache {
        private let lock = NSLock()
        private var storage: [String: String] = [:]

        func value(for key: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return storage[key]
        }

        func insert(_ value: String, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            if storage.count >= OpenBotAvatarSoften.cacheLimit { storage.removeAll(keepingCapacity: true) }
            storage[key] = value
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage.count
        }
    }

    private static let cache = PathCache()

    /// How many paths have been softened in this process (twelve at most, for the presets).
    public static var cachedCount: Int { cache.count }
}
