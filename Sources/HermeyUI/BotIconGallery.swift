import Foundation
import HermesKit
import SwiftUI

/// The user's own choice for a bot's face, in the reference's stored form.
///
/// One string — `#RRGGBB::shape_N` — because that is what `bots.color` holds on the web app, and a
/// bot that looks one way here has to look the same way there. The single field is the whole point:
/// a colour and a shape travelling separately is how the two sides drift apart (and it is what the
/// old `{shape, color}` payload did).
///
/// Three shapes of value are valid, and all three mean something concrete:
///
/// * `#FF781C::shape_5` — a colour **and** a body. What this picker writes.
/// * `#FF781C` — a colour only; the body comes from the bot's id, exactly as a bot with nothing
///   stored resolves. Writable by an older palette picker, and by the web.
/// * a palette id or name (`violet`, `Executive Violet`) — `BotAvatarStoredValue.parse` reads it,
///   and `BotAvatarIdentity.resolve` maps it to its hex.
///
/// Everything goes back through `BotAvatarStoredValue.parse` (aliased as `BotAvatarIdentity.parse`),
/// so there is exactly one reader of this format in the app.
public struct BotFaceChoice: Hashable, Codable, Sendable, RawRepresentable {

    /// The stored value, verbatim: `#RRGGBB`, `#RRGGBB::shape_N`, or a palette id/name.
    public var raw: String

    /// `RawRepresentable`'s door, so this type can be an `@AppStorage` value and a dictionary key
    /// without a second spelling of the string.
    public var rawValue: String { raw }

    /// Non-failing: internal construction always starts from a value this type built or validated.
    private init(value raw: String) {
        self.raw = raw
    }

