import SwiftUI

/// Every bot's stored avatar, in one place, carried by the environment.
///
/// A face used to be a per-call-site argument: four surfaces passed `definition:` and the rest
/// passed only an id and a colour, so a bot that had chosen a new avatar went on wearing its old
/// shape in Settings, in the bot panel and in every small row. The fix is not sixteen more
/// arguments — a fifth surface added later would forget again — it is one value that says what the
/// host stores for each bot, handed down once from the root of the app:
///
/// ```swift
/// WorkspaceRoot(store: store)
///     .environment(\.botAvatars, BotAvatarLibrary(avatars: store.botAvatars))
/// ```
///
/// `BotAvatarView` reads this as its fallback, so **every** call site resolves the stored avatar
/// whether or not it knows the library exists. A caller that passes `definition:` still wins (the
/// editor's preview and the previews in this package), which is the only reason the parameter is
/// still there.
///
/// It carries `BotAvatarDocument`s rather than bare definitions because a stored face is a body
/// **and** a colour, and the colour has to travel with the body: a call site that passes a stale
/// `bots.color` beside a new definition must not repaint the new face. For a bot with a definition
/// the stored colour wins; for one without, nothing here applies and the call site's colour is
/// still what draws its shape.
///
/// This is a value, not a cache. The maps it is built from — `WorkspaceStore.botAvatars` on the
/// Mac, `AppEnvironment.botAvatars` on the phone — are `@Published`, and the roots that inject it
/// observe them, so saving, clearing or changing a definition re-reads the map and every face
/// follows on the next pass. A second store of the same data inside this type would be a copy that
/// can go stale, which is the bug this type exists to end.
public struct BotAvatarLibrary: Hashable, Sendable {
    /// The host's stored avatars, by bot id — `bot_icons`' `avatars` answer, unchanged.
    public var avatars: [String: BotAvatarDocument]

    public init(avatars: [String: BotAvatarDocument] = [:]) {
        self.avatars = avatars
    }

    /// Just the bodies, for a caller that asks "does this bot have one?".
    public var definitions: [String: BotAvatarDefinition] {
        avatars.mapValues(\.definition)
    }

    public subscript(botID: String) -> BotAvatarDocument? { avatars[botID] }

    /// No host has answered yet, or none of the bots has one: every face draws its shape.
    public static let empty = BotAvatarLibrary()
}

private struct BotAvatarsKey: EnvironmentKey {
    static let defaultValue = BotAvatarLibrary.empty
}

public extension EnvironmentValues {
    /// What the host stores for each bot's face. See `BotAvatarLibrary`.
    var botAvatars: BotAvatarLibrary {
        get { self[BotAvatarsKey.self] }
        set { self[BotAvatarsKey.self] = newValue }
    }
}
