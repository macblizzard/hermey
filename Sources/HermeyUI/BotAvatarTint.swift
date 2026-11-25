import Foundation
import SwiftUI

/// **The one colour a bot is drawn in** — its face, its name, and the bubble around what it says.
///
/// A bot's colour used to be `bots.color` read at each surface, which was right while a face *was*
/// a shape and a palette swatch. A bot with a drawn avatar carries a second colour — the one stored
/// beside its definition (`BotAvatarDocument.color`) — and nothing on the reading surfaces knew
/// about it, so a bot whose avatar is green kept a blue bubble. Reported by Mohammad, 2026-11-25.
///
/// The rule, in order, and it is the *only* place the rule exists:
///
/// 1. a bot with a drawn avatar (a definition, with or without a material) wears that document's
///    stored colour, or the house colour its renderer paints it in when none was stored;
/// 2. otherwise the shape/photo face's colour, resolved through `BotFaceChoice` and
///    `BotAvatarIdentity` — the same resolution the face itself draws from;
/// 3. otherwise the colour the bot's id derives.
///
/// Two surfaces asking this question must get the same answer, or a bot ends up green in the header
/// and blue under its words. That is why every one of them calls `resolve` rather than writing the
/// expression out: the expression was already copied into two view files before this type existed,
/// and neither copy knew about drawn avatars.
public struct BotAvatarTint: Hashable {
    /// `#RRGGBB`, upper case: one spelling per colour, so two resolutions of one bot compare equal.
    public let hex: String
    /// The same colour, ready to draw with.
    public let color: Color

    public init(hex: String) {
        let normalised = BotAvatarTint.normalised(hex)
        self.hex = normalised
        self.color = OpenBotAvatarColor.color(hex: normalised) ?? Self.houseColor
    }

    /// The colour `OpenBotAvatarRenderer` paints a document that stored none — `1.0, 0.416, 0.102`.
    public static let houseHex = "#FF6A1A"
    static let houseColor = Color(red: 1.0, green: 0.416, blue: 0.102)

    /// `#rgb` widened and upper-cased; a six-digit value comes back as it went in, re-cased.
    static func normalised(_ hex: String) -> String {
        "#" + BotAvatarPalette.expandedHex(hex).uppercased()
    }

    // MARK: - Resolving one bot

    /// A bot's colour, from the host's two answers about its face.
    ///
    /// - Parameters:
    ///   - botID: the bot the colour is for; the id is the seed of the third rule.
    ///   - face: the stored shape face (`bots.color`), or nil when the bot has none.
    ///   - document: the host's drawn avatar for this bot, or nil.
    public static func resolve(botID: String,
                               face: BotFaceChoice?,
                               document: BotAvatarDocument?) -> BotAvatarTint {
        if let document {
            // The drawn avatar owns the colour: its stored one when it has a legible hex, else the
            // house colour its renderer falls back to. Reading `bots.color` here would repaint a
            // face that was saved after it — the same rule `BotAvatarView` follows for the body.
            if let stored = document.color, BotAvatarPalette.isHexColor(stored) {
                return BotAvatarTint(hex: stored)
            }
            return BotAvatarTint(hex: houseHex)
        }
        let resolved = face?.identity(for: botID) ?? BotAvatarIdentity.resolve(identity: botID)
        return BotAvatarTint(hex: resolved.color.hex)
    }

    /// The same rule for a surface that already carries the host's map (`BotAvatarLibrary`).
    public static func resolve(botID: String,
                               face: BotFaceChoice?,
                               avatars: BotAvatarLibrary) -> BotAvatarTint {
        resolve(botID: botID, face: face, document: avatars[botID])
    }

    // MARK: - The bubble

    /// The three colours a bot's own message is painted in.
    ///
    /// Fill, border and ink are all derived from the bot's one colour, and the ink is *measured*
    /// against the fill rather than assumed — a bubble that hard-codes white text breaks the first
    /// time a bot wears Amber Gold.
    public func bubble(lightPage: Bool) -> BotAvatarBubble {
        BotAvatarBubble(tintHex: hex, lightPage: lightPage)
    }
}

