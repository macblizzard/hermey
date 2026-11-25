import Foundation

/// One of the fixed faces a bot can wear instead of drawing its own — a shipped body and a palette
/// colour, the pair an older build stored in `bots.color` as `#RRGGBB::shape_N`.
///
/// Nothing here is new art. The eight bodies are `BotAvatarShape.shipped`, the colours are
/// `BotAvatarPalette.colors`, and the *pairing* is the only new thing: before the Avatar tab there
/// was no table of faces, so a person picked a body and a colour separately. This is that grid,
/// read as eight whole faces, which is what "one of the classics" means to somebody choosing.
///
/// The eight chosen colours are the palette entries that read as a *face* on either page: Staff
/// White is left out because a white body on Parchment is a hole, and every other entry is used
/// once. The bodies are in the shipped order, so the row is stable across builds.
public struct BotAvatarClassicFace: Hashable, Sendable, Identifiable {
    /// The palette entry, by id — the hex is never written here, so a palette correction reaches
    /// the classics too.
    public let colorID: String
    /// The shipped body.
    public let kind: BotAvatarShape.Kind

    public var id: String { "\(colorID)-\(kind.rawValue)" }

    /// The body's index in the shipped order: what `shape_N` stores.
    public var shapeIndex: Int { BotAvatarShape.index(of: kind) }

    /// The palette entry, or the default when an id has been retired from the palette.
    public var paletteColor: BotAvatarColorDef {
        BotAvatarPalette.color(id: colorID) ?? BotAvatarPalette.defaultColor
    }

    public var hex: String { paletteColor.hex }

    /// What the host stores for this face — the same string the shape picker wrote before drawn
    /// avatars existed, so a bot that picks one wears exactly the face it used to.
    public var choice: BotFaceChoice { BotFaceChoice.make(colorHex: hex, shapeIndex: shapeIndex) }

    /// "Emerald Blob" — the colour's name over the body's, so a swatch has a spoken name.
    public var name: String { "\(paletteColor.name) \(BotAvatarShape.shipped(index: shapeIndex).name)" }

    public init(colorID: String, kind: BotAvatarShape.Kind) {
        self.colorID = colorID
        self.kind = kind
    }
}

/// The Classic family: the fixed faces the app already ships, as one table.
///
/// The editor draws this row and nothing else reads it — but the *table* is the guard. A face that
/// is in a view is a face somebody typed; a face in a table is a face the tests can prove comes
/// from the palette and the eight bodies.
public enum BotAvatarClassics {
    public static let all: [BotAvatarClassicFace] = [
        BotAvatarClassicFace(colorID: "violet", kind: .hex),
        BotAvatarClassicFace(colorID: "blue", kind: .squircle),
        BotAvatarClassicFace(colorID: "cyan", kind: .tablet),
        BotAvatarClassicFace(colorID: "green", kind: .pebble),
        BotAvatarClassicFace(colorID: "orange", kind: .blob),
        BotAvatarClassicFace(colorID: "red", kind: .wedge),
        BotAvatarClassicFace(colorID: "yellow", kind: .teardrop),
        BotAvatarClassicFace(colorID: "gray", kind: .cloud),
    ]
}

/// **Which of the two families a bot's face comes from** — and the whole of what saving a face
/// means, because the two halves are alternatives and never a pair.
///
/// A bot's entry in the host's `bot-icons` document holds both: `avatar` (the Classic face) and
/// `definition` + `color` + `material` (the drawn avatar). A bot that kept both would wear its
/// definition everywhere — that is the branch `BotAvatarView` draws first — so a Classic choice
/// that did not clear the definition would look like nothing happened, and a drawn avatar that
/// left a stale face behind would come back the moment the definition was reset.
///
/// So a write names one case, and the store clears the other half in the same request.
public enum BotAvatarSelection: Hashable, Sendable {
    /// The bot wears a fixed face. `bots.color` holds `#RRGGBB::shape_N`, and the drawn avatar is
    /// cleared so nothing outranks it.
    case classic(BotFaceChoice)
    /// The bot wears its own drawing. The document is stored, and the fixed face is cleared.
    case custom(BotAvatarDocument)

    /// The half to store, if this selection draws an avatar.
    public var document: BotAvatarDocument? {
        if case .custom(let document) = self { return document }
        return nil
    }

    /// The half to store, if this selection is a Classic face.
    public var face: BotFaceChoice? {
        if case .classic(let face) = self { return face }
        return nil
    }

    /// The family, for a picker that has to say which one is current.
    public var isClassic: Bool {
        if case .classic = self { return true }
        return false
    }

    /// The same answer as a `Family`.
    public var family: Family { isClassic ? .classic : .custom }

    /// Which family the host's two answers put a bot on — the drawn one when it has a document,
    /// because that is the branch every surface draws first, whatever else is stored. `nil` when it
    /// has neither, in which case it wears the face its id derives.
    public static func stored(document: BotAvatarDocument?,
                              face: BotFaceChoice?) -> BotAvatarSelection? {
        if let document { return .custom(document) }
        if let face { return .classic(face) }
        return nil
    }

    /// The two families a face can come from, named on their own so a picker can hold "which one is
    /// the draft in" without holding a whole document it has not built yet.
    public enum Family: String, Hashable, Sendable {
        /// The fixed faces: a shipped body and a palette colour.
        case classic
        /// The bot's own drawing.
        case custom
    }
}