    /// Fails for anything that would draw differently from what it says — an empty string, a
    /// `data:` URL (a photo is not this picker's business), a bare word that is not in the palette.
    public init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isStorable(trimmed) else { return nil }
        self.raw = trimmed
    }

    /// True for a value `BotAvatarIdentity.resolve` can draw a shape for.
    public static func isStorable(_ raw: String) -> Bool {
        switch BotAvatarIdentity.parse(raw) {
        case .image:
            return false
        case .shape(let color, _):
            return BotAvatarPalette.isHexColor(color) || BotAvatarPalette.match(color) != nil
        case .color:
            return true
        case .other(let value):
            return BotAvatarPalette.match(value) != nil
        }
    }

    /// Build the canonical form the reference stores.
    public static func make(colorHex: String, shapeIndex: Int) -> BotFaceChoice {
        let index = BotAvatarShape.normalized(index: shapeIndex)
        return BotFaceChoice(value: "\(normalisedHex(colorHex))::shape_\(index)")
    }

    /// A colour-only value: the body is derived from the bot's id.
    public static func make(colorHex: String) -> BotFaceChoice {
        BotFaceChoice(value: normalisedHex(colorHex))
    }

    /// `#rgb` widened to `#rrggbb` and upper-cased, so the same choice written twice is one string.
    static func normalisedHex(_ hex: String) -> String {
        let expanded = BotAvatarPalette.expandedHex(hex)
        return "#" + expanded.uppercased()
    }

    // MARK: - Reading it back

    /// What the parser made of `raw`.
    public var stored: BotAvatarStoredValue { BotAvatarIdentity.parse(raw) }

    /// The colour, as stored: a hex (custom or palette) or a palette token.
    public var colorHex: String? {
        switch stored {
        case .shape(let color, _): return color
        case .color(let color): return color
        case .other(let value): return BotAvatarPalette.match(value)?.hex
        case .image: return nil
        }
    }

    /// The body the value names, or `nil` when it leaves the body to the bot's id.
    public var shapeIndex: Int? {
        if case .shape(_, let index) = stored { return index }
        return nil
    }

    /// The resolved face: colour, body, and — when the value named one — the explicit body.
    public func identity(for botID: String) -> BotAvatarIdentity {
        BotAvatarIdentity.resolve(identity: botID, explicitColor: raw)
    }

    /// What a `BotAvatarView` should be handed: the stored string, unchanged.
    public var avatarColor: String { raw }

    // MARK: - Migration

    /// The sixteen silhouettes the old shape map drew, in their own order.
    ///
    /// Kept only here, only for reading a choice made before this build: `index % 8` lands each of
    /// them on one of the eight shipped bodies, deterministically, so nobody's bot changes body
    /// twice and a chosen shape is never silently dropped.
    static let legacyShapeOrder: [String] = [
        "ember", "nova", "cobalt", "orbit", "moss", "dusk", "beacon", "pixel",
        "rover", "prism", "lump", "mushroom", "blob", "capsule", "droplet", "scallop",
    ]

    /// The twelve old swatches, mapped to the palette entry that is closest by name.
    ///
    /// Not a colour-distance search: the old set was pitched as hues ("teal", "ruby"), the palette
    /// is pitched as roles ("Cyber Cyan", "Crimson Red"), and the role is what makes a bot's bubble,
    /// name and face agree again. A value missing from this table keeps the id's own colour.
    static let legacyColors: [String: String] = [
        "orange": "#FF781C",   // Forge Orange
        "amber": "#FFAF38",    // Amber Gold
        "lime": "#00C972",     // Emerald
        "mint": "#00C972",
        "teal": "#1CC3B0",     // Cyber Cyan
        "cyan": "#1CC3B0",
        "blue": "#2A92FE",     // Cobalt Blue
        "indigo": "#A97EFE",   // Executive Violet
        "purple": "#A97EFE",
        "pink": "#FF5EB1",     // Neon Pink
        "ruby": "#FF3E51",     // Crimson Red
        "slate": "#94A3B8",    // Slate Silver
    ]

    /// A choice made by the old `BotFaceChoice{shape, color}` picker, carried over.
    ///
    /// - Parameters:
    ///   - shape: the old silhouette's raw name (`ember`, `nova`, …). An unknown name keeps the
    ///     body the bot's id picks, which is still a face rather than nothing.
    ///   - color: the old swatch's raw name (`orange`, `ruby`, …).
    public static func migrated(legacyShape shape: String?, legacyColor color: String?) -> BotFaceChoice? {
        guard let color else { return nil }
        let hex = legacyColors[color.lowercased()] ?? BotAvatarPalette.match(color)?.hex
        guard let hex else { return nil }
        if let shape, let index = legacyShapeOrder.firstIndex(of: shape.lowercased()) {
            return make(colorHex: hex, shapeIndex: index)
        }
        return make(colorHex: hex)
    }

    /// The one-string form of the same migration: what this device cached, `"ember|orange"`.
    public static func migrated(legacyToken token: String) -> BotFaceChoice? {
        let parts = token.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return migrated(legacyShape: String(parts[0]), legacyColor: String(parts[1]))
    }

    /// The colour each of the sixteen old silhouettes was drawn in — the bridge's own `LEGACY` map,
    /// so a row that only ever had an icon id and a row that had the pair migrate to the same face.
    static let legacyIconColors: [String: String] = [
        "ember": "orange", "nova": "pink", "cobalt": "cyan", "orbit": "purple",
        "moss": "lime", "dusk": "indigo", "beacon": "amber", "pixel": "mint",
        "rover": "blue", "prism": "ruby", "lump": "slate", "mushroom": "teal",
        "blob": "indigo", "capsule": "blue", "droplet": "cyan", "scallop": "pink",
    ]

    /// A face chosen by the pre-pair picker, which stored only an icon id.
    public static func migrated(legacyIcon name: String) -> BotFaceChoice? {
        let key = name.lowercased()
        return migrated(legacyShape: key, legacyColor: legacyIconColors[key])
    }

    // MARK: - Codable

    /// One string on the wire and in `UserDefaults`.
    ///
    /// The decoder also accepts the old object — `{"shape": "ember", "color": "orange"}` — so a
    /// value written by the previous build reads back as the equivalent shipped choice instead of
    /// failing to decode and losing the whole face map with it.
    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let string = try? container.decode(String.self) {
            guard let choice = BotFaceChoice(rawValue: string) else {
                throw DecodingError.dataCorruptedError(in: container,
                                                       debugDescription: "not a bot face: \(string)")
            }
            self = choice
            return
        }
        let container = try decoder.container(keyedBy: LegacyKeys.self)
        let shape = try container.decodeIfPresent(String.self, forKey: .shape)
        let color = try container.decodeIfPresent(String.self, forKey: .color)
        guard let choice = BotFaceChoice.migrated(legacyShape: shape, legacyColor: color) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                     debugDescription: "no face in the legacy pair"))
        }
        self = choice
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    private enum LegacyKeys: String, CodingKey {
        case shape, color
    }
}

/// The eight shipped bodies and the palette, as one picker.
///
/// Selection is controlled by the caller — persistence is never local, because the host holds the
/// answer and the other device has to see it. What *is* local is the draft: a person who likes a
/// body should not have to give up the colour it is drawn in to keep it, and the preview at the top
/// is the face they are about to get, drawn by the same view every other surface uses.
public struct BotFacePicker: View {
    /// The bot whose face is being chosen. Its id decides the body (and the colour, when nothing is
    /// chosen) — that is the reference's rule, and it is why the preview needs it.
    public let identity: String
    /// The stored choice, or `nil` when this bot has never been given one.
    public let value: BotFaceChoice?
    public let choose: (BotFaceChoice) -> Void

