import SwiftUI

// The one file in this module that knows about pixels: the parsed commands become a `Path`, and a
// palette hex becomes a `Color`. Everything else is plain numbers, which is what lets the geometry
// and the colour rules be tested off-device.

public extension BotAvatarShape {
    /// The body, drawn into a square `side` points wide.
    ///
    /// The path data lives in the reference's 259-unit view box, which starts at -15: this applies
    /// that origin and the scale, so the body fills the square edge to edge at any size.
    func path(inSide side: CGFloat) -> Path {
        path(in: CGRect(x: 0, y: 0, width: side, height: side))
    }

    /// The same into an arbitrary rect, fitted and centred — a caller that gives a wide frame gets a
    /// round avatar in the middle of it rather than a stretched one.
    func path(in rect: CGRect) -> Path {
        let geometry = BotAvatarGeometry.shipped
        let side = min(rect.width, rect.height)
        guard side > 0 else { return Path() }
        let scale = geometry.scale(forSide: Double(side))
        let originX = rect.midX - side / 2 - geometry.viewBox.minX * scale
        let originY = rect.midY - side / 2 - geometry.viewBox.minY * scale

        func place(_ point: BotAvatarPoint) -> CGPoint {
            CGPoint(x: originX + point.x * scale, y: originY + point.y * scale)
        }

        var path = Path()
        for command in commands {
            switch command {
            case .move(let to):
                path.move(to: place(to))
            case .line(let to):
                path.addLine(to: place(to))
            case .quad(let control, let to):
                path.addQuadCurve(to: place(to), control: place(control))
            case .cubic(let control1, let control2, let to):
                path.addCurve(to: place(to), control1: place(control1), control2: place(control2))
            case .close:
                path.closeSubpath()
            }
        }
        return path
    }
}

public extension BotAvatarGeometry {
    /// Both bar eyes as one path, at a square `side` points wide — what the reference calls
    /// `avatarEyeRects`, drawn.
    func eyesPath(inSide side: CGFloat) -> Path {
        let scale = self.scale(forSide: Double(side))
        guard scale > 0, viewBox.width > 0 else { return Path() }
        let bars = eyes.bars.map { self.bar($0, inSide: side) }
        var path = Path()
        for bar in bars {
            let rect = CGRect(x: bar.x, y: bar.y, width: bar.width, height: bar.height)
            path.addRoundedRect(in: rect,
                                cornerSize: CGSize(width: bar.cornerRadius, height: bar.cornerRadius))
        }
        return path
    }
}

public extension BotAvatarColorDef {
    /// The palette hex as a SwiftUI colour. Parsed as sRGB, which is what the reference's hexes
    /// mean; a malformed value falls back to clear rather than to black so a bug is visible.
    var color: Color {
        Self.color(fromHex: hex) ?? .clear
    }

    static func color(fromHex hex: String) -> Color? {
        let digits = BotAvatarPalette.expandedHex(hex)
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return Color(.sRGB,
                     red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255,
                     opacity: 1)
    }
}
