import Foundation

/// What a stored `bots.color` value turned out to be.
///
/// Mirrors `parseBotAvatarValue` from the contracts package, including its fallbacks, because a
/// value saved by the web app has to draw the same on this side of the wire.
public enum BotAvatarStoredValue: Hashable, Sendable {
    /// A `data:image/…` URL. The caller draws the photo; this module never fetches one.
    case image(String)
    /// A colour and a chosen shape, encoded as `#RRGGBB::shape_N`.
    case shape(color: String, shapeIndex: Int)
    /// A plain hex colour.
    case color(String)
    /// Anything else that was stored.
    case other(String)

    /// How many shapes a stored index can address (`BOT_AVATAR_SHAPE_COUNT`).
    public static let shapeCount = 8

    public static func parse(_ raw: String) -> BotAvatarStoredValue {
        if raw.hasPrefix("data:image/") { return .image(raw) }
        if raw.contains("::shape_") {
            let parts = raw.components(separatedBy: "::shape_")
            let head = parts.first ?? ""
            let color = head.isEmpty ? "#F97316" : head
            let rawShape = parts.count > 1 ? parts[1] : "0"
            let isDigits = !rawShape.isEmpty && rawShape.allSatisfy { $0 >= "0" && $0 <= "9" }
            let value = isDigits ? Int(rawShape) : 0
            let index = (value ?? 0) % shapeCount
            return .shape(color: color, shapeIndex: index)
        }
        if BotAvatarPalette.isHexColor(raw) { return .color(raw) }
        return .other(raw)
    }
}

/// The seed stream the reference calls `shippedRandom`: a small, reproducible PRNG.
///
/// Not `SystemRandomNumberGenerator`, and not `Hasher`: both differ between builds, platforms and
/// processes. A bot's colour has to be the same on the phone as on the Mac, forever, so this is the
/// reference's exact 32-bit integer maths — `Math.imul` and `| 0` reproduced with wrapping Int32.
public struct BotAvatarRandom {
    private var value: Int32

    public init(seed: UInt32) {
        value = Int32(bitPattern: seed)
    }

    /// One draw in `[0, 1)`.
    public mutating func next() -> Double {
        value = value &+ 1_831_565_813
        var next = BotAvatarHash.multiply(value ^ shiftRight(value, 15), 1 | value)
        next = (next &+ BotAvatarHash.multiply(next ^ shiftRight(next, 7), 61 | next)) ^ next
        return Double(UInt32(bitPattern: next ^ shiftRight(next, 14))) / 4_294_967_296
    }

    /// The reference's shape: a closure that advances the stream on each call.
    public static func stream(_ seed: UInt32) -> () -> Double {
        var generator = BotAvatarRandom(seed: seed)
        return { generator.next() }
    }

    /// `value >>> bits`: a logical shift, so the sign bit is not dragged in.
    private func shiftRight(_ value: Int32, _ bits: Int32) -> Int32 {
        Int32(bitPattern: UInt32(bitPattern: value) >> UInt32(bits))
    }
}

public enum BotAvatarHash {
    /// `Math.imul`: the low 32 bits of the product, as a signed value. Swift's `*` on Int32 traps on
    /// overflow; this cannot.
    @inline(__always)
    public static func multiply(_ a: Int32, _ b: Int32) -> Int32 {
        Int32(truncatingIfNeeded: Int64(a) * Int64(b))
    }

    /// `shippedHash`: FNV-1a over UTF-16 code units, not bytes.
    ///
    /// The distinction matters: an identity with an emoji is a surrogate pair on the wire and two
    /// code units here, and the reference hashes the units. Hashing UTF-8 would give every such bot
    /// a different colour than the web app gives it.
    public static func shippedHash(_ value: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for unit in value.utf16 {
            hash = UInt32(truncatingIfNeeded: UInt64(hash ^ UInt32(unit)) &* 16_777_619)
        }
        return hash
    }

    /// `avatarIdentitySeed`: the djb2-style seed the organic bodies — and so the shape index here —
    /// are chosen from. Over UTF-16 code units, as `charCodeAt` reads them.
    public static func identitySeed(for identity: String) -> Int {
        var hash: Int32 = 0
        for unit in identity.utf16 {
            hash = (hash &* 32) &- hash &+ Int32(bitPattern: UInt32(unit))
        }
        return Int(abs(Int64(hash)))
    }

    /// The index of the no-shape body an identity draws: the reference's `organicAvatarFamily`
    /// pattern (`identitySeed % familyCount`) over this port's eight shipped shapes.
    public static func shapeIndex(for identity: String) -> Int {
        let count = BotAvatarShape.count
        guard count > 0 else { return 0 }
        return identitySeed(for: identity) % count
    }
}

