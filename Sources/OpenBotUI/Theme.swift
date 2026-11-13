import SwiftUI

/// A colour scheme the app can wear.
///
/// Every colour in the app comes from `Tokens`, and `Tokens` reads whatever palette is active here.
/// That is deliberate: there is one place a theme is defined, one place it is chosen, and no view
/// ever hardcodes a shade — so a new theme is a value in `ThemeCatalog`, not a pass over the UI.
///
/// The palettes are the well-known editor themes people already read code in (Gruvbox, Tokyo Night,
/// Catppuccin, Dracula, Nord) mapped onto this app's own roles. Roles that a theme does not name
/// outright are derived from the ones it does — a hover state is its surface nudged toward the
/// foreground, a muted text is its text pulled back toward the background — which is why each entry
/// below is a dozen numbers rather than three dozen.
public struct ThemePalette: Identifiable, Equatable {
    public let id: String
    public let name: String

    // MARK: Surfaces
    public let canvas: Color
    public let frame: Color
    public let sidebar: Color
    public let surface: Color
    public let surfaceRaised: Color
    public let control: Color
    public let controlHover: Color
    public let controlActive: Color
    public let sheet: Color
    public let sheetInset: Color
    public let grouped: Color

    // MARK: Text
    public let textPrimary: Color
    public let textSecondary: Color
    public let textMuted: Color
    public let textDim: Color
    public let textPlaceholder: Color
    public let textGroupedSecondary: Color

    // MARK: Accent and status
    public let accent: Color
    public let accentHover: Color
    public let accentText: Color
    public let success: Color
    public let warning: Color
    public let danger: Color

    // MARK: Borders
    public let border: Color
    public let borderStrong: Color
    public let borderGrouped: Color

    /// The swatch a picker draws: the theme's canvas, its surface and its accent, in one shape.
    public var swatch: [Color] { [canvas, surfaceRaised, accent] }
}

/// The themes that ship.
public enum ThemeCatalog {
    /// The app's own palette, and the one a fresh install gets.
    ///
    /// Rakazo's monochrome shell is the house look now: ink on near-black, one blue for unread and
    /// working, one green for success. The earlier OpenBot palette stays in the catalogue, so a
    /// restyle that does not land is one pick away from the old face.
    public static let defaultID = "rakazo"

    public static let all: [ThemePalette] = [
        rakazo,
        openbot,
        gruvbox,
        tokyoNight,
        catppuccin,
        dracula,
        nord,
    ]

    public static func theme(id: String) -> ThemePalette {
        all.first { $0.id == id } ?? rakazo
    }

    // MARK: - Palettes

    /// The shell's own palette, ported from Rakazo's `webDarkTokens`
    /// (`packages/ui-tokens/src/index.ts`): `background #0A0A0A`, `muted #232323`, ink `#F5F5F5`,
    /// `unread`/`statusWorking #4D9BFF`, `success #00BA69`, `warning #E28600`, `destructive #FF6463`.
    ///
    /// Text tones are the palette's alphas flattened onto this canvas, because a SwiftUI `Color` in
    /// a token table has to be one value: `mutedForeground #F5F5F5A8` → `#A5A5A5`,
    /// `faintForeground #F5F5F58A` → `#898989`, both composited over `#0A0A0A`.
    public static let rakazo = ThemePalette.make(
        id: "rakazo", name: "Rakazo",
        canvas: 0x0A0A0A, frame: 0x0A0A0A, surface: 0x232323, surfaceHigh: 0x2B2B2B,
        sheet: 0x161616,
        text: 0xF5F5F5, textMuted: 0xA5A5A5, textDim: 0x898989,
        accent: 0x4D9BFF, accentText: 0x4D9BFF,
        success: 0x00BA69, warning: 0xE28600, danger: 0xFF6463,
        borderAlpha: 0.10)

