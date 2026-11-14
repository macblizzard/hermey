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
public extension View {
    /// Real Liquid Glass where the OS has it.
    ///
    /// This replaces an earlier recipe that painted the surface by hand — a material blur, a wash
    /// and a rim — because at the time an opaque canvas band sat directly behind the composer, so
    /// the real material had nothing to refract and arrived as a flat box. That band is gone, which
    /// makes this the right implementation: the platform's own glass, with its own refraction and
    /// its own specular edge. A hand-built surface can be made to *look* like glass; only the real
    /// one behaves like it, and next to the rest of the system it is what reads as native.
    ///
    /// The fallback is a material, not a tint: an OS without Liquid Glass still gets a surface that
    /// samples what is behind it rather than a flat fill.
    ///
    /// `interactive` marks a shape a finger lands on, so the glass answers the touch.
    @ViewBuilder
    func hermeyGlass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self
                .background(shape.fill(.ultraThinMaterial))
                .clipShape(shape)
        }
    }
}
