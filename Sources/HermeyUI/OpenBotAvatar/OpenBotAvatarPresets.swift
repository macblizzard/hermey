import Foundation

/// The definitions the editor offers before anyone generates one.
///
/// They are ordinary v1 definitions — the same JSON a bot's owner could paste — so the editor has
/// no privileged path for its own art: a preset is picked by putting its definition in the box, and
/// a preset that stopped validating would fail the same way a paste does. `Tests/test_open_bot_avatar.py`
/// runs every one through the validator (and through the host's, in Rust), so a preset cannot rot
/// into something the host refuses.
///
/// Six silhouettes, chosen for the contract's own advice ("recognizable, soft, minimal object
/// silhouettes with two eyes that remain readable at sidebar size"): a blob, a box, a mug, a
/// sprout, a cat and an egg. Each keeps its geometry inside 8..92 so there is room for turning, and
/// each has a wide, solid face for the eyes.
public enum OpenBotAvatarPresets {

    public static let blob = BotAvatarDefinition(
        id: "blob",
        name: "Blob",
        body: .init(path: "M50 10 C72 10 90 28 90 50 C90 72 72 90 50 90 C28 90 10 72 10 50 C10 28 28 10 50 10 Z"),
        eyes: .init(x: 50, y: 47, spacing: 16, scale: 1))

    public static let box = BotAvatarDefinition(
        id: "box",
        name: "Box",
        body: .init(path: "M20 20 H80 V80 H20 Z"),
        eyes: .init(x: 50, y: 46, spacing: 15, scale: 1))

    public static let mug = BotAvatarDefinition(
        id: "mug",
        name: "Mug",
        body: .init(path: "M18 28 H74 V78 Q74 86 66 86 H30 Q22 86 22 78 Z M74 40 C86 40 90 48 90 56 C90 64 84 72 74 72 L74 64 C80 64 82 60 82 56 C82 50 78 48 74 48 Z"),
        eyes: .init(x: 46, y: 54, spacing: 13, scale: 0.9))

    public static let sprout = BotAvatarDefinition(
        id: "sprout",
        name: "Sprout",
        body: .init(path: "M32 52 H68 V82 Q68 88 62 88 H38 Q32 88 32 82 Z M47 30 C47 22 50 16 56 12 C62 20 60 36 47 44 Z"),
        eyes: .init(x: 50, y: 70, spacing: 14, scale: 0.85))

    public static let cat = BotAvatarDefinition(
        id: "cat",
        name: "Cat",
        body: .init(path: "M26 42 L26 16 L44 30 C48 28 52 28 56 30 L74 16 L74 42 C82 50 82 64 74 72 C66 80 34 80 26 72 C18 64 18 50 26 42 Z"),
        eyes: .init(x: 50, y: 50, spacing: 18, scale: 1))

    public static let egg = BotAvatarDefinition(
        id: "egg",
        name: "Egg",
        body: .init(path: "M50 12 C68 12 82 30 82 52 C82 74 68 88 50 88 C32 88 18 74 18 52 C18 30 32 12 50 12 Z"),
        eyes: .init(x: 50, y: 48, spacing: 15, scale: 1))

    /// Every preset, in the order the editor shows them.
    public static let all: [BotAvatarDefinition] = [blob, box, mug, sprout, cat, egg]

    /// The presets, checked. Throws with every reason if one has been edited into something the
    /// contract refuses — which is a programming error, not a user's.
    public static func validated() throws -> [BotAvatarDefinition] {
        try all.map { try $0.validated() }
    }

    /// A preset by its definition id, for a surface that only stores the id.
    public static func named(_ id: String) -> BotAvatarDefinition? {
        all.first { $0.id == id }
    }
}
