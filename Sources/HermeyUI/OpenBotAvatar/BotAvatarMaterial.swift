import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The material a bot's drawn avatar is made of: the stored `material` value, its rules, and the
/// table of specs a renderer and an editor read.
///
/// ## Why a table
///
/// A material is not a flag. Glass is a fill treatment plus a halo, a sheen, a streak, a rim and a
/// contact band, each with its own geometry, opacity and blend — and the next material (a matte, a
/// soft fabric) will be the same kind of list with different numbers. So the drawing reads a
/// `BotAvatarMaterialSpec` and never a `switch`: **adding a material is a row in `all`**, and the
/// editor lists whatever rows exist rather than hard-coding two choices.
///
/// The two shipped rows are:
///
/// * `glass` — six layers over the silhouette, built to the reference's spec;
/// * `solid` — the 0.1.648 solid, whose spec is deliberately empty: a flat fill and nothing over
///   it, so the slice-stack drawing that shipped keeps drawing exactly what it drew.
///
/// ## What is stored
///
/// One field on the avatar document, beside `definition` and `color`:
///
/// ```json
/// { "faces": { "cody": { "avatar": "#A97EFE::shape_1", "definition": { … },
///                        "color": "#A97EFE", "material": "glass" } } }
/// ```
///
/// Absent or null means `solid`, so nothing already saved changes and nothing needs migrating; the
/// `open-bot-avatar` definition itself is untouched. The host refuses any other value with a 400
/// (`hermeyd/src/bot_avatar.rs`, `parse_material`), and this enum's own validator accepts exactly
/// the same two strings with the same sentence — one rule, two readers.
public enum BotAvatarMaterial: String, CaseIterable, Hashable, Sendable, Codable {
    /// The 0.1.648 face: the volume's cross-sections filled flat, with nothing over them.
    case solid
    /// The reference's material: a ramped silhouette with a halo, sheen, streak, rim and contact.
    case glass

    /// What an absent or null field means. Every document written before `material` existed is
    /// solid, which is why there is no migration.
    public static let fallback: BotAvatarMaterial = .solid

    /// The values this build accepts, derived from the cases rather than written out again, so a new
    /// material cannot be drawable and unlisted. `bot_avatar.rs`'s `MATERIALS` is the host's copy of
    /// the same two, and `Tests/test_bot_avatar_glass.py` checks the two agree.
    public static let accepted: [String] = allCases.map(\.rawValue)

    /// The refusal, in the contract's own words, for a value that is neither.
    public static func refusal(_ raw: String) -> String {
        "material must be \"solid\" or \"glass\", not \"\(raw)\""
    }

    /// The stored string as a material: nil is `solid`, anything else is itself or a refusal.
    ///
    /// This is the *only* Swift rule, and it is the same rule the host applies. A reader that meets
    /// an unknown value is reading a document from a newer host, and it is refused rather than
    /// guessed at — a face drawn in a material this build cannot paint is worse than a face.
    public init(validating raw: String?) throws {
        guard let raw else {
            self = .fallback
            return
        }
        guard let value = BotAvatarMaterial(rawValue: raw) else {
            throw BotAvatarMaterialFailure(reason: Self.refusal(raw))
        }
        self = value
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        try self.init(validating: raw)
    }
}

/// Why a stored material was refused, in the contract's own words — the sentence an editor shows
/// and the sentence the host answers 400 with.
public struct BotAvatarMaterialFailure: Error, Hashable, Sendable, LocalizedError {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
    public var description: String { reason }
}

// MARK: - The spec

/// How a material paints the body, before anything is laid over it.
enum MaterialFill: Hashable, Sendable {
    /// The volume's own cross-sections, each filled flat with the tint — what 0.1.648 shipped.
    case flat
    /// One silhouette filled with a vertical three-stop gradient: `lightness` toward white at 0,
    /// the tint at `mid`, `darkness` toward black at 1. This is a glass body's whole volume.
    case ramp(lightness: Double, mid: Double, darkness: Double)
}

/// A colour in a material's gradient, named relative to the bot's tint so a material is data and
/// not a palette: the tint itself, white or clear, or the tint mixed toward one of them.
enum MaterialTone: Hashable, Sendable {
    case tint
    case white
    case clear
    /// The tint mixed toward white.
    case lighten(Double)
    /// The tint mixed toward black.
    case darken(Double)
}

/// One stop of a gradient along a tone.
struct MaterialStop: Hashable, Sendable {
    var tone: MaterialTone
    var opacity: Double
    /// 0…1 along the gradient.
    var location: Double
}