    /// The palette this app shipped before the Rakazo shell, kept for the way back.
    public static let openbot = ThemePalette.make(
        id: "openbot", name: "OpenBot",
        canvas: 0x1A1A1A, frame: 0x0D0D0D, surface: 0x212121, surfaceHigh: 0x242424,
        sheet: 0x141414,
        text: 0xFFFFFF, textMuted: 0x979797, textDim: 0x6A6A6A,
        accent: 0x007CF7, accentText: 0x42A0FF,
        success: 0x31CF76, warning: 0xFF9412, danger: 0xFD2F3B,
        borderAlpha: 0.045)

    public static let gruvbox = ThemePalette.make(
        id: "gruvbox", name: "Gruvbox",
        canvas: 0x282828, frame: 0x1D2021, surface: 0x32302F, surfaceHigh: 0x3C3836,
        sheet: 0x1D2021,
        text: 0xEBDBB2, textMuted: 0xA89984, textDim: 0x928374,
        accent: 0xD65D0E, accentText: 0xFE8019,
        success: 0xB8BB26, warning: 0xD79921, danger: 0xFB4934,
        borderAlpha: 0.07)

    public static let tokyoNight = ThemePalette.make(
        id: "tokyo-night", name: "Tokyo Night",
        canvas: 0x1A1B26, frame: 0x16161E, surface: 0x1F2335, surfaceHigh: 0x292E42,
        sheet: 0x16161E,
        text: 0xC0CAF5, textMuted: 0x7A88C0, textDim: 0x565F89,
        accent: 0x7AA2F7, accentText: 0x7DCFFF,
        success: 0x9ECE6A, warning: 0xE0AF68, danger: 0xF7768E,
        borderAlpha: 0.06)

    public static let catppuccin = ThemePalette.make(
        id: "catppuccin", name: "Catppuccin",
        canvas: 0x1E1E2E, frame: 0x181825, surface: 0x313244, surfaceHigh: 0x45475A,
        sheet: 0x181825,
        text: 0xCDD6F4, textMuted: 0xA6ADC8, textDim: 0x7F849C,
        accent: 0x89B4FA, accentText: 0xB4BEFE,
        success: 0xA6E3A1, warning: 0xF9E2AF, danger: 0xF38BA8,
        borderAlpha: 0.07)

    public static let dracula = ThemePalette.make(
        id: "dracula", name: "Dracula",
        canvas: 0x282A36, frame: 0x21222C, surface: 0x30323F, surfaceHigh: 0x44475A,
        sheet: 0x21222C,
        text: 0xF8F8F2, textMuted: 0xB0B4CC, textDim: 0x6272A4,
        accent: 0xBD93F9, accentText: 0xFF79C6,
        success: 0x50FA7B, warning: 0xFFB86C, danger: 0xFF5555,
        borderAlpha: 0.07)

    public static let nord = ThemePalette.make(
        id: "nord", name: "Nord",
        canvas: 0x2E3440, frame: 0x272C36, surface: 0x3B4252, surfaceHigh: 0x434C5E,
        sheet: 0x272C36,
        text: 0xECEFF4, textMuted: 0xAAB3C4, textDim: 0x7B8598,
        accent: 0x88C0D0, accentText: 0x8FBCBB,
        success: 0xA3BE8C, warning: 0xEBCB8B, danger: 0xBF616A,
        borderAlpha: 0.07)
}

// MARK: - The active theme

/// Which palette `Tokens` should read.
///
/// `nonisolated(unsafe)`: these colours are read from view bodies (main thread) and from a handful of
/// static helpers. The only write is the user's choice, and every root re-creates its view tree on
/// that change, so there is no moment where half the app wears one palette and half the other.
public enum ThemeRuntime {
    public nonisolated(unsafe) static var active: ThemePalette = ThemeCatalog.theme(id: ThemeCatalog.defaultID)

    /// The `UserDefaults` key a root watches. It lives here so the picker and the two roots cannot
    /// disagree about where the choice is written.
    public static let defaultsKey = "hermey.theme"

