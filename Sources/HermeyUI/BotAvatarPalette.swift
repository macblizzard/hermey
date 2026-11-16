import Foundation

/// One entry of the reference's bot palette: an id, the name a picker shows, and the one hex.
public struct BotAvatarColorDef: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// The bot's one colour: its avatar, its name and its bubble all start from it.
    public var hex: String
    /// A deeper value this colour used to be stored as; existing bots still resolve through it.
    public var previousHex: String?

    public init(id: String, name: String, hex: String, previousHex: String? = nil) {
        self.id = id
        self.name = name
        self.hex = hex
        self.previousHex = previousHex
    }

    /// The lower-case form used for matching, exactly as `resolvePersonaColorDef` lower-cases the
    /// value it was given.
    var hexValue: String { hex.lowercased() }
}

/// The one bot palette, the eye-ink rule and the small colour maths around them.
///
/// Ported from `packages/core/src/bot-avatar-colors.ts` and `packages/contracts/src/bot-avatar.ts`.
/// The list is the same eleven entries in the same order with the same hexes: the order is load
/// bearing, because the identity hash picks an index into it.
public enum BotAvatarPalette {

    /// `BOT_COLOR_LIST`, in order.
    public static let colors: [BotAvatarColorDef] = [
        BotAvatarColorDef(id: "white", name: "Staff White", hex: "#FFFFFF"),
        BotAvatarColorDef(id: "violet", name: "Executive Violet", hex: "#A97EFE", previousHex: "#8B5CF6"),
        BotAvatarColorDef(id: "green", name: "Emerald", hex: "#00C972", previousHex: "#10B981"),
        BotAvatarColorDef(id: "orange", name: "Forge Orange", hex: "#FF781C", previousHex: "#F97316"),
        BotAvatarColorDef(id: "cyan", name: "Cyber Cyan", hex: "#1CC3B0", previousHex: "#06B6D4"),
        BotAvatarColorDef(id: "blue", name: "Cobalt Blue", hex: "#2A92FE", previousHex: "#3B82F6"),
        BotAvatarColorDef(id: "yellow", name: "Amber Gold", hex: "#FFAF38", previousHex: "#EAB308"),
        BotAvatarColorDef(id: "brown", name: "Caramel Bronze", hex: "#A27952", previousHex: "#8D6E63"),
        BotAvatarColorDef(id: "red", name: "Crimson Red", hex: "#FF3E51", previousHex: "#EF4444"),
        BotAvatarColorDef(id: "magenta", name: "Neon Pink", hex: "#FF5EB1", previousHex: "#EC4899"),
        BotAvatarColorDef(id: "gray", name: "Slate Silver", hex: "#94A3B8", previousHex: "#64748B"),
    ]

    /// Every hex the palette offers, in order — `BOT_COLORS`.
    public static var hexes: [String] { colors.map(\.hex) }

    /// The reset/fallback colour: Executive Violet.
    public static let defaultColor: BotAvatarColorDef =
        colors.first { $0.id == "violet" } ?? BotAvatarColorDef(id: "violet", name: "Executive Violet", hex: "#A97EFE")

    /// The five the invite artwork draws, white being invisible on a light page.
    public static let inviteColors: [BotAvatarColorDef] = ["violet", "green", "orange", "cyan", "blue"]
        .compactMap { id in colors.first { $0.id == id } }

    /// A palette entry by id, the way a picker stores it.
    public static func color(id: String) -> BotAvatarColorDef? {
        colors.first { $0.id == id }
    }

    /// The entry a stored value names — by id, by display name, by current hex or by the deeper hex
    /// it used to be saved as. Matching is case-insensitive, as in `resolvePersonaColorDef`.
    ///
    /// Returns `nil` for anything that is not a palette entry, including a custom hex: the caller
    /// decides whether an unmatched value is custom ink or a reason to fall back to the hash.
    public static func match(_ value: String) -> BotAvatarColorDef? {
        let clean = value.lowercased()
        if let byName = colors.first(where: { $0.id == clean || $0.name.lowercased() == clean }) {
            return byName
        }
        return colors.first { color in
            color.hexValue == clean || color.previousHex?.lowercased() == clean
        }
    }

    /// True for `#abc` and `#aabbcc`.
    public static func isHexColor(_ value: String) -> Bool {
        guard value.hasPrefix("#") else { return false }
        let digits = value.dropFirst()
        guard digits.count == 3 || digits.count == 6 else { return false }
        return digits.allSatisfy { $0.isHexDigit }
    }

    /// `#rgb` widened to `#rrggbb`; a six-digit value comes back unchanged. The `#` is optional, as
    /// `expandHex` treats it.
    public static func expandedHex(_ hex: String) -> String {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 3 else { return digits }
        var expanded = ""
        for character in digits {
            expanded.append(character)
            expanded.append(character)
        }
        return expanded
    }

    // MARK: - Contrast

    /// WCAG relative luminance, with the reference's `0.03928` knee.
    public static func relativeLuminance(_ hex: String) -> Double {
        let digits = expandedHex(hex)
        let characters = Array(digits)
        guard characters.count >= 6 else { return 0 }
        var channels: [Double] = []
        for offset in stride(from: 0, to: 6, by: 2) {
            let slice = String(characters[offset..<(offset + 2)])
            let raw = Double(Int(slice, radix: 16) ?? 0) / 255
            channels.append(raw <= 0.03928 ? raw / 12.92 : pow((raw + 0.055) / 1.055, 2.4))
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }

    /// WCAG contrast ratio between two hex colours.
    public static func contrastRatio(_ a: String, _ b: String) -> Double {
        let values = [relativeLuminance(a), relativeLuminance(b)].sorted(by: >)
        return (values[0] + 0.05) / (values[1] + 0.05)
    }

    // MARK: - Eyes

    /// Which ink a bot's eyes take.
    public enum EyeTone: String, Hashable, Sendable {
        /// Cut out in the page colour: the default, and what makes the face look like a hole.
        case page
        /// The body is pale enough that a white cut-out would vanish, so the bars go dark.
        case dark
        /// The body is dark enough that a page-coloured bar would vanish, so the bars go light.
        case light
    }

    /// `botEyeTone`: pale bodies (contrast with white under 2.4) get dark bars, very dark bodies
    /// (contrast with black under 2) get light ones, and everything else is a cut-out.
    public static func eyeTone(forBody hex: String) -> EyeTone {
        if contrastRatio(hex, "#FFFFFF") < 2.4 { return .dark }
        if contrastRatio(hex, "#000000") < 2 { return .light }
        return .page
    }

    /// `botEyeInk`: the tone above, resolved against the two colours of the page the avatar sits on.
    ///
    /// A cut-out is the page's own background. For the rare pale or dark body the reference picks
    /// whichever of the page's two colours is further from white — darker for a pale body, lighter
    /// for a dark one — so the bars cannot fade into the page in either theme.
    public static func eyeInk(forBody body: String,
                              pageBackground: String,
                              pageForeground: String) -> String {
        switch eyeTone(forBody: body) {
        case .page:
            return pageBackground
        case .dark:
            return contrastRatio(pageBackground, "#FFFFFF") > contrastRatio(pageForeground, "#FFFFFF")
                ? pageBackground : pageForeground
        case .light:
            return contrastRatio(pageBackground, "#FFFFFF") > contrastRatio(pageForeground, "#FFFFFF")
                ? pageForeground : pageBackground
        }
    }
}
