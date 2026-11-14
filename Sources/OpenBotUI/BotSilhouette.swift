import SwiftUI

/// A bot's silhouette, drawn as a **filled blob** in the face's colour.
///
/// The portraits used to be line drawings: a ring, a body, two dots, an antenna. They read as
/// robots, and they were ten variations of one idea — the state badge had to sit on top of a busy
/// mark, and at 22 pt in a list row the antenna was a smudge.
///
/// Rakazo's answer is better and this is it: a single solid shape with two dark bars for eyes. The
/// shape does all the identifying, the eyes do all the character, and because the mass is solid, a
/// badge or a spark on the corner reads instantly instead of competing with the drawing beneath it.
///
/// Every silhouette is drawn in a unit square, so one set of coordinates serves 22 pt in a row and
/// 40 pt in the header pill.
public struct BotSilhouette: Shape {
    public var kind: BotIcon

    public init(_ kind: BotIcon) {
        self.kind = kind
    }

    public func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let box = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: box.minX + x * side, y: box.minY + y * side)
        }

        var path = Path()

        switch kind {
        case .orbit:
            // A plain disk: the one silhouette with nothing to explain.
            path.addEllipse(in: box.insetBy(dx: side * 0.07, dy: side * 0.07))

        case .dusk:
            // Flatter than it is tall, and a touch uneven: a worn stone rather than a circle.
            path.addPath(Self.wobble(point, centre: (0.5, 0.5), rx: 0.43, ry: 0.37,
                                     lobes: 9, amplitude: 0.035, seed: 1))

        case .cobalt:
            path.addPath(Self.wobble(point, centre: (0.5, 0.5), rx: 0.42, ry: 0.41,
                                     lobes: 8, amplitude: 0.06, seed: 3))

        case .lump:
            // The one that looks like it was squeezed: six soft protrusions, no symmetry.
            path.addPath(Self.wobble(point, centre: (0.5, 0.5), rx: 0.40, ry: 0.37,
                                     lobes: 7, amplitude: 0.10, seed: 5))

        case .blob:
            // A square that has melted at every corner.
            path.addRoundedRect(in: CGRect(x: box.minX + side * 0.06, y: box.minY + side * 0.07,
                                           width: side * 0.88, height: side * 0.86),
                                cornerSize: CGSize(width: side * 0.33, height: side * 0.33),
                                style: .continuous)

        case .pixel:
            path.addRoundedRect(in: box.insetBy(dx: side * 0.08, dy: side * 0.08),
                                cornerSize: CGSize(width: side * 0.24, height: side * 0.24),
                                style: .continuous)

        case .capsule:
            let height = side * 0.50
            path.addRoundedRect(in: CGRect(x: box.minX + side * 0.03,
                                           y: box.midY - height / 2,
                                           width: side * 0.94, height: height),
                                cornerSize: CGSize(width: height / 2, height: height / 2),
                                style: .continuous)

        case .rover:
            path.addPath(Self.roundedPolygon(point, sides: 6, radius: 0.44,
                                             rotation: -.pi / 2, rounding: 0.07))

        case .prism:
            // A triangle with its apex up and its feet rounded: a tent, not a blade.
            path.addPath(Self.roundedPolygon(point, sides: 3, radius: 0.47,
                                             rotation: -.pi / 2, rounding: 0.10))

        case .nova:
            path.addPath(Self.star(point, points: 5, outer: 0.47, inner: 0.25, rounding: 0.035))

        case .ember:
            path.addPath(Self.flame(point, top: 0.03, waist: 0.66, foot: 0.97, lean: -0.06))

        case .droplet:
            path.addPath(Self.flame(point, top: 0.03, waist: 0.60, foot: 0.97, lean: 0))

        case .beacon:
            // Dome, flared skirt, a curved base: a bell.
            path.move(to: point(0.15, 0.68))
            path.addCurve(to: point(0.85, 0.68),
                          control1: point(0.13, 0.12), control2: point(0.87, 0.12))
            path.addCurve(to: point(0.95, 0.88),
                          control1: point(0.88, 0.78), control2: point(0.95, 0.82))
            path.addQuadCurve(to: point(0.05, 0.88), control: point(0.5, 1.02))
            path.addCurve(to: point(0.15, 0.68),
                          control1: point(0.05, 0.82), control2: point(0.12, 0.78))
            path.closeSubpath()

        case .moss:
            // A cloud: three bumps on a flat floor.
            path.addEllipse(in: CGRect(x: box.minX + side * 0.02, y: box.minY + side * 0.36,
                                       width: side * 0.44, height: side * 0.44))
            path.addEllipse(in: CGRect(x: box.minX + side * 0.22, y: box.minY + side * 0.16,
                                       width: side * 0.58, height: side * 0.58))
            path.addEllipse(in: CGRect(x: box.minX + side * 0.56, y: box.minY + side * 0.34,
                                       width: side * 0.42, height: side * 0.42))
            path.addRoundedRect(in: CGRect(x: box.minX + side * 0.06,
                                           y: box.minY + side * 0.55,
                                           width: side * 0.88, height: side * 0.27),
                                cornerSize: CGSize(width: side * 0.13, height: side * 0.13),
                                style: .continuous)

        case .mushroom:
            path.addEllipse(in: CGRect(x: box.minX + side * 0.03, y: box.minY + side * 0.10,
                                       width: side * 0.94, height: side * 0.56))
            path.addRoundedRect(in: CGRect(x: box.minX + side * 0.34,
                                           y: box.minY + side * 0.52,
                                           width: side * 0.32, height: side * 0.40),
                                cornerSize: CGSize(width: side * 0.11, height: side * 0.11),
                                style: .continuous)

        case .scallop:
            // A rosette: seven lobes around a filled middle, wider than it is tall.
            for index in 0..<7 {
                let angle = -.pi / 2 + CGFloat(index) * (2 * .pi / 7)
                let radius = side * 0.26
                let centre = CGPoint(x: box.midX + cos(angle) * radius,
                                     y: box.midY + sin(angle) * radius * 0.86)
                let lobe = side * 0.30
                path.addEllipse(in: CGRect(x: centre.x - lobe / 2, y: centre.y - lobe / 2,
                                           width: lobe, height: lobe))
            }
            path.addEllipse(in: box.insetBy(dx: side * 0.26, dy: side * 0.20))
        }

        return path
    }

    // MARK: - Geometry that is easier to describe than to hand-list

    /// A closed curve through `lobes` radii that vary by `amplitude` — the difference between a
    /// stone, a pebble and a shape that looks squeezed.
    private static func wobble(_ point: (CGFloat, CGFloat) -> CGPoint,
                               centre: (CGFloat, CGFloat),
                               rx: CGFloat, ry: CGFloat,
                               lobes: Int, amplitude: CGFloat, seed: Int) -> Path {
        var samples: [CGPoint] = []
        for index in 0..<lobes {
            let angle = CGFloat(index) / CGFloat(lobes) * 2 * .pi
            let wobble = 1 + amplitude * sin(CGFloat(index) * 2.399 + CGFloat(seed) * 1.7)
            samples.append(point(centre.0 + cos(angle) * rx * wobble,
                                 centre.1 + sin(angle) * ry * wobble))
        }

        var path = Path()
        guard let first = samples.first else { return path }
        // Midpoints as on-curve anchors and the samples as controls: a smooth closed curve without
        // a spline solver.
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        let start = mid(first, samples[1])
        path.move(to: start)
        for index in 0..<samples.count {
            let control = samples[(index + 1) % samples.count]
            let target = mid(control, samples[(index + 2) % samples.count])
            path.addQuadCurve(to: target, control: control)
        }
        path.closeSubpath()
        return path
    }

    private static func roundedPolygon(_ point: (CGFloat, CGFloat) -> CGPoint,
                                       sides: Int, radius: CGFloat,
                                       rotation: CGFloat, rounding: CGFloat) -> Path {
        let vertices: [CGPoint] = (0..<sides).map { index in
            let angle = rotation + CGFloat(index) / CGFloat(sides) * 2 * .pi
            return point(0.5 + cos(angle) * radius * 0.92, 0.5 + sin(angle) * radius * 0.92)
        }

        var path = Path()
        for index in 0..<vertices.count {
            let current = vertices[index]
            let next = vertices[(index + 1) % vertices.count]
            let previous = vertices[(index + sides - 1) % vertices.count]

            func towards(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
                let dx = to.x - from.x, dy = to.y - from.y
                let length = max(0.0001, sqrt(dx * dx + dy * dy))
                let reach = rounding * length
                return CGPoint(x: from.x + dx / length * reach, y: from.y + dy / length * reach)
            }

            if index == 0 { path.move(to: towards(current, next)) }
            // The corner itself is the control point: a quadratic round-off, the same trick the
            // tail of the wobble uses.
            path.addQuadCurve(to: towards(current, previous), control: current)
            path.addLine(to: towards(current, next))
            path.addQuadCurve(to: towards(next, current), control: next)
        }
        path.closeSubpath()
        return path
    }

    private static func star(_ point: (CGFloat, CGFloat) -> CGPoint,
                             points: Int, outer: CGFloat, inner: CGFloat,
                             rounding: CGFloat) -> Path {
        var vertices: [CGPoint] = []
        for index in 0..<(points * 2) {
            let angle = -.pi / 2 + CGFloat(index) * .pi / CGFloat(points)
            let radius = index % 2 == 0 ? outer : inner
            vertices.append(point(0.5 + cos(angle) * radius, 0.5 + sin(angle) * radius))
        }

        var path = Path()
        path.move(to: vertices[0])
        for index in 0..<vertices.count {
            let current = vertices[(index + 1) % vertices.count]
            let previous = vertices[index]
            let dx = current.x - previous.x, dy = current.y - previous.y
            let length = max(0.0001, sqrt(dx * dx + dy * dy))
            let pull = CGPoint(x: current.x - dx / length * rounding * length,
                               y: current.y - dy / length * rounding * length)
            _ = pull
            path.addLine(to: current)
        }
        path.closeSubpath()
        return path
    }

    /// A pointed top and a rounded foot: a flame when it leans, a droplet when it does not.
    private static func flame(_ point: (CGFloat, CGFloat) -> CGPoint,
                              top: CGFloat, waist: CGFloat, foot: CGFloat,
                              lean: CGFloat) -> Path {
        var path = Path()
        let tipX = 0.5 + lean

        path.move(to: point(tipX, top))
        path.addCurve(to: point(0.12 + lean * 0.4, waist),
                      control1: point(tipX - 0.17, top + 0.20),
                      control2: point(0.12, waist - 0.24))
        path.addCurve(to: point(0.5, foot),
                      control1: point(0.12, foot - 0.14),
                      control2: point(0.28, foot))
        path.addCurve(to: point(0.88 + lean * 0.4, waist),
                      control1: point(0.72, foot),
                      control2: point(0.88, foot - 0.14))
        path.addCurve(to: point(tipX, top),
                      control1: point(0.88, waist - 0.24),
                      control2: point(tipX + 0.17, top + 0.20))
        path.closeSubpath()
        return path
    }
}

