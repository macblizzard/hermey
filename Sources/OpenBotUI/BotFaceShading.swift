import SwiftUI

/// The light that turns a flat shape into something a little dimensional.
///
/// Tier one of the "a little 3D" work (#100): a silhouette is one flat fill, which read as a
/// sticker next to the app's panes. Three layers, drawn *inside* the same silhouette so the outline
/// never changes:
///
/// 1. **A highlight from above** — where a light over the window would land, fading out by the
///    shape's middle.
/// 2. **A shadow below** — the same shape, darkened toward the bottom, so it reads as curved away
///    from the light rather than cut out of paper.
/// 3. **An inner rim** — a blurred dark stroke clipped inside the edge. This is the part that does
///    the most work: it makes the fill look like it sits *behind* the outline instead of filling it.
///
/// No blend modes: they are the fastest way to make a dark theme look dirty, and the effect wanted
/// here (a lighter top, a darker bottom) is what plain alpha gradients already do. No material, no
/// shadow on the outside: at 22 pt in a roster row an outer shadow is a smudge.
public struct BotFaceLight: View {
    public let icon: BotIcon
    public let size: CGFloat

    public init(icon: BotIcon, size: CGFloat) {
        self.icon = icon
        self.size = size
    }

    public var body: some View {
        ZStack {
            // Lit from above.
            BotSilhouette(icon)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(highlight), location: 0),
                            .init(color: .white.opacity(highlight * 0.35), location: 0.28),
                            .init(color: .clear, location: 0.55)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // Turning away from it.
            BotSilhouette(icon)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.42),
                            .init(color: .black.opacity(shade * 0.45), location: 0.78),
                            .init(color: .black.opacity(shade), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // The rim, clipped to the shape.
            BotSilhouette(icon)
                .stroke(Color.black.opacity(0.5), lineWidth: max(1, size * 0.09))
                .blur(radius: max(1, size * 0.045))
                .mask(BotSilhouette(icon).fill(Color.black))

            // A small specular mark, high and slightly left, where a room's light would catch a
            // rounded form. It is a dot, not a gradient: at these sizes a broad highlight reads as
            // a smudge.
            if size >= 28 {
                Circle()
                    .fill(Color.white.opacity(0.20))
                    .frame(width: size * 0.10, height: size * 0.10)
                    .blur(radius: size * 0.022)
                    .offset(x: -size * 0.17, y: -size * 0.24)
                    .mask(BotSilhouette(icon).fill(Color.black))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Small faces get less light: at 22 pt a strong gradient eats the silhouette's own colour.
    private var highlight: Double {
        size >= 40 ? 0.30 : (size >= 28 ? 0.26 : 0.20)
    }

    private var shade: Double {
        size >= 40 ? 0.34 : (size >= 28 ? 0.28 : 0.22)
    }
}
