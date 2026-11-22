import SwiftUI

/// The colours and radii a card draws with, injected rather than imported.
///
/// `HermesCards` deliberately depends on `HermesKit` only: it must be testable as a pure value
/// module and must not pull the whole design system into a package a bot-facing target links.
/// The app therefore hands its real palette in once, where it wires the card view:
///
///     CardView(model: model, theme: CardTheme(canvas: Tokens.canvas,
///                                            surface: Tokens.surface,
///                                            ink: Tokens.textPrimary,
///                                            mutedInk: Tokens.textMuted,
///                                            accent: Tokens.accent,
///                                            accentInk: Tokens.textPrimary,
///                                            danger: Tokens.danger,
///                                            border: Tokens.border))
///
/// `CardTheme()` is the light "Parchment" palette's own values (canvas `#FAF9F5`, surface
/// `#F0EEE6`, ink `#141413`, accent `#CC6543`), so an app that passes nothing still gets the
/// house look rather than a stray system grey.
public struct CardTheme {
    /// The page behind a card; used for a neutral button's fill.
    public var canvas: Color
    /// The card's own fill.
    public var surface: Color
    /// Titles and body text.
    public var ink: Color
    /// Labels, muted values and the unavailable message.
    public var mutedInk: Color
    /// The primary button's fill.
    public var accent: Color
    /// Text on the accent fill. On the light palette the label is ink, not white: `#141413` on
    /// `#CC6543` is 5.9:1, where white is 3.1:1.
    public var accentInk: Color
    /// The destructive tint: a `danger` button's text and its hairline.
    public var danger: Color
    /// Hairline border.
    public var border: Color

    public var radiusCard: CGFloat
    public var radiusControl: CGFloat

    /// The house palette. Values live in the body rather than in default arguments: a public
    /// default argument may not name a private helper, and the hex initialiser is private to
    /// this file.
    public init() {
        self.init(canvas: Color(cardHex: 0xFAF9F5),
                  surface: Color(cardHex: 0xF0EEE6),
                  ink: Color(cardHex: 0x141413),
                  mutedInk: Color(cardHex: 0x6C6A64),
                  accent: Color(cardHex: 0xCC6543),
                  accentInk: Color(cardHex: 0x141413),
                  danger: Color(cardHex: 0xB3392B),
                  border: Color(cardHex: 0xE3DACC))
    }

    public init(canvas: Color,
                surface: Color,
                ink: Color,
                mutedInk: Color,
                accent: Color,
                accentInk: Color,
                danger: Color,
                border: Color,
                radiusCard: CGFloat = 16,
                radiusControl: CGFloat = 10) {
        self.canvas = canvas
        self.surface = surface
        self.ink = ink
        self.mutedInk = mutedInk
        self.accent = accent
        self.accentInk = accentInk
        self.danger = danger
        self.border = border
        self.radiusCard = radiusCard
        self.radiusControl = radiusControl
    }

    /// The default palette above, named for call sites that want to say so explicitly.
    public static let hermey = CardTheme()
}

private extension Color {
    /// `0xRRGGBB`, the form the token tables are written in. Named to avoid colliding with the
    /// app's own hex helper if both modules are imported in one scope.
    init(cardHex hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