/// Everything needed to draw one bot: which colour it wears and which body it sits in.
public struct BotAvatarIdentity: Hashable, Sendable {
    /// The id the face was resolved from.
    public var identity: String
    public var color: BotAvatarColorDef
    public var shapeIndex: Int
    public var shape: BotAvatarShape
    /// True when the stored value named a shape, false when the shape came from the identity hash.
    public var hasExplicitShape: Bool
    /// True when the stored value was a photo: draw the image, and use this only for the ring tint.
    public var isImage: Bool

    /// What a stored value turned out to be.
    ///
    /// The same reader `resolve` uses, published on its own because a picker has to know *what it is
    /// looking at* before it draws anything — and because "parse it with this, then resolve it with
    /// that" is how a second, subtly different parser gets written.
    public static func parse(_ raw: String) -> BotAvatarStoredValue {
        BotAvatarStoredValue.parse(raw)
    }

    public init(identity: String,
                color: BotAvatarColorDef,
                shapeIndex: Int,
                hasExplicitShape: Bool = false,
                isImage: Bool = false) {
        self.identity = identity
        self.color = color
        self.shapeIndex = shapeIndex
        self.shape = BotAvatarShape.shipped(index: shapeIndex)
        self.hasExplicitShape = hasExplicitShape
        self.isImage = isImage
    }

    /// Resolve a bot's face from its id and whatever was stored for it.
    ///
    /// The colour rule is `resolvePersonaColorDef` reproduced exactly: a stored value that names a
    /// palette entry (id, display name, current hex or the deeper hex it used to be saved as) wins;
    /// a valid custom hex becomes `custom`; anything else — including a value that is simply wrong —
    /// falls through to the identity hash, and the hash is FNV-1a plus one `shippedRandom` draw
    /// indexed into the palette.
    ///
    /// The shape rule follows the reference's division of labour. Where the reference derives a
    /// bot's *organic body* from its id (`organicAvatarFamily` → `identitySeed % familyCount`), this
    /// port derives the shipped shape from the same seed over its eight bodies, so an id always
    /// draws the same one. A `#RRGGBB::shape_N` value overrides it, which is the one case the
    /// reference stores a shape at all.
    public static func resolve(identity: String, explicitColor: String? = nil) -> BotAvatarIdentity {
        let stored = explicitColor.map(BotAvatarStoredValue.parse)
        var explicit: String?
        var explicitShapeIndex: Int?
        var isImage = false
        switch stored {
        case .some(.image):
            isImage = true
        case .some(.shape(let color, let index)):
            explicit = color
            explicitShapeIndex = index
        case .some(.color(let color)):
            explicit = color
        case .some(.other(let raw)):
            explicit = raw
        case .none:
            break
        }

        // The reference falls back to the stored value, then to "agent", when no identity is given —
        // a preview of a bot that has no id yet still gets a stable face.
        let seedIdentity: String
        if !identity.isEmpty {
            seedIdentity = identity
        } else if let explicit, !explicit.isEmpty {
            seedIdentity = explicit
        } else {
            seedIdentity = "agent"
        }

        let color = resolveColor(identity: seedIdentity, explicit: explicit)
        let index = explicitShapeIndex ?? BotAvatarHash.shapeIndex(for: seedIdentity)
        return BotAvatarIdentity(identity: seedIdentity,
                                 color: color,
                                 shapeIndex: index,
                                 hasExplicitShape: explicitShapeIndex != nil,
                                 isImage: isImage)
    }

    /// The colour half of `resolve`, on its own.
    public static func resolveColor(identity: String, explicit: String? = nil) -> BotAvatarColorDef {
        if let explicit, !explicit.isEmpty {
            if let matched = BotAvatarPalette.match(explicit) { return matched }
            if BotAvatarPalette.isHexColor(explicit) {
                return BotAvatarColorDef(id: "custom", name: "Custom", hex: explicit)
            }
        }
        // `(shippedHash(identity) ^ imul(1, 2654435769)) >>> 0`, then one draw of
        // `shippedRandom(seed ^ 2654435769)`, so both XORs are against the same constant.
        let constant: UInt32 = 2_654_435_769
        let seed = BotAvatarHash.shippedHash(identity) ^ constant
        var random = BotAvatarRandom(seed: seed ^ constant)
        let count = BotAvatarPalette.colors.count
        guard count > 0 else { return BotAvatarPalette.defaultColor }
        let index = Int((random.next() * Double(count)).rounded(.down))
        return BotAvatarPalette.colors[index % count]
    }
}