/// The highlight that makes a 2-D shape read as glass: the silhouette stroked with a gradient.
struct MaterialRim: Hashable, Sendable {
    /// Top-left to bottom-right, for a dark backdrop (and always for the pet).
    var stops: [MaterialStop]
    /// The same gradient on a light backdrop, where a white rim vanishes into paper.
    var lightStops: [MaterialStop]?
    /// Stroke width as a fraction of the side…
    var width: Double
    /// …but never thinner than this, in points: the rim has to survive at 26 pt.
    var minimumWidth: Double
    var blend: MaterialBlend
    /// The dark hairline a light backdrop adds outside the rim so the silhouette still holds.
    var outerHairline: MaterialStop?
    var hairlineWidth: Double
}

/// The soft light a material throws: layer 1 of the glass spec.
struct MaterialHalo: Hashable, Sendable {
    var tone: MaterialTone
    /// Downward offset, as a fraction of the side.
    var offset: Double
    /// Blur radius, as a fraction of the side.
    var blur: Double
}

/// A soft radial sheen on the body's upper-left: layer 3.
struct MaterialSheen: Hashable, Sendable {
    /// Centre, as a fraction of the bounds.
    var center: CGPoint
    /// Radius, as a fraction of the bounds' long side.
    var radius: Double
    var opacity: Double
    var blend: MaterialBlend
}

/// A specular streak: a rotated capsule filled along its short axis, clipped to the shape. Layer 4.
struct MaterialStreak: Hashable, Sendable {
    /// The capsule's centre, as a fraction of the bounds.
    var anchor: CGPoint
    /// Rotation, radians.
    var angle: Double
    /// As a fraction of the bounds' width.
    var length: Double
    var thickness: Double
    var opacity: Double
    /// Blur, in points.
    var blur: Double
    var blend: MaterialBlend
}

/// The dark band along the bottom inside edge that stops the shape looking pasted on. Layer 6.
struct MaterialContact: Hashable, Sendable {
    var tone: MaterialTone
    var opacity: Double
    /// Band height as a fraction of the bounds' height.
    var height: Double
    /// Blur, in points.
    var blur: Double
    var blend: MaterialBlend
}

/// A pattern over the fill. No shipped material uses one; it is here so a matte or a fabric is a
/// row rather than a new drawing path.
struct MaterialTexture: Hashable, Sendable {
    enum Pattern: String, Hashable, Sendable {
        /// A lattice of dots.
        case dots
        /// A finer, denser lattice, read as grain.
        case grain
    }
    var pattern: Pattern
    var opacity: Double
    /// Cells across the bounds' long side.
    var cells: Double
    var tone: MaterialTone
}

/// How a material composites a layer.
enum MaterialBlend: Hashable, Sendable {
    case normal
    case plusLighter

    var graphics: GraphicsContext.BlendMode {
        switch self {
        case .normal: return .normal
        case .plusLighter: return .plusLighter
        }
    }
}

/// One material, as data: what paints the body, what sits over it, and what a state may do to it.
///
/// The renderer reads this and nothing else about a material; the editor lists `all`. Nothing here
/// is a size or a state — those are the plan (`MaterialPlan`) and the light (`OpenBotAvatarLight`).
struct BotAvatarMaterialSpec: Hashable, Sendable {
    let material: BotAvatarMaterial
    /// The word the editor shows.
    let name: String
    /// A sentence for the editor, under the choice.
    let summary: String
    let fill: MaterialFill
    /// Layer 1. nil for a material with no light of its own.
    let halo: MaterialHalo?
    /// Layer 3.
    let sheens: [MaterialSheen]
    /// Layer 4.
    let streaks: [MaterialStreak]
    /// Layer 5.
    let rim: MaterialRim?
    /// Layer 6.
    let contact: MaterialContact?
    /// An optional pattern over the fill.
    let texture: MaterialTexture?
    /// Whether `blocked` desaturates the tint for this material. Glass does; a flat solid is the
    /// colour the bot chose and stays it.
    let desaturatesWhenBlocked: Bool
    /// Whether the eyes take the 1 pt catchlight above 64 pt. A material with a lit surface earns
    /// one; the flat solid's eyes are solid ink and stay that way.
    let addsEyeCatchlight: Bool
}

extension BotAvatarMaterialSpec {

    /// The table, in the order an editor lists it. The first row is the default.
    ///
    /// A new material is a new `static let` and one more entry here. Nothing else in the drawing
    /// changes: `OpenBotAvatarMaterialPaint` walks whatever entries the spec has.
    static let all: [BotAvatarMaterialSpec] = [.solid, .glass]

    static func spec(for material: BotAvatarMaterial) -> BotAvatarMaterialSpec {
        all.first { $0.material == material } ?? .solid
    }

