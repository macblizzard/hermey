import Foundation

// MARK: - Geometry
//
// Everything here is plain `Double` maths in the reference's own coordinate space, with no
// SwiftUI or CoreGraphics types. That keeps the numbers testable off-device and lets the
// view layer be the only thing that knows about pixels.

/// A point in the avatar's own space: the reference's 259-unit view box.
public struct BotAvatarPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = BotAvatarPoint(0, 0)
}

/// An axis-aligned rectangle in the avatar's own space.
public struct BotAvatarRect: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// Finite on all four edges: NaN or infinity in a path is a drawing bug, not a shape.
    public var isFinite: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
    }

    /// The smallest rectangle holding both, the way a path's bounds are accumulated.
    public func union(_ other: BotAvatarRect) -> BotAvatarRect {
        let left = Swift.min(minX, other.minX)
        let top = Swift.min(minY, other.minY)
        let right = Swift.max(maxX, other.maxX)
        let bottom = Swift.max(maxY, other.maxY)
        return BotAvatarRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

/// One bar eye: a fully rounded bar, sized and placed by its box, as `avatarEyeRects` gives it.
public struct BotAvatarEyeBar: Hashable, Sendable, Identifiable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Half the width: the bar's ends are semicircles.
    public var cornerRadius: Double

    public var id: Double { x }

    public init(x: Double, y: Double, width: Double, height: Double, cornerRadius: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
    }

    public var rect: BotAvatarRect {
        BotAvatarRect(x: x, y: y, width: width, height: height)
    }
}

/// The pair of bars, described by the two centres they are placed at.
public struct BotAvatarEyes: Hashable, Sendable {
    public var width: Double
    public var height: Double
    public var leftCx: Double
    public var rightCx: Double
    public var cy: Double

    public init(width: Double, height: Double, leftCx: Double, rightCx: Double, cy: Double) {
        self.width = width
        self.height = height
        self.leftCx = leftCx
        self.rightCx = rightCx
        self.cy = cy
    }

    /// Left then right, as `avatarEyeRects` returns them: `x = cx - width/2`, `y = cy - height/2`.
    public var bars: [BotAvatarEyeBar] {
        [leftCx, rightCx].map { cx in
            BotAvatarEyeBar(x: cx - width / 2,
                            y: cy - height / 2,
                            width: width,
                            height: height,
                            cornerRadius: width / 2)
        }
    }

    /// The box both bars occupy, for placing an eyes layer.
    public var bounds: BotAvatarRect {
        BotAvatarRect(x: leftCx - width / 2,
                      y: cy - height / 2,
                      width: (rightCx - leftCx) + width,
                      height: height)
    }
}

/// The view box every shipped shape is drawn in, the centre it is drawn about, and the one face
/// they all wear.
///
/// Ported literally from `bot-avatar-shapes.ts`: the view box is `"-15 -15 259 259"`, the centre is
/// `114.2705`, and the eyes are the organic avatars' bars scaled into that box — width 15, height
/// 52, centres at `centre ∓ 22.5`, `cy = centre - 8`. Every shape therefore wears the same face at
/// the same place, which is what makes eight outlines read as one family.
public struct BotAvatarGeometry: Hashable, Sendable {
    /// The reference's view box string, kept for parity checks and for anyone drawing it in SVG.
    public static let viewBoxString = "-15 -15 259 259"
    /// The reference's centre value, before any offset is applied.
    public static let centreValue: Double = 114.2705

    public var viewBox: BotAvatarRect
    public var centre: BotAvatarPoint
    public var eyes: BotAvatarEyes

    public init(viewBox: BotAvatarRect, centre: BotAvatarPoint, eyes: BotAvatarEyes) {
        self.viewBox = viewBox
        self.centre = centre
        self.eyes = eyes
    }

    /// The one geometry the eight shipped shapes are drawn in.
    public static let shipped = BotAvatarGeometry(
        viewBox: BotAvatarRect(x: -15, y: -15, width: 259, height: 259),
        centre: BotAvatarPoint(centreValue, centreValue),
        eyes: BotAvatarEyes(width: 15,
                            height: 52,
                            leftCx: centreValue - 22.5,
                            rightCx: centreValue + 22.5,
                            cy: centreValue - 8)
    )

    /// How wide the view box is, in its own units.
    public var side: Double { viewBox.width }

    /// Units per point for an avatar `side` points wide.
    public func scale(forSide side: Double) -> Double {
        guard viewBox.width > 0, side > 0 else { return 0 }
        return side / viewBox.width
    }

    /// A point from the path data placed on a canvas `side` points wide.
    ///
    /// The view box starts at -15, so the origin shift is what keeps every shape centred rather
    /// than pushed 15 units down and right.
    public func point(_ point: BotAvatarPoint, inSide side: Double) -> BotAvatarPoint {
        let scale = scale(forSide: side)
        return BotAvatarPoint((point.x - viewBox.minX) * scale,
                              (point.y - viewBox.minY) * scale)
    }

    /// The same for one bar eye: its box, scaled.
    public func bar(_ bar: BotAvatarEyeBar, inSide side: Double) -> BotAvatarEyeBar {
        let scale = scale(forSide: side)
        return BotAvatarEyeBar(x: (bar.x - viewBox.minX) * scale,
                               y: (bar.y - viewBox.minY) * scale,
                               width: bar.width * scale,
                               height: bar.height * scale,
                               cornerRadius: bar.cornerRadius * scale)
    }
}
