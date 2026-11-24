import Foundation

/// One shape, one material, one colour — what the editor's Random button applies.
///
/// The three fields are the three things the editor already edits (`draft`, `material`, `colorHex`),
/// in the types it already stores them in, so "random" is a value it can adopt rather than a special
/// path through the view.
///
/// `combination` names all three, which is what makes "not the same twice in a row" a comparison
/// rather than a guess: two picks that differ only in the colour are still two picks.
public struct OpenBotAvatarRandomPick: Hashable, Sendable {
    public var definition: BotAvatarDefinition
    public var material: BotAvatarMaterial
    /// `#RRGGBB` from `BotAvatarPalette`, so a random face is a face the colour picker can show.
    public var colorHex: String

    public init(definition: BotAvatarDefinition, material: BotAvatarMaterial, colorHex: String) {
        self.definition = definition
        self.material = material
        self.colorHex = colorHex
    }

    /// The three together, e.g. `bottle|matte|#A97EFE`.
    public var combination: String {
        "\(definition.id)|\(material.rawValue)|\(colorHex)"
    }
}

/// The Random button: a pick from the app's own tables, and nothing else.
///
/// This is deliberately not a generator. It has no palette of its own, no shapes of its own and no
/// materials of its own: the shapes are `OpenBotAvatarPresets.all` (validated, so every one is a
/// definition the editor could have offered as a preset), the materials are the rows of
/// `BotAvatarMaterialSpec.all` (so every one is a value the host stores), and the colours are
/// `BotAvatarPalette`, the app's avatar palette — a random face the Save button then refuses would
/// be worse than no button at all.
///
/// **Never the same twice.** The pick is drawn from the *set* of every combination with the previous
/// one removed, not by re-rolling until something new comes up: with 12 shapes, 4 materials and 10
/// colours there are 480 combinations, so the set is never empty and one draw is always different
/// from the last. No seed, no state in the type — the caller keeps the last pick's `combination`.
public enum OpenBotAvatarRandom {

    /// The shapes a pick may choose: the presets, each checked by the contract. A preset that had
    /// been edited into something invalid is left out rather than offered.
    public static var shapes: [BotAvatarDefinition] {
        (try? OpenBotAvatarPresets.validated()) ?? []
    }

    /// The materials a pick may choose: the table's rows, in the order the editor lists them.
    public static var materials: [BotAvatarMaterial] {
        BotAvatarMaterialSpec.all.map(\.material)
    }

    /// The colours a pick may choose: the app's avatar palette, minus its white, which the invite
    /// artwork leaves out for the same reason — a white body is invisible on a light page, and a
    /// random face that can vanish is not a fair random face.
    public static var colors: [String] {
        BotAvatarPalette.colors.filter { $0.id != "white" }.map(\.hex)
    }

    /// Every combination the three tables hold, in table order.
    public static func combinations() -> [OpenBotAvatarRandomPick] {
        let availableShapes = shapes
        let availableMaterials = materials
        let availableColors = colors
        var all: [OpenBotAvatarRandomPick] = []
        all.reserveCapacity(availableShapes.count * availableMaterials.count * availableColors.count)
        for shape in availableShapes {
            for material in availableMaterials {
                for color in availableColors {
                    all.append(OpenBotAvatarRandomPick(definition: shape,
                                                       material: material,
                                                       colorHex: color))
                }
            }
        }
        return all
    }

    /// One pick, never the one named by `previous` (a `OpenBotAvatarRandomPick.combination`).
    ///
    /// Returns nil only when a table is empty, which is a programming error rather than a state the
    /// editor can reach — the editor keeps what it had and shows nothing new.
    public static func pick(avoiding previous: String? = nil) -> OpenBotAvatarRandomPick? {
        let all = combinations()
        guard !all.isEmpty else { return nil }
        let choices = previous.map { key in all.filter { $0.combination != key } } ?? all
        // `choices` is empty only when there is exactly one combination and it is `previous`; then
        // there is nothing else to show and the one pick is still valid.
        return (choices.isEmpty ? all : choices).randomElement()
    }
}
