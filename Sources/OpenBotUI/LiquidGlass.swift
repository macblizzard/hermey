import SwiftUI

/// Liquid Glass, where the OS has it.
///
/// The chrome in these apps is a set of small floating shapes over content — the bot pill, the back
/// button, the way to the newest message, the composer — and that is exactly the case the material
/// on iOS 26 and macOS 26 was made for: it refracts what passes underneath instead of covering it,
/// which is the difference between "a pill sitting on the transcript" and "a pill floating over it".
///
/// Everything below is a fallback, not a second design: an OS without the material gets the theme's
/// own surface in the same shape, so a shape that reads as a pill on one phone reads as a pill on
/// the other.
public extension View {
    /// Wraps the view in glass, clipped to `shape`.
    ///
    /// `interactive` is for a control a finger lands on: the material answers the touch. Static
    /// glass is for a shape that only reports something.
    @ViewBuilder
    func hermeyGlass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(shape.fill(Tokens.surface))
        }
    }
}
