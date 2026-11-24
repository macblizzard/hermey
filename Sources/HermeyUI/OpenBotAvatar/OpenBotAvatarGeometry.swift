import Foundation

/// The geometry behind `OpenBotAvatar`: a path parser, the polygon and distance-field maths that
/// infers a volume from an outline, and the cross-section contours that volume is drawn from.
///
/// Everything here is plain `Double` arithmetic in the definition's own `0 0 100 100` space. No
/// SwiftUI, no CoreGraphics: the drawing layer is the only thing that knows about pixels, and these
/// functions can be checked by a test without a screen.
///
/// The maths is a port of upstream `packages/core/src/path.ts`, `validate.ts`, `volume.ts` and
/// `render.ts` (MIT). What is deliberately *not* here is upstream's full generality: no `revolve-x`
/// solids of revolution, no thin-region refinement slices, no x-stack planes. Every part of a
/// definition is inflated from its own outline, which is the model a silhouette needs — see
/// `OpenBotAvatarVolume` for the list of simplifications and why each is faithful enough.
public enum OpenBotAvatarGeometry {

    // MARK: - Points and rectangles

    public struct Point: Hashable, Sendable {
        public var x: Double
        public var y: Double
        public init(_ x: Double, _ y: Double) {
            self.x = x
            self.y = y
        }
        public static let zero = Point(0, 0)
        public func distance(to other: Point) -> Double {
            ((x - other.x) * (x - other.x) + (y - other.y) * (y - other.y)).squareRoot()
        }
    }

    /// An axis-aligned box in definition space.
    public struct Box: Hashable, Sendable {
        public var minX: Double
        public var minY: Double
        public var maxX: Double
        public var maxY: Double
        public var width: Double { maxX - minX }
        public var height: Double { maxY - minY }
        public var center: Point { Point((minX + maxX) / 2, (minY + maxY) / 2) }

        public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
            self.minX = minX
            self.minY = minY
            self.maxX = maxX
            self.maxY = maxY
        }

        public init(_ points: [Point]) {
            var lo = Point(Double.infinity, Double.infinity)
            var hi = Point(-Double.infinity, -Double.infinity)
            for point in points {
                lo.x = Swift.min(lo.x, point.x); lo.y = Swift.min(lo.y, point.y)
                hi.x = Swift.max(hi.x, point.x); hi.y = Swift.max(hi.y, point.y)
            }
            self.init(minX: lo.x, minY: lo.y, maxX: hi.x, maxY: hi.y)
        }

