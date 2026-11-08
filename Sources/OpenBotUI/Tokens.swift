import SwiftUI

/// The OpenBot design system.
///
/// Every value here is a direct port of `packages/brand/src/tokens.css` from the
/// OpenBot clone (dark palette). That file is the single declaration site upstream;
/// this one is its Swift mirror. Do not add a colour anywhere else in the app — if a
/// component needs a new shade, add the token here first, with the upstream name in
/// the comment, so the two files can be diffed.
///
/// Colours are **computed**: each one reads the active `ThemePalette`, so a theme change is a value
/// in `ThemeCatalog` rather than a pass over every view. Radius and type are fixed — a theme is
/// colour, not geometry.
public enum Tokens {

    // MARK: Surfaces
    public static var canvas: Color { ThemeRuntime.active.canvas }
    public static var frame: Color { ThemeRuntime.active.frame }
    public static var sidebar: Color { ThemeRuntime.active.sidebar }
    public static var surface: Color { ThemeRuntime.active.surface }
    public static var surfaceRaised: Color { ThemeRuntime.active.surfaceRaised }
    public static var control: Color { ThemeRuntime.active.control }
    public static var controlHover: Color { ThemeRuntime.active.controlHover }
    public static var controlActive: Color { ThemeRuntime.active.controlActive }
    public static var sheet: Color { ThemeRuntime.active.sheet }
    public static var sheetInset: Color { ThemeRuntime.active.sheetInset }
    public static var grouped: Color { ThemeRuntime.active.grouped }

    // MARK: Text
    public static var textPrimary: Color { ThemeRuntime.active.textPrimary }
    public static var textSecondary: Color { ThemeRuntime.active.textSecondary }
    public static var textMuted: Color { ThemeRuntime.active.textMuted }
    public static var textDim: Color { ThemeRuntime.active.textDim }
    public static var textPlaceholder: Color { ThemeRuntime.active.textPlaceholder }
    public static var textGroupedSecondary: Color { ThemeRuntime.active.textGroupedSecondary }

    // MARK: Accent and status
    public static var accent: Color { ThemeRuntime.active.accent }
    public static var accentHover: Color { ThemeRuntime.active.accentHover }
    public static var accentText: Color { ThemeRuntime.active.accentText }
    /// The accent as a wash behind a selected row. Derived, so a theme's accent tints its own
    /// selection instead of keeping the default blue's.
    public static var accentSoft: Color { accent.opacity(0.16) }
    public static var success: Color { ThemeRuntime.active.success }
    public static var successSoft: Color { success.opacity(0.12) }
    public static var warning: Color { ThemeRuntime.active.warning }
    public static var warningSoft: Color { warning.opacity(0.12) }
    public static var danger: Color { ThemeRuntime.active.danger }
    public static var dangerSoft: Color { danger.opacity(0.16) }

    // MARK: Borders
    public static var border: Color { ThemeRuntime.active.border }
    public static var borderStrong: Color { ThemeRuntime.active.borderStrong }
    public static var borderGrouped: Color { ThemeRuntime.active.borderGrouped }
    public static var borderFocus: Color { ThemeRuntime.active.textMuted }

    // MARK: Radius
    public static let radiusGrouped: CGFloat = 16
    public static let radiusCard: CGFloat = 12
    public static let radiusControl: CGFloat = 9
    public static let radiusSmall: CGFloat = 6

    // MARK: Type scale (--openbot-text-sm/md/lg/xl)
    public static let textSM: CGFloat = 12
    public static let textMD: CGFloat = 13
    public static let textLG: CGFloat = 14
    public static let textXL: CGFloat = 16

    /// Chat body. OpenBot draws chat text at 16 pt on a 22 pt line on iOS and 14/1.62
    /// on the desktop; both are one table there (`chat-text-styles.ts`) and one table
    /// here, so every way of drawing a message agrees.
    public static let chatBodyMacOS: CGFloat = 14
    public static let chatBodyIOS: CGFloat = 16
    public static let chatLineIOS: CGFloat = 22

    public static let mono = Font.system(size: 11.5, weight: .regular, design: .monospaced)
}

// MARK: - Geometry (src/renderer/src/layout-constants.ts)

public enum Geometry {
    public static let serverRailMacOS: CGFloat = 72      // MAC_SERVER_RAIL_WIDTH
    public static let serverRail: CGFloat = 64           // SERVER_RAIL_WIDTH
    public static let serverRailNarrow: CGFloat = 56     // NARROW_SERVER_RAIL_WIDTH
    public static let sidebarDefault: CGFloat = 280      // LEFT_PANEL_DEFAULT
    public static let sidebarMin: CGFloat = 128
    public static let sidebarMax: CGFloat = 400
    public static let sidebarCompact: CGFloat = 88
    public static let sidebarCollapseBelow: CGFloat = 110
    public static let conversationMin: CGFloat = 424     // CONVERSATION_MIN_WIDTH
    public static let contextPanel: CGFloat = 236
    public static let conversationMeasure: CGFloat = 640
    /// One inset for the conversation column: header, transcript, approval cards, composer and
    /// error strips all start here, so their left edges cannot drift apart.
    public static let readingInset: CGFloat = 24
    /// One inset for the bot panel: its header, rows, empty states and host chip agree.
    public static let sidebarInset: CGFloat = 12
    /// The window's own rounded clip, and the floating palette's.
    public static let radiusWindow: CGFloat = 13
    public static let radiusPalette: CGFloat = 14
    /// The divider between the bot panel and the conversation (hit area, not visual width).
    public static let paneDivider: CGFloat = 7
}

// MARK: - Helpers

public extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

public extension View {
    /// The 1 px hairline every OpenBot surface uses.
    func hairlineBorder(_ radius: CGFloat = Tokens.radiusCard) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Tokens.borderStrong, lineWidth: 1)
        )
    }
}