    @State private var colorHex: String
    @State private var shapeIndex: Int

    public init(identity: String,
                value: BotFaceChoice?,
                choose: @escaping (BotFaceChoice) -> Void) {
        self.identity = identity
        self.value = value
        self.choose = choose
        // Seed from what is stored, so opening the picker and changing only the colour keeps the
        // body that was already there; with nothing stored, from the face the bot is wearing right
        // now, so the first tap is a change rather than a surprise.
        let resolved = value?.identity(for: identity) ?? BotAvatarIdentity.resolve(identity: identity)
        _colorHex = State(initialValue: resolved.color.hex)
        _shapeIndex = State(initialValue: resolved.shapeIndex)
    }

    /// The choice the current draft would store.
    private var draft: BotFaceChoice {
        BotFaceChoice.make(colorHex: colorHex, shapeIndex: shapeIndex)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            preview

            grid(title: "Shape") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8),
                          spacing: 8) {
                    ForEach(BotAvatarShape.shipped.indices, id: \.self) { index in
                        let shape = BotAvatarShape.shipped[index]
                        Button {
                            shapeIndex = index
                            commit()
                        } label: {
                            // The body draws itself, in the colour being chosen, so the grid is a set
                            // of eight real answers rather than eight outlines.
                            BotAvatarView(identity: identity,
                                          color: BotFaceChoice.make(colorHex: colorHex, shapeIndex: index).raw,
                                          activity: .idle,
                                          size: 34,
                                          animates: false)
                                .frame(width: 44, height: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(shapeIndex == index ? Tokens.controlActive : .clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(shapeIndex == index ? Tokens.accent : .clear,
                                                      lineWidth: 1.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(shape.name) face shape")
                        .accessibilityAddTraits(shapeIndex == index ? .isSelected : [])
                        .hermeyFocusQuiet()
                    }
                }
            }

            grid(title: "Colour") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6),
                          spacing: 8) {
                    ForEach(BotAvatarPalette.colors) { swatch in
                        Button {
                            colorHex = swatch.hex
                            commit()
                        } label: {
                            Circle()
                                .fill(swatch.color)
                                .frame(width: 26, height: 26)
                                .overlay(
                                    Circle().strokeBorder(isChosen(swatch)
                                                          ? Tokens.textPrimary : .clear,
                                                          lineWidth: 2)
                                )
                                .overlay(
                                    Circle().strokeBorder(Tokens.border, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(swatch.name) colour")
                        .accessibilityAddTraits(isChosen(swatch) ? .isSelected : [])
                        .hermeyFocusQuiet()
                    }
                }
            }
        }
    }

    /// Whether this swatch is the one in the draft: matched by hex, so a palette entry picked by a
    /// previous build (which stored a name) still lights its circle.
    private func isChosen(_ swatch: BotAvatarColorDef) -> Bool {
        if let matched = BotAvatarPalette.match(colorHex) { return swatch.id == matched.id }
        return swatch.hex.caseInsensitiveCompare(colorHex) == .orderedSame
    }

    /// The face being built, at a size where the drawing is actually legible — and moving, because
    /// a still preview of a face that will animate on every other surface is not the face.
    private var preview: some View {
        HStack(spacing: 14) {
            BotAvatarView(identity: identity, color: draft.raw, activity: .idle, size: 76)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(BotAvatarShape.shipped(index: shapeIndex).name) · \(paletteName)")
                    .font(TypeScale.font(TypeScale.md, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                Text("Any body, any colour — the bot list, the chat header and your own message bubbles all take it.")
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous))
    }

    /// The picked colour's palette name, or its hex for custom ink.
    private var paletteName: String {
        BotAvatarPalette.match(colorHex)?.name ?? colorHex.uppercased()
    }

    private func grid<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(TypeScale.font(TypeScale.sm, weight: .medium))
                .foregroundStyle(Tokens.textSecondary)
            content()
        }
    }

    private func commit() {
        choose(draft)
    }
}

#if DEBUG
#Preview("Face picker") {
    BotFacePicker(identity: "research", value: nil) { _ in }
        .padding(20)
        .frame(width: 420)
        .background(Tokens.canvas)
        .preferredColorScheme(.dark)
}
#endif
