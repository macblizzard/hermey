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
///
/// Six more, added for the Avatar tab's "start from" row: a bottle, a star, a droplet, an hourglass,
/// an open book and a mushroom. They are meant to be *silhouettes* a person can name at 26 pt —
/// a neck under a cap, five points, a point over a round belly, two cones on a waist, two wings on a
/// spine, a dome on a stalk — rather than six variations on a rounded square. Every one still holds
/// a face: the eyes sit in the widest solid part (the bottle's shoulder, the star's core, the
/// droplet's belly, the hourglass's upper bulb, the book's spine side, the mushroom's cap), and the
/// contract's own eye-fit rule is what decides the numbers, not taste.
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

    /// A bottle: a capped neck over a wide shoulder. The face sits on the shoulder, below the neck.
    public static let bottle = BotAvatarDefinition(
        id: "bottle",
        name: "Bottle",
        body: .init(path: "M38 12 H62 V26 C70 32 80 40 80 54 V78 Q80 88 70 88 H30 Q20 88 20 78 V54 C20 40 30 32 38 26 Z"),
        eyes: .init(x: 50, y: 62, spacing: 16, scale: 0.9))

    /// A five-point star. The eyes sit in the core, between the two lower notches, which is the only
    /// part of a star wide enough to hold a pair.
    public static let star = BotAvatarDefinition(
        id: "star",
        name: "Star",
        body: .init(path: "M50 10 L61 34 L88 38 L68 56 L73 82 L50 69 L27 82 L32 56 L12 38 L39 34 Z"),
        eyes: .init(x: 50, y: 48, spacing: 12, scale: 0.85))

    /// A droplet: a point at the top, a round belly below it.
    public static let droplet = BotAvatarDefinition(
        id: "droplet",
        name: "Droplet",
        body: .init(path: "M50 10 C58 24 80 40 80 60 C80 78 67 90 50 90 C33 90 20 78 20 60 C20 40 42 24 50 10 Z"),
        eyes: .init(x: 50, y: 62, spacing: 16, scale: 1))

    /// An hourglass: two cones meeting on a narrow waist. The face is in the upper bulb, the one
    /// place tall and wide enough at 26 pt.
    public static let hourglass = BotAvatarDefinition(
        id: "hourglass",
        name: "Hourglass",
        body: .init(path: "M24 14 H76 V26 L58 50 L76 74 V86 H24 V74 L42 50 L24 26 Z"),
        eyes: .init(x: 50, y: 33, spacing: 16, scale: 1))

    /// An open book: two covers lifting away from a spine at the bottom middle.
    public static let book = BotAvatarDefinition(
        id: "book",
        name: "Book",
        body: .init(path: "M10 26 C24 20 38 22 50 30 C62 22 76 20 90 26 V70 C76 64 62 66 50 74 C38 66 24 64 10 70 Z"),
        eyes: .init(x: 50, y: 48, spacing: 14, scale: 0.85))

    /// A mushroom: a dome cap over a short stalk. The face is on the cap.
    public static let mushroom = BotAvatarDefinition(
        id: "mushroom",
        name: "Mushroom",
        body: .init(path: "M10 46 C10 26 28 14 50 14 C72 14 90 26 90 46 Q90 50 86 50 H14 Q10 50 10 46 Z M36 50 H64 V76 Q64 84 56 84 H44 Q36 84 36 76 Z"),
        eyes: .init(x: 50, y: 34, spacing: 16, scale: 0.9))

    /// Every preset, in the order the editor shows them: the six that shipped first, then the six
    /// that followed, so a person who has used the tab keeps their bearings.
    public static let all: [BotAvatarDefinition] = [blob, box, mug, sprout, cat, egg,
                                                    bottle, star, droplet, hourglass, book, mushroom]

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
