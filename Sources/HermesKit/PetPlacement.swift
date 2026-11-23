import Foundation

/// A rectangle in the screen's own coordinate space (origin bottom-left, y up), in points.
///
/// Deliberately not `CGRect`: the clamping rules are pure arithmetic, and a value type this module
/// owns is what lets them be tested off a window server.
public struct PetRect: Equatable, Sendable {
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
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }

    public func contains(x pointX: Double, y pointY: Double) -> Bool {
        pointX >= minX && pointX <= maxX && pointY >= minY && pointY <= maxY
    }
}

/// Where one pet sits, and on which display.
///
/// Stored as `"x,y,screenID"` — one string per bot in `UserDefaults`, because that is the whole
/// requirement: this Mac's desk, for this Mac's bot. The screen id is the `NSScreenNumber` as a
/// string, which survives relaunches for the same display and changes when it is unplugged.
public struct PetPlacement: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var screenID: String

    public init(x: Double, y: Double, screenID: String) {
        self.x = x
        self.y = y
        self.screenID = screenID
    }

    /// `"x,y,screenID"`. Whole points: a window origin with a fraction in it drifts a pixel per drag.
    public var encoded: String {
        "\(Int(x.rounded())),\(Int(y.rounded())),\(screenID)"
    }

    /// Reads `"x,y,screenID"`. The screen id keeps any commas of its own (a localised display name
    /// is not used here, but a future id might contain one), so the split is bounded to two.
    public static func decode(_ raw: String) -> PetPlacement? {
        let parts = raw.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let x = Double(parts[0]),
              let y = Double(parts[1]),
              !parts[2].isEmpty
        else { return nil }
        return PetPlacement(x: x, y: y, screenID: String(parts[2]))
    }
}

/// The pet's own rules: how big it is, and where it may sit on a display.
///
/// "Clamped into the visible frame" is the whole of it — an icon dragged half off the edge is
/// dragged back on, and a position saved on a display that is now gone lands on whichever screen
/// the caller hands in. Kept here, free of AppKit, so the arithmetic is unit-tested rather than
/// eyeballed on a second monitor.
public enum PetGeometry {
    /// The icon's side, in points. The window is exactly this big plus `motionMargin` on each side:
    /// no more, because a larger window would be transparent-but-clickable, which is the widget feel
    /// the design avoids.
    public static let iconSide: Double = 96

    /// The transparent ring the window keeps around the icon so a hop is not clipped at its edge.
    /// It is clear, and `hitTest` declines it, so it costs pixels rather than clicks.
    public static let motionMargin: Double = 12

    public static func windowSide(icon: Double) -> Double {
        icon + motionMargin * 2
    }

    /// The origin that puts a `side`-point icon fully inside `frame`.
    ///
    /// A frame smaller than the icon (a tiny mirrored display) has no inside; the icon is pinned to
    /// the frame's own origin rather than given a negative range that would flip on every pass.
    public static func clamp(_ placement: PetPlacement, side: Double, to frame: PetRect) -> PetPlacement {
        let maxX = max(frame.minX, frame.maxX - side)
        let maxY = max(frame.minY, frame.maxY - side)
        return PetPlacement(x: min(max(placement.x, frame.minX), maxX),
                            y: min(max(placement.y, frame.minY), maxY),
                            screenID: placement.screenID)
    }

    /// A pet that has never been placed: centred, a little above the middle, so it does not sit on
    /// the Dock or under the menu bar.
    public static func centre(in frame: PetRect, screenID: String, side: Double) -> PetPlacement {
        let x = frame.minX + (frame.width - side) / 2
        let y = frame.minY + (frame.height - side) / 2
        return clamp(PetPlacement(x: x, y: y, screenID: screenID), side: side, to: frame)
    }

    /// A pet to the side of, and just above, another: where the balloon goes relative to its pet.
    public static func above(_ placement: PetPlacement,
                             side: Double,
                             balloon: PetRect,
                             in frame: PetRect,
                             gap: Double = 8) -> PetRect {
        let centredX = placement.x + (side - balloon.width) / 2
        let maxX = max(frame.minX, frame.maxX - balloon.width)
        let x = min(max(centredX, frame.minX), maxX)
        // Above the icon; if that would leave the screen, below it instead.
        let above = placement.y + side + gap
        let y = above + balloon.height <= frame.maxY
            ? above
            : max(frame.minY, placement.y - balloon.height - gap)
        return PetRect(x: x, y: y, width: balloon.width, height: balloon.height)
    }
}
