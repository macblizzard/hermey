import SwiftUI
import HermesKit

/// A face drawn once — no timeline, no ring, no state.
///
/// `BotAvatarView` wraps its drawing in a `TimelineView` so a visible face can move. That is right on
/// screen and wrong off it: `ImageRenderer` cannot sample a timeline, so a view built for motion
/// renders blank or stale when it is turned into a notification banner. This is the same body and the
/// same two bars at rest, in a tree the renderer can walk in one pass.
///
/// It is deliberately not a second design: the geometry, the palette and the eye ink all come from
/// `BotAvatarGeometry`/`BotAvatarPalette`, so a face here and the face in the roster cannot disagree.
public struct BotAvatarStill: View {
    public var identity: String
    /// The stored `#RRGGBB::shape_N`, or nil for the identity's own face.
    public var color: String?
    public var size: CGFloat
    /// The colour behind the eyes when the palette asks the page for them (the palest bodies).
    public var pageBackground: Color?

    public init(identity: String, color: String? = nil, size: CGFloat, pageBackground: Color? = nil) {
        self.identity = identity
        self.color = color
        self.size = size
        self.pageBackground = pageBackground
    }

    public var body: some View {
        let resolved = BotAvatarIdentity.resolve(identity: identity, explicitColor: color)

        ZStack {
            if resolved.isImage {
                // A photo face is the host's picture, not geometry: nothing to draw here.
                Color.clear
            } else {
                resolved.shape.path(inSide: size)
                    .fill(resolved.color.color)
                eyes(for: resolved)
            }
        }
        .frame(width: size, height: size)
    }

    private func eyes(for resolved: BotAvatarIdentity) -> some View {
        let geometry = BotAvatarGeometry.shipped
        let scale = CGFloat(geometry.scale(forSide: Double(size)))

        return ZStack(alignment: .topLeading) {
            ForEach(geometry.eyes.bars) { bar in
                RoundedRectangle(cornerRadius: CGFloat(bar.cornerRadius) * scale, style: .continuous)
                    .fill(ink(forBody: resolved.color.hex))
                    .frame(width: CGFloat(bar.width) * scale, height: CGFloat(bar.height) * scale)
                    .offset(x: CGFloat(bar.x - geometry.viewBox.minX) * scale,
                            y: CGFloat(bar.y - geometry.viewBox.minY) * scale)
            }
        }
        .frame(width: size, height: size, alignment: .topLeading)
    }

    /// The same three inks as the animated view: the page's own colour, near-black, or white.
    private func ink(forBody hex: String) -> Color {
        switch BotAvatarPalette.eyeTone(forBody: hex) {
        case .page: return pageBackground ?? Tokens.canvas
        case .dark: return Color(red: 0.04, green: 0.04, blue: 0.05)
        case .light: return .white
        }
    }
}