        public func contains(_ point: Point) -> Bool {
            point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
        }
    }

    // MARK: - The path

    /// One absolute pen command. Arcs are flattened as they are read, so nothing downstream has to
    /// know about them.
    public enum Segment: Hashable, Sendable {
        case move(Point)
        case line(Point)
        case quad(control: Point, to: Point)
        case cubic(control1: Point, control2: Point, to: Point)
        case close
    }

    public enum PathError: Error, Hashable, Sendable, CustomStringConvertible {
        case empty
        case tooLong(Int)
        case unknownCharacter(Character)
        case malformedNumber(String)
        case missingInitialMove
        case nothingToDraw
        case tooManySubpaths(Int)

        public var description: String {
            switch self {
            case .empty: return "path is empty"
            case .tooLong(let limit): return "path longer than \(limit) characters"
            case .unknownCharacter(let character):
                return "unsupported character \"\(character)\" (allowed commands: M L H V C S Q T A Z)"
            case .malformedNumber(let text): return "cannot parse number \"\(text)\""
            case .missingInitialMove: return "path must start with M"
            case .nothingToDraw: return "path has too few coordinates"
            case .tooManySubpaths(let limit): return "path has more than \(limit) subpaths"
            }
        }
    }

    /// Upstream's limits (`PATH_LIMITS`), so a definition that imports there imports here.
    public static let maxPathCharacters = 6000
    public static let maxSubpaths = 16

    /// Parse an SVG path into absolute `M/L/Q/C/Z` commands, with arcs and shorthands resolved.
    ///
    /// Only the pen commands the contract allows (`M L H V C S Q T A Z`, both cases). Anything else
    /// is refused by name, because a definition is model-written text and a parser that ignores what
    /// it does not know draws a *different* shape instead of saying so.
    public static func parse(_ path: String) throws -> [Segment] {
        if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw PathError.empty }
        if path.count > maxPathCharacters { throw PathError.tooLong(maxPathCharacters) }

        let characters = Array(path)
        var index = 0
        var segments: [Segment] = []
        var command: Character?
        var current = Point.zero
        var subpathStart = Point.zero
        var lastCubicControl: Point?
        var lastQuadControl: Point?
        var subpaths = 0
        var open = false

        func readNumber() throws -> Double {
            skipSeparators()
            let start = index
            if index < characters.count, characters[index] == "-" || characters[index] == "+" {
                index += 1
            }
            var sawDigit = false
            while index < characters.count, characters[index].isNumber || characters[index] == "." {
                if characters[index].isNumber { sawDigit = true }
                index += 1
            }
            if index < characters.count, characters[index] == "e" || characters[index] == "E" {
                let mark = index
                index += 1
                if index < characters.count, characters[index] == "-" || characters[index] == "+" {
                    index += 1
                }
                let exponentStart = index
                while index < characters.count, characters[index].isNumber { index += 1 }
                if exponentStart == index { index = mark }
            }
            let text = String(characters[start..<index])
            guard sawDigit, let value = Double(text), value.isFinite else {
                throw PathError.malformedNumber(text.isEmpty ? String(characters[min(start, characters.count - 1)]) : text)
            }
            return value
        }

        func skipSeparators() {
            while index < characters.count, characters[index].isWhitespace || characters[index] == "," {
                index += 1
            }
        }

        func point(_ relative: Bool) throws -> Point {
            let x = try readNumber()
            let y = try readNumber()
            return relative ? Point(current.x + x, current.y + y) : Point(x, y)
        }

        while index < characters.count {
            let character = characters[index]
            if character.isLetter {
                let upper = Character(String(character).uppercased())
                guard "MLHVCSQTAZ".contains(upper) else { throw PathError.unknownCharacter(character) }
                if upper == "Z" {
                    guard open else { throw PathError.malformedNumber("Z") }
                    segments.append(.close)
                    current = subpathStart
                    lastCubicControl = nil
                    lastQuadControl = nil
                    open = false
                    index += 1
                    continue
                }
                if !open && upper != "M" { throw PathError.missingInitialMove }
                command = character
                if upper == "M" { subpaths += 1 }
                index += 1
                continue
            }
            skipSeparators()
            guard index < characters.count else { break }
            // The number run ended at the next command: let the top of the loop dispatch it.
            if characters[index].isLetter { continue }
            guard let raw = command else { throw PathError.missingInitialMove }
            let upper = Character(String(raw).uppercased())
            let relative = raw.isLowercase

            switch upper {
            case "M":
                let target = try point(relative)
                if open { segments.append(.close) }
                segments.append(.move(target))
                current = target
                subpathStart = target
                open = true
                lastCubicControl = nil
                lastQuadControl = nil
                // Following pairs are implicit line-tos, as SVG says.
                command = relative ? "l" : "L"
            case "L":
                let target = try point(relative)
                segments.append(.line(target))
                current = target
                lastCubicControl = nil
                lastQuadControl = nil
            case "H":
                let x = try readNumber()
                let target = Point(relative ? current.x + x : x, current.y)
                segments.append(.line(target))
                current = target
                lastCubicControl = nil
                lastQuadControl = nil
            case "V":
                let y = try readNumber()
                let target = Point(current.x, relative ? current.y + y : y)
                segments.append(.line(target))
                current = target
                lastCubicControl = nil
                lastQuadControl = nil
            case "C":
                let c1 = try point(relative)
                let c2 = try point(relative)
                let end = try point(relative)
                segments.append(.cubic(control1: c1, control2: c2, to: end))
                current = end
                lastCubicControl = c2
                lastQuadControl = nil
            case "S":
                let reflected = lastCubicControl.map { Point(2 * current.x - $0.x, 2 * current.y - $0.y) } ?? current
                let c2 = try point(relative)
                let end = try point(relative)
                segments.append(.cubic(control1: reflected, control2: c2, to: end))
                current = end
                lastCubicControl = c2
                lastQuadControl = nil
            case "Q":
                let c = try point(relative)
                let end = try point(relative)
                segments.append(.quad(control: c, to: end))
                current = end
                lastQuadControl = c
                lastCubicControl = nil
            case "T":
                let reflected = lastQuadControl.map { Point(2 * current.x - $0.x, 2 * current.y - $0.y) } ?? current
                let end = try point(relative)
                segments.append(.quad(control: reflected, to: end))
                current = end
                lastQuadControl = reflected
                lastCubicControl = nil
            case "A":
                let rx = try readNumber()
                let ry = try readNumber()
                let rotation = try readNumber()
                _ = try readNumber() // large-arc flag
                _ = try readNumber() // sweep flag
                let end = try point(relative)
                for segment in arcSegments(from: current, to: end, rx: rx, ry: ry, rotation: rotation) {
                    segments.append(segment)
                }
                current = end
                lastCubicControl = nil
                lastQuadControl = nil
            default:
                throw PathError.unknownCharacter(character)
            }
        }
        if segments.isEmpty { throw PathError.nothingToDraw }
        if subpaths > maxSubpaths { throw PathError.tooManySubpaths(maxSubpaths) }
        return segments
    }

    /// An elliptical arc as cubic Béziers (SVG's endpoint → centre parameterisation).
    ///
    /// The contract's artwork is drawn with `M/Q/C/Z`, but a definition pasted from an editor may
    /// carry an `A`, and refusing one would be a drawing that silently loses a limb.
    private static func arcSegments(from start: Point, to end: Point, rx: Double, ry: Double, rotation: Double) -> [Segment] {
        guard rx > 0, ry > 0, start != end else { return [.line(end)] }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        let scale = lambda > 1 ? lambda.squareRoot() : 1
        let rx2 = rx * scale, ry2 = ry * scale
        let numerator = max(0, rx2 * rx2 * ry2 * ry2 - rx2 * rx2 * y1 * y1 - ry2 * ry2 * x1 * x1)
        let denominator = rx2 * rx2 * y1 * y1 + ry2 * ry2 * x1 * x1
        var factor = denominator == 0 ? 0 : (numerator / denominator).squareRoot()
        if (x1 * y1) > 0 { factor = -factor }
        let cx1 = factor * rx2 * y1 / ry2
        let cy1 = -factor * ry2 * x1 / rx2
        let centerX = cosPhi * cx1 - sinPhi * cy1 + (start.x + end.x) / 2
        let centerY = sinPhi * cx1 + cosPhi * cy1 + (start.y + end.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let dot = ux * vx + uy * vy
            let length = ((ux * ux + uy * uy) * (vx * vx + vy * vy)).squareRoot()
            let value = length == 0 ? 0 : max(-1, min(1, dot / length))
            return ux * vy - uy * vx < 0 ? -acos(value) : acos(value)
        }
        let theta = angle(1, 0, (x1 - cx1) / rx2, (y1 - cy1) / ry2)
        var sweep = angle((x1 - cx1) / rx2, (y1 - cy1) / ry2, (-x1 - cx1) / rx2, (-y1 - cy1) / ry2)
        // The sweep flag decides the direction; the flags were read but not kept, so the shorter
        // arc wins — which is what every shipped definition's arcs are.
        if sweep < 0 { sweep += 2 * .pi }
        let steps = max(2, Int((abs(sweep) / (.pi / 2)).rounded(.up)) * 2)
        func at(_ t: Double) -> Point {
            let x = rx2 * cos(t), y = ry2 * sin(t)
            return Point(cosPhi * x - sinPhi * y + centerX, sinPhi * x + cosPhi * y + centerY)
        }
        func derivative(_ t: Double) -> Point {
            let x = -rx2 * sin(t), y = ry2 * cos(t)
            return Point(cosPhi * x - sinPhi * y, sinPhi * x + cosPhi * y)
        }
        var output: [Segment] = []
        for step in 0..<steps {
            let t0 = theta + sweep * Double(step) / Double(steps)
            let t1 = theta + sweep * Double(step + 1) / Double(steps)
            let p0 = at(t0), p1 = at(t1)
            let d0 = derivative(t0), d1 = derivative(t1)
            let k = (4.0 / 3.0) * tan((t1 - t0) / 4)
            output.append(.cubic(control1: Point(p0.x + k * d0.x, p0.y + k * d0.y),
                                 control2: Point(p1.x - k * d1.x, p1.y - k * d1.y),
                                 to: step == steps - 1 ? end : p1))
        }
        return output
    }

    /// The path flattened into closed polygons, one per subpath.
    public static func polygons(_ segments: [Segment]) -> [[Point]] {
        var result: [[Point]] = []
        var current: [Point] = []
        var point = Point.zero
        var start = Point.zero
        func flush() {
            if current.count >= 3 { result.append(current) }
            current = []
        }
        let steps = 14
        for segment in segments {
            switch segment {
            case .move(let to):
                flush()
                point = to; start = to
                current.append(to)
            case .line(let to):
                point = to
                current.append(to)
            case .quad(let control, let to):
                for i in 1...steps {
                    let t = Double(i) / Double(steps), m = 1 - t
                    current.append(Point(m * m * point.x + 2 * m * t * control.x + t * t * to.x,
                                          m * m * point.y + 2 * m * t * control.y + t * t * to.y))
                }
                point = to
            case .cubic(let c1, let c2, let to):
                for i in 1...steps {
                    let t = Double(i) / Double(steps), m = 1 - t
                    current.append(Point(m * m * m * point.x + 3 * m * m * t * c1.x + 3 * m * t * t * c2.x + t * t * t * to.x,
                                          m * m * m * point.y + 3 * m * m * t * c1.y + 3 * m * t * t * c2.y + t * t * t * to.y))
                }
                point = to
            case .close:
                flush()
                point = start
            }
        }
        flush()
        return result
    }

    // MARK: - Filling

    /// Nonzero winding: whether `point` is inside the filled set of `polygons`.
    public static func contains(_ polygons: [[Point]], _ point: Point) -> Bool {
        var winding = 0
        for polygon in polygons {
            var previous = polygon[polygon.count - 1]
            for vertex in polygon {
                if previous.y <= point.y {
                    if vertex.y > point.y, cross(previous, vertex, point) > 0 { winding += 1 }
                } else if vertex.y <= point.y, cross(previous, vertex, point) < 0 {
                    winding -= 1
                }
                previous = vertex
            }
        }
        return winding != 0
    }

    private static func cross(_ a: Point, _ b: Point, _ p: Point) -> Double {
        (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y)
    }

    /// Distance from `point` to the nearest polygon edge.
    public static func edgeDistance(_ polygons: [[Point]], _ point: Point) -> Double {
        var best = Double.infinity
        for polygon in polygons {
            var previous = polygon[polygon.count - 1]
            for vertex in polygon {
                best = Swift.min(best, segmentDistance(point, previous, vertex))
                previous = vertex
            }
        }
        return best
    }

    private static func segmentDistance(_ p: Point, _ a: Point, _ b: Point) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return p.distance(to: a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return p.distance(to: Point(a.x + t * dx, a.y + t * dy))
    }

    /// Area enclosed by the polygons, using their winding: a hole wound the other way subtracts.
    public static func filledArea(_ polygons: [[Point]]) -> Double {
        var total = 0.0
        for polygon in polygons {
            var sum = 0.0
            var previous = polygon[polygon.count - 1]
            for vertex in polygon {
                sum += previous.x * vertex.y - vertex.x * previous.y
                previous = vertex
            }
            total += sum / 2
        }
        return abs(total)
    }

    // MARK: - Distance field

    /// A sampled signed distance: positive inside the part, negative outside, roughly in units.
    public struct Field {
        public var origin: Point
        public var step: Double
        public var columns: Int
        public var rows: Int
        public var values: [Double]

        public func value(column: Int, row: Int) -> Double {
            values[row * columns + column]
        }

        public func point(column: Int, row: Int) -> Point {
            Point(origin.x + Double(column) * step, origin.y + Double(row) * step)
        }

        /// Bilinear read, for the surface probe (the eye plane).
        public func sample(_ x: Double, _ y: Double) -> Double {
            let fx = (x - origin.x) / step, fy = (y - origin.y) / step
            let i = max(0, min(columns - 2, Int(fx.rounded(.down))))
            let j = max(0, min(rows - 2, Int(fy.rounded(.down))))
            let tx = max(0, min(1, fx - Double(i))), ty = max(0, min(1, fy - Double(j)))
            let a = value(column: i, row: j), b = value(column: i + 1, row: j)
            let c = value(column: i, row: j + 1), d = value(column: i + 1, row: j + 1)
            return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
        }
    }

    /// Build the distance field of a part over its own box.
    ///
    /// The step is chosen from the part's size: fine enough that a contour reads as the outline at
    /// avatar sizes, coarse enough that the whole field is a few thousand samples — this runs once
    /// per definition, never per frame.
    public static func field(for polygons: [[Point]], box: Box, step requestedStep: Double? = nil) -> Field {
        let step = requestedStep ?? max(0.35, min(0.6, min(box.width, box.height) / 90))
        let pad = 1.0
        let columns = max(3, Int(((box.width + 2 * pad) / step).rounded(.up)) + 1)
        let rows = max(3, Int(((box.height + 2 * pad) / step).rounded(.up)) + 1)
        let origin = Point(box.minX - pad, box.minY - pad)
        var values = [Double](repeating: 0, count: columns * rows)
        for row in 0..<rows {
            let y = origin.y + Double(row) * step
            for column in 0..<columns {
                let x = origin.x + Double(column) * step
                let p = Point(x, y)
                let inside = contains(polygons, p)
                let distance = edgeDistance(polygons, p)
                values[row * columns + column] = inside ? distance : -distance
            }
        }
        return Field(origin: origin, step: step, columns: columns, rows: rows, values: values)
    }

    /// The zero contour of `value − threshold`, as closed loops.
    ///
    /// Marching squares with linear interpolation: the contour of a distance field is an offset
    /// outline, which is exactly the cross-section an inflated part has at a given depth. Loops are
    /// stitched from the cell segments and smoothed once, so a 0.5-unit grid still gives a curve
    /// rather than a staircase.
    public static func contours(of field: Field, at threshold: Double = 0) -> [[Point]] {
        var segments: [(Point, Point)] = []
        for row in 0..<(field.rows - 1) {
            for column in 0..<(field.columns - 1) {
                let a = field.value(column: column, row: row) - threshold
                let b = field.value(column: column + 1, row: row) - threshold
                let c = field.value(column: column + 1, row: row + 1) - threshold
                let d = field.value(column: column, row: row + 1) - threshold
                var mask = 0
                if a >= 0 { mask |= 1 }
                if b >= 0 { mask |= 2 }
                if c >= 0 { mask |= 4 }
                if d >= 0 { mask |= 8 }
                if mask == 0 || mask == 15 { continue }
                let p0 = field.point(column: column, row: row)
                let p1 = field.point(column: column + 1, row: row)
                let p2 = field.point(column: column + 1, row: row + 1)
                let p3 = field.point(column: column, row: row + 1)
                func edge(_ from: Point, _ to: Point, _ va: Double, _ vb: Double) -> Point {
                    let t = va == vb ? 0.5 : va / (va - vb)
                    return Point(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t)
                }
                let bottom = { edge(p0, p1, a, b) }()
                let right = { edge(p1, p2, b, c) }()
                let top = { edge(p3, p2, d, c) }()
                let left = { edge(p0, p3, a, d) }()
                switch mask {
                case 1, 14: segments.append((left, bottom))
                case 2, 13: segments.append((bottom, right))
                case 3, 12: segments.append((left, right))
                case 4, 11: segments.append((right, top))
                case 6, 9: segments.append((bottom, top))
                case 7, 8: segments.append((left, top))
                case 5, 10:
                    // Ambiguous saddle: split by the cell's average, which is what the surface does.
                    if (a + b + c + d) / 4 >= 0 {
                        segments.append((left, bottom)); segments.append((right, top))
                    } else {
                        segments.append((left, top)); segments.append((bottom, right))
                    }
                default: break
                }
            }
        }
        return stitch(segments).map(smooth)
    }

    private static func key(_ point: Point) -> String {
        "\(Int((point.x * 512).rounded())):\(Int((point.y * 512).rounded()))"
    }

    /// Join unordered segments into closed loops (a contour never dead-ends).
    private static func stitch(_ segments: [(Point, Point)]) -> [[Point]] {
        var byPoint: [String: [Int]] = [:]
        for (index, segment) in segments.enumerated() {
            byPoint[key(segment.0), default: []].append(index)
            byPoint[key(segment.1), default: []].append(index)
        }
        var used = [Bool](repeating: false, count: segments.count)
        var loops: [[Point]] = []
        for start in segments.indices where !used[start] {
            used[start] = true
            var loop = [segments[start].0, segments[start].1]
            var cursor = segments[start].1
            var guardCount = 0
            while guardCount < segments.count + 2 {
                guardCount += 1
                let candidates = byPoint[key(cursor)] ?? []
                guard let next = candidates.first(where: { !used[$0] }) else { break }
                used[next] = true
                let (a, b) = segments[next]
                let following = key(a) == key(cursor) ? b : a
                if key(following) == key(loop[0]) { break }
                loop.append(following)
                cursor = following
            }
            if loop.count >= 3 { loops.append(loop) }
        }
        return loops
    }

    /// One Chaikin pass: rounds the grid's staircase without moving the shape.
    private static func smooth(_ loop: [Point]) -> [Point] {
        guard loop.count >= 4 else { return loop }
        var output: [Point] = []
        for index in loop.indices {
            let next = loop[(index + 1) % loop.count]
            output.append(Point(loop[index].x * 0.75 + next.x * 0.25, loop[index].y * 0.75 + next.y * 0.25))
            output.append(Point(loop[index].x * 0.25 + next.x * 0.75, loop[index].y * 0.25 + next.y * 0.75))
        }
        return output
    }

    // MARK: - The lid

    /// Neutral eye size at scale 1, in definition units (the contract's own numbers).
    public static let eyeWidth = 4.0
    public static let eyeHeight = 11.0
    /// How much bigger the drawn eyes may be when the body has room (`EYE_BOOST`).
    public static let eyeBoost = 1.45
    /// The gap the enlarged eyes must keep from the outline (`EYE_BOOST_PAD`).
    public static let eyeBoostPad = 3.0
    /// The margin validation demands between the eyes and the outline.
    public static let eyeMargin = 1.2
    /// Gaze travel at the drawn scale: small on purpose, a glance rather than a slide.
    public static let gazeX = 1.5
    public static let gazeY = 1.1

    public static func eyeCenters(_ eyes: BotAvatarDefinition.Eyes) -> [Point] {
        [Point(eyes.x - eyes.spacing / 2, eyes.y), Point(eyes.x + eyes.spacing / 2, eyes.y)]
    }

    /// Points on the outline of one eye's pill, expanded by `margin`.
    public static func eyeOutline(center: Point, scale: Double, margin: Double) -> [Point] {
        let halfWidth = (eyeWidth * scale) / 2 + margin
        let halfHeight = (eyeHeight * scale) / 2 + margin
        let straight = max(0, halfHeight - halfWidth)
        var points: [Point] = []
        for step in 0..<16 {
            let angle = Double(step) / 16 * 2 * .pi
            let x = cos(angle) * halfWidth
            let y = sin(angle) * halfWidth + (sin(angle) >= 0 ? 1 : -1) * straight
            points.append(Point(center.x + x, center.y + y))
        }
        for fraction in [-0.5, 0, 0.5] {
            points.append(Point(center.x - halfWidth, center.y + fraction * straight))
            points.append(Point(center.x + halfWidth, center.y + fraction * straight))
        }
        return points
    }

    /// Whether both eyes, at `scale`, sit `margin` inside the filled body.
    public static func eyesFit(_ polygons: [[Point]], eyes: BotAvatarDefinition.Eyes, scale: Double, margin: Double) -> Bool {
        for center in eyeCenters(eyes) {
            for point in eyeOutline(center: center, scale: scale, margin: margin) where !contains(polygons, point) {
                return false
            }
        }
        return true
    }
}