/// The two bars that make a silhouette a face.
///
/// Short, vertical, rounded, and dark: the eyes are the only thing drawn *on* the shape, so their
/// proportion is what keeps a 22 pt row recognisable. `tilt` is a couple of degrees either way,
/// which is the difference between a shape that looks at you and one that stares.
public struct BotEyes: View {
    public var size: CGFloat
    public var tilt: Double

    public init(size: CGFloat, tilt: Double = 0) {
        self.size = size
        self.tilt = tilt
    }

    public var body: some View {
        HStack(spacing: size * 0.135) {
            eye
            eye
        }
        .rotationEffect(.degrees(tilt))
        .offset(y: -size * 0.015)
    }

    private var eye: some View {
        RoundedRectangle(cornerRadius: size * 0.05, style: .continuous)
            .fill(Color.black.opacity(0.72))
            .frame(width: size * 0.105, height: size * 0.185)
    }
}

public extension BotIcon {
    /// How far each face's eyes are tipped. Small numbers on purpose: past about five degrees the
    /// face stops looking curious and starts looking broken.
    var eyeTilt: Double {
        switch self {
        case .ember: return -6
        case .nova: return 0
        case .cobalt: return 4
        case .orbit: return 0
        case .moss: return 0
        case .dusk: return -3
        case .beacon: return 0
        case .pixel: return 0
        case .rover: return 0
        case .prism: return 0
        case .lump: return 5
        case .mushroom: return 0
        case .blob: return 0
        case .capsule: return -4
        case .droplet: return 0
        case .scallop: return 3
        }
    }
}