    /// The 0.1.648 face, written down as data.
    ///
    /// It is deliberately empty above the fill: no halo, no sheen, no streak, no rim, no contact.
    /// The fill is `.flat`, which the renderer draws through the volume's own slice stack — the
    /// drawing that shipped — so choosing Solid is byte-for-byte the face a bot already had, and a
    /// bot that never chose a material (absent, null, or before this field existed) is Solid.
    static let solid = BotAvatarMaterialSpec(
        material: .solid,
        name: "Solid",
        summary: "The face as it has always been: a flat body with no highlight over it.",
        fill: .flat,
        halo: nil,
        sheens: [],
        streaks: [],
        rim: nil,
        contact: nil,
        texture: nil,
        desaturatesWhenBlocked: false,
        addsEyeCatchlight: false
    )

    /// The reference's material, in six layers over one silhouette.
    ///
    /// The numbers are the spec's, not taste: the ramp's three stops are 0.18/0.55/0.15, the sheen
    /// sits at (0.42, 0.28) with radius 0.6 of the bounds, there is **one** streak, and the rim is
    /// 0.035 of the side but never thinner than a point.
    static let glass = BotAvatarMaterialSpec(
        material: .glass,
        name: "Glass",
        summary: "A lit body: a soft ramp, one streak, a bright rim and a shadow that grounds it.",
        fill: .ramp(lightness: 0.18, mid: 0.55, darkness: 0.15),
        halo: MaterialHalo(tone: .tint, offset: 0.04, blur: 0.08),
        sheens: [
            MaterialSheen(center: CGPoint(x: 0.42, y: 0.28), radius: 0.6, opacity: 0.22,
                          blend: .plusLighter),
        ],
        streaks: [
            // One streak, in the upper left, at about 38°: the reference has a single highlight and
            // three of them read as scratches.
            MaterialStreak(anchor: CGPoint(x: 0.32, y: 0.30), angle: -0.66,
                           length: 0.62, thickness: 0.15, opacity: 0.55, blur: 1.5,
                           blend: .plusLighter),
        ],
        rim: MaterialRim(
            stops: [
                MaterialStop(tone: .white, opacity: 0.55, location: 0),
                MaterialStop(tone: .lighten(0.3), opacity: 1, location: 0.18),
            ],
            // Paper: white 0.55 into plain tint, plus a dark hairline outside so the silhouette
            // still holds on Parchment.
            lightStops: [
                MaterialStop(tone: .white, opacity: 0.55, location: 0),
                MaterialStop(tone: .tint, opacity: 0.5, location: 0.18),
            ],
            width: 0.035,
            minimumWidth: 1,
            blend: .plusLighter,
            outerHairline: MaterialStop(tone: .darken(0.4), opacity: 0.25, location: 0),
            hairlineWidth: 1
        ),
        contact: MaterialContact(tone: .darken(0.35), opacity: 0.12, height: 0.2, blur: 2,
                                 blend: .normal),
        texture: nil,
        desaturatesWhenBlocked: true,
        addsEyeCatchlight: true
    )
}

// MARK: - Colours

/// A colour as components, so a material can mix the bot's tint toward white or black without
/// another trip through the platform colour type for every stop of every gradient, every frame.
struct MaterialColor: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    static let white = MaterialColor(red: 1, green: 1, blue: 1)
    static let black = MaterialColor(red: 0, green: 0, blue: 0)

    init(_ color: Color) {
        #if canImport(UIKit)
        let resolved = UIColor(color)
        #else
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.black
        #endif
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(red: Double(red), green: Double(green), blue: Double(blue))
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    /// This colour mixed toward `other` by `amount`, clamped to 0…1.
    func mixed(with other: MaterialColor, _ amount: Double) -> MaterialColor {
        let t = max(0, min(1, amount))
        func blend(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        return MaterialColor(red: blend(red, other.red),
                             green: blend(green, other.green),
                             blue: blend(blue, other.blue))
    }

    /// The colour with `amount` of its saturation removed, around its own luminance — how `blocked`
    /// calms a glass body without turning it a different colour.
    func desaturated(by amount: Double) -> MaterialColor {
        let t = max(0, min(1, amount))
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        func calm(_ value: Double) -> Double { luminance + (value - luminance) * (1 - t) }
        return MaterialColor(red: calm(red), green: calm(green), blue: calm(blue))
    }

    /// One of a material's tones, in this tint.
    func resolved(_ tone: MaterialTone, opacity: Double = 1) -> Color {
        switch tone {
        case .tint: return color.opacity(opacity)
        case .white: return Color.white.opacity(opacity)
        case .clear: return Color.clear
        case .lighten(let amount): return mixed(with: .white, amount).color.opacity(opacity)
        case .darken(let amount): return mixed(with: .black, amount).color.opacity(opacity)
        }
    }
}
