import SwiftUI

// MARK: - Focus

/// The app's one spelling for "this control is a control, not a Macintosh text field".
///
/// macOS draws its keyboard focus ring in the accent blue — the same blue `Tokens.accent`
/// spends on `HermeyButton(kind: .primary)` — around every focusable control that holds
/// keyboard focus: a `Button` in any style, a `Picker`, a `Toggle`, a `Menu`, and it lands on
/// the first focusable control in a window the moment it opens. No chrome in Hermey ever
/// shows that ring. The kit's states are hover fill, pressed dim and (on the two rows that
/// are a keyboard stop) its own faint fill; a blue ring on a chat row or a chip reads as a
/// selection nobody made, and on the search glyph at launch it reads as focus the pointer
/// never asked for.
///
/// So the ring is off **everywhere**, and this is the only spelling of that decision:
///
/// ```swift
/// Button("Retry") { retry() }
///     .buttonStyle(PressableButtonStyle())
///     .hermeyFocusQuiet()
/// ```
///
/// **Where it is applied, and why it cannot be fewer places.** A `ButtonStyle` sees the
/// label, not the button: the ring is drawn by the `Button` around whatever its style
/// returned, so `PressableButtonStyle` cannot carry it. It is applied once per control
/// *type* — inside `HermeyButton`, `HermeyIconButton`, `TextButton`, the chips, the rows,
/// every kit control that wraps a `Button` — so each use of those inherits it, and then in
/// the modifier chain of each bare `Button`/`Toggle`/`Picker`/`Menu`/`Link`/`ShareLink` in
/// the apps. `Tests/test_focus_rings.py` holds that line: it reads every Swift construction
/// in `Apps` and `Sources/HermeyUI` and fails if one is not covered.
///
/// **It never costs a tab stop.** `focusEffectDisabled()` suppresses the drawing, not the
/// focus: a focused button still answers Space and Return, and the two places where keyboard
/// focus is a real affordance — the sidebar's bot rows and the composer's model pill — keep
/// their `@FocusState` and draw their own quiet fill instead. Nothing here calls
/// `focusable(false)`; that is a different decision, about whether Tab reaches a control at
/// all, and it is made deliberately where it appears.
///
/// **Not for menus.** A `Menu`'s items, a `.contextMenu`, and the app's `Commands` are
/// `NSMenu`s: the system owns their highlight and they never take this ring. They are out of
/// scope in the test for that reason.
public extension View {
    /// Suppress the platform's focus effect (the accent-blue ring) on this control.
    ///
    /// Focus and keyboard activation are untouched — only the ring is.
    func hermeyFocusQuiet() -> some View {
        focusEffectDisabled()
    }
}