/// A bot's own message, painted in its colour.
///
/// **Why a deep shade on a dark page and a pale one on a light page.** A bubble fill at the colour's
/// own mid-tone cannot carry body text at a readable contrast: the best of black and white is about
/// 4.5:1 on a mid luminance, which is the floor and not a comfortable place to sit. So the fill is
/// the bot's colour moved *away* from the page — 72 % toward black on Midnight, 78 % toward white on
/// Parchment — which keeps the hue legible (a deep emerald, a pale emerald) and puts the text at
/// 9:1 or better. The **border** is the same colour moved the *other* way, so the bubble's edge
/// reads as the bot's actual colour even where the fill is a shade of it, and the shape is carried
/// by a 1 pt line on both pages.
///
/// **Why the ink is computed.** `ink` is whichever of the two ends of the scale contrasts better
/// with `fillHex`, measured with the palette's own WCAG ratio (`BotAvatarPalette.contrastRatio`) —
/// the same maths `BotAvatarPalette.eyeTone` already applies to a face's eyes. Today that always
/// lands on white for a dark fill and near-black for a pale one, which is the point: it is a fact
/// about the fill, not a constant, so a palette entry added later is legible without being looked
/// at.
public struct BotAvatarBubble: Hashable {
    /// The bot's colour, unchanged — what the border and the fill are both mixed from.
    public let tintHex: String
    /// An opaque fill: the ink's contrast is a fact about the bubble, not about the page behind it.
    public let fillHex: String
    public let borderHex: String
    public let inkHex: String

    public init(tintHex: String, lightPage: Bool) {
        let tint = BotAvatarTint(tintHex).hex
        let fillMix = lightPage ? BotAvatarBubble.lightFillMix : BotAvatarBubble.darkFillMix
        let borderMix = lightPage ? BotAvatarBubble.lightBorderMix : BotAvatarBubble.darkBorderMix
        self.tintHex = tint
        self.fillHex = BotAvatarBubble.mixed(tint, toward: lightPage ? "#FFFFFF" : "#000000", fillMix)
        self.borderHex = BotAvatarBubble.mixed(tint, toward: lightPage ? "#000000" : "#FFFFFF", borderMix)
        self.inkHex = BotAvatarBubble.ink(forFill: self.fillHex)
    }

    // MARK: - The numbers

    /// How far the fill is moved away from the page. Measured, not chosen by eye: over the palette's
    /// eleven colours these give a text contrast of at least 9.3:1 on Midnight and 14.8:1 on
    /// Parchment, and the border stays at least 2.2:1 from its own fill, so the edge is an edge.
    public static let darkFillMix: Double = 0.72
    public static let lightFillMix: Double = 0.78
    /// How far the border is moved the other way, so it reads as the bot's colour rather than the
    /// fill's.
    public static let darkBorderMix: Double = 0.35
    public static let lightBorderMix: Double = 0.32

    /// The two ends of the ink scale. Not "white and black": the app's own darkest ink and the
    /// lightest ink it writes in, so a computed ink is still a colour this app uses.
    public static let inkOnDark = "#FFFFFF"
    public static let inkOnLight = "#0B0B0F"

    /// The ink for a fill: the end of the scale with the better contrast, measured.
    public static func ink(forFill fill: String) -> String {
        BotAvatarPalette.contrastRatio(fill, inkOnLight) >= BotAvatarPalette.contrastRatio(fill, inkOnDark)
            ? inkOnLight : inkOnDark
    }

    /// `a` moved `amount` of the way to `b`, channel by channel, as `#RRGGBB`.
    ///
    /// The same linear blend `BotAvatarMaterial` uses to light and darken a body, kept here because
    /// the bubble is not a material: it is one page colour's worth of distance from the bot's colour.
    public static func mixed(_ a: String, toward b: String, _ amount: Double) -> String {
        let t = min(max(amount, 0), 1)
        let left = BotAvatarPalette.expandedHex(a)
        let right = BotAvatarPalette.expandedHex(b)
        func channel(_ text: String, _ offset: Int) -> Double {
            let start = text.index(text.startIndex, offsetBy: offset)
            let end = text.index(start, offsetBy: 2)
            return Double(Int(text[start..<end], radix: 16) ?? 0)
        }
        guard left.count == 6, right.count == 6 else { return BotAvatarTint.normalised(a) }
        var out = "#"
        for offset in stride(from: 0, to: 6, by: 2) {
            let from = channel(left, offset)
            let to = channel(right, offset)
            let value = Int((from + (to - from) * t).rounded())
            out += String(format: "%02X", max(0, min(255, value)))
        }
        return out
    }

    // MARK: - Drawing

    public var fill: Color { OpenBotAvatarColor.color(hex: fillHex) ?? Tokens.surface }
    public var border: Color { OpenBotAvatarColor.color(hex: borderHex) ?? Tokens.border }
    public var ink: Color { OpenBotAvatarColor.color(hex: inkHex) ?? Tokens.textPrimary }
}
