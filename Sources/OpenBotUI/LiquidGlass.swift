import SwiftUI

/// The one glass recipe these apps use.
///
/// The OS material is the right instinct — it refracts what passes underneath instead of covering
/// it — but on these screens the backdrop is a near-black canvas, and a lens over black is black.
/// That is why a `glassEffect` capsule kept arriving as a flat charcoal box: there was nothing
/// bright under it to bend, so all that reached the eye was the material's own tint.
///
/// So the surface is built rather than borrowed, out of three parts that survive any backdrop:
///
/// - **the blur** — `.ultraThinMaterial`, a real backdrop blur, so anything that does pass beneath
///   the shape is still legible through it;
/// - **the wash** — a hair of white at the top falling away to almost nothing at the bottom, which
///   is the light a panel of that thickness would gather;
/// - **the rim** — bright along the top edge where light would catch it, nearly gone along the
///   bottom. This is deliberately not a border: a border draws the same line the whole way round and
///   boxes the shape in, which is the "thin transparent frame" it kept reading as. A rim is an edge
///   with thickness.
///
/// The same three parts on every shape mean a pill, a circle and the composer read as one material
/// instead of three guesses.
public enum GlassSurface {
    /// Light gathered at the top of the panel, falling away below.
    public static let wash = LinearGradient(
        colors: [Color.white.opacity(0.12), Color.white.opacity(0.03)],
        startPoint: .top, endPoint: .bottom
    )

    /// Light catching the top edge, fading out before it reaches the bottom one.
    public static let rim = LinearGradient(
        colors: [Color.white.opacity(0.38), Color.white.opacity(0.04)],
        startPoint: .top, endPoint: .bottom
    )
}

public extension View {
    /// Wraps the view in the glass recipe, clipped to `shape`.
    ///
    /// `interactive` stays in the signature because call sites say what a shape *is* — a control a
    /// finger lands on, or a shape that only reports something — and that distinction should not
    /// vanish from the source just because the surface is built by hand here.
    @ViewBuilder
    func hermeyGlass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        self
            .background {
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.fill(GlassSurface.wash))
            }
            .overlay(shape.stroke(GlassSurface.rim, lineWidth: 1))
            .clipShape(shape)
    }
}
