import SwiftUI

/// Make this surface wear the palette's own light/dark direction.
///
/// The app draws every colour from `Tokens`, but the *system* still draws things of its own inside a
/// surface: navigation titles, grouped row backgrounds, section footers, keyboards, scroll
/// indicators and sheet chrome. When the palette and the system disagree, you get the failure a light
/// theme invites — a white title and pale footers on cream, and rows painted with the system's dark
/// grouped background while the token text is ink. Both are the same bug: the surface never told the
/// system which direction it is.
///
/// Applied to a root it fixes the window; applied to a screen presented separately — a sheet, a
/// navigation stack inside a tab — it fixes that screen, because `preferredColorScheme` does not
/// always follow the presenting view into a presentation whose own environment was built earlier.
/// `@AppStorage` here (not `ThemeRuntime.active`) so the surface re-reads the choice when it changes
/// instead of holding the value it had when it first drew.
public struct HermesThemeChrome: ViewModifier {
    @AppStorage(ThemeRuntime.defaultsKey) private var themeID: String = ThemeCatalog.defaultID

    public init() {}

    public func body(content: Content) -> some View {
        content.preferredColorScheme(ThemeCatalog.theme(id: themeID).isLight ? .light : .dark)
    }
}

public extension View {
    /// Wear the palette's direction on this surface, system chrome included.
    func hermesThemeChrome() -> some View { modifier(HermesThemeChrome()) }
}