    /// Read the stored choice and make it the active palette. Called by each root before it draws.
    ///
    /// One migration rides along: an install that never chose a theme is wearing the old default by
    /// accident, not by preference, so it moves to the new house palette once. A stored choice of
    /// any *other* theme is left exactly as the user left it.
    @discardableResult
    public static func restoreFromDefaults() -> String {
        let stored = UserDefaults.standard.string(forKey: defaultsKey)
        let migratedKey = "hermey.theme.migrated.rakazo"
        if UserDefaults.standard.bool(forKey: migratedKey) == false {
            UserDefaults.standard.set(true, forKey: migratedKey)
            if stored == nil || stored == "openbot" {
                UserDefaults.standard.set(ThemeCatalog.defaultID, forKey: defaultsKey)
                active = ThemeCatalog.theme(id: ThemeCatalog.defaultID)
                return ThemeCatalog.defaultID
            }
        }
        let id = stored ?? ThemeCatalog.defaultID
        active = ThemeCatalog.theme(id: id)
        return id
    }

    public static func apply(id: String) {
        active = ThemeCatalog.theme(id: id)
        UserDefaults.standard.set(id, forKey: defaultsKey)
    }

    /// The next theme in the catalogue — what the palette's "change theme" verb uses.
    public static func next(after id: String) -> ThemePalette {
        let all = ThemeCatalog.all
        guard let index = all.firstIndex(where: { $0.id == id }) else { return all[0] }
        return all[(index + 1) % all.count]
    }
}

// MARK: - Building a palette from a dozen numbers

private extension ThemePalette {
    /// Blend two hex colours, `t` being how far to `b`.
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        let t = min(max(t, 0), 1)
        func channel(_ shift: UInt32) -> UInt32 {
            let av = Double((a >> shift) & 0xFF)
            let bv = Double((b >> shift) & 0xFF)
            return UInt32((av + (bv - av) * t).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }

    static func make(id: String,
                     name: String,
                     canvas: UInt32,
                     frame: UInt32,
                     surface: UInt32,
                     surfaceHigh: UInt32,
                     sheet: UInt32,
                     text: UInt32,
                     textMuted: UInt32,
                     textDim: UInt32,
                     accent: UInt32,
                     accentText: UInt32,
                     success: UInt32,
                     warning: UInt32,
                     danger: UInt32,
                     borderAlpha: Double) -> ThemePalette {
        // A hovered control is the surface nudged toward the text; a dimmer sheet is the sheet
        // pulled toward black. Deriving these keeps each theme a dozen real decisions.
        let active = mix(surfaceHigh, text, 0.06)
        return ThemePalette(
            id: id, name: name,
            canvas: Color(hex: canvas),
            frame: Color(hex: frame),
            sidebar: Color(hex: canvas),
            surface: Color(hex: surface),
            surfaceRaised: Color(hex: surfaceHigh),
            control: Color(hex: surface),
            controlHover: Color(hex: surfaceHigh),
            controlActive: Color(hex: active),
            sheet: Color(hex: sheet),
            sheetInset: Color(hex: mix(sheet, 0x000000, 0.35)),
            grouped: Color(hex: surface),
            textPrimary: Color(hex: text),
            textSecondary: Color(hex: mix(text, canvas, 0.22)),
            textMuted: Color(hex: textMuted),
            textDim: Color(hex: textDim),
            textPlaceholder: Color(hex: mix(textMuted, text, 0.35)),
            textGroupedSecondary: Color(hex: textMuted),
            accent: Color(hex: accent),
            accentHover: Color(hex: accentText),
            accentText: Color(hex: accentText),
            success: Color(hex: success),
            warning: Color(hex: warning),
            danger: Color(hex: danger),
            border: Color.white.opacity(borderAlpha * 0.75),
            borderStrong: Color.white.opacity(borderAlpha),
            borderGrouped: Color(hex: mix(surface, text, 0.18)))
    }
}
