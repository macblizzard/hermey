import Foundation

// MARK: - One key combination

/// A key plus the modifiers held with it — the thing a shortcut actually *is*.
///
/// **Why not `KeyEquivalent`.** `ShortcutCombo` is Foundation-only on purpose: the registry has to be
/// readable, storable and comparable without AppKit, so it can be unit-tested and so the phone can
/// share it later. SwiftUI's `KeyEquivalent` and AppKit's `keyEquivalent` + `keyEquivalentModifierMask`
/// are both derived from this value at the two edges that need them
/// (`Apps/HermesMac/Shortcuts/ShortcutCenter.swift`).
///
/// `key` is the *canonical* spelling, never the drawing: a printable key is its lowercased character
/// (`"f"`, `"0"`, `"+"`, `"]"`), and everything that has no character of its own is a token from
/// ``ShortcutCombo/namedKeys`` (`"return"`, `"escape"`, `"delete"`, `"down"`, `"f5"`). A stored file
/// therefore cannot go stale because a keyboard layout changed, and an unknown token is refused at
/// decode time rather than drawn as a blank key.
public struct ShortcutCombo: Hashable, Sendable, Codable {

    /// The four modifiers a Mac shortcut may carry, in the order a Mac writes them (⌃⌥⇧⌘).
    public enum Modifier: String, CaseIterable, Codable, Sendable {
        case control
        case option
        case shift
        case command

        /// The glyph macOS prints for it.
        public var glyph: String {
            switch self {
            case .control: return "⌃"
            case .option: return "⌥"
            case .shift: return "⇧"
            case .command: return "⌘"
            }
        }

        /// ⌃⌥⇧⌘ — the canonical order, which is not the declaration order by accident: Apple writes
        /// a combination in this order and a menu that printed ⇧⌘F as ⌘⇧F would look foreign.
        public var displayOrder: Int {
            switch self {
            case .control: return 0
            case .option: return 1
            case .shift: return 2
            case .command: return 3
            }
        }
    }

    /// The canonical spelling of the key.
    public let key: String
    /// The modifiers, as a set: there is no meaning to their order, and two combos that differ only
    /// in how they were typed are the same combo.
    public let modifiers: Set<Modifier>

    public init(key: String, modifiers: Set<Modifier>) {
        self.key = ShortcutCombo.canonicalKey(key)
        self.modifiers = modifiers
    }

    /// Convenience for the registry table, where every row is written by hand.
    public init(_ key: String, _ modifiers: Modifier...) {
        self.init(key: key, modifiers: Set(modifiers))
    }

    // MARK: The keys that have no character

    /// Every key besides a printable character, with the glyph the menu draws for it.
    ///
    /// Named rather than spelled as control characters in the table: `"return"` is a fact about the
    /// key, `"\r"` is a fact about a terminal.
    public static let namedKeys: [String: String] = [
        "return": "↩",
        "escape": "⎋",
        "tab": "⇥",
        "space": "Space",
        "delete": "⌫",
        "forwardDelete": "⌦",
        "up": "↑",
        "down": "↓",
        "left": "←",
        "right": "→",
        "home": "↖",
        "end": "↘",
        "pageUp": "⇞",
        "pageDown": "⇟",
    ]

    /// The function keys, F1–F20. Spelled by number so `"f5"` and `"F5"` are one key.
    public static let functionKeys: Set<String> = Set((1...20).map { "f\($0)" })

    /// The printable keys the recorder may produce: letters, digits and the punctuation a Mac
    /// shortcut is usually made of. Anything else is refused rather than stored — a combination the
    /// registry cannot draw is one the owner cannot find again.
    public static let printableKeys: Set<Character> = {
        var keys = Set<Character>("abcdefghijklmnopqrstuvwxyz0123456789")
        keys.formUnion("`-=[]\\;',./ ")
        keys.formUnion("+*")
        return keys
    }()

    /// A key is usable when it is a name we know, a function key, or one printable character.
    public static func isUsableKey(_ raw: String) -> Bool {
        let key = canonicalKey(raw)
        if namedKeys[key] != nil { return true }
        if functionKeys.contains(key) { return true }
        guard key.count == 1, let character = key.first else { return false }
        return printableKeys.contains(character)
    }

    /// Lowercased, trimmed, with the aliases people type folded onto the canonical token.
    public static func canonicalKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        switch lowered {
        case "enter", "\r", "\n": return "return"
        case "esc", "\u{1b}": return "escape"
        case "tab", "\t": return "tab"
        case "space", " ": return "space"
        case "backspace", "⌫", "\u{8}", "\u{7f}": return "delete"
        case "del", "⌦": return "forwardDelete"
        case "arrowup", "↑": return "up"
        case "arrowdown", "↓": return "down"
        case "arrowleft", "←": return "left"
        case "arrowright", "→": return "right"
        default: return lowered
        }
    }

    // MARK: Drawing

    /// The key on its own, as a menu prints it: `F`, `↩`, `⌫`, `Space`.
    public var keyLabel: String {
        if let named = ShortcutCombo.namedKeys[key] { return named }
        if ShortcutCombo.functionKeys.contains(key) { return key.uppercased() }
        return key.uppercased()
    }

    /// The whole combination as macOS prints it: `⇧⌘F`, `⌘↩`, `⌥⌘↓`.
    public var label: String {
        modifiers.sorted { $0.displayOrder < $1.displayOrder }.map(\.glyph).joined() + keyLabel
    }

    // MARK: Codable

    /// The stored shape, spelled out rather than synthesised: `Set` has no stable encoding order,
    /// and a file whose bytes shuffle every save is a file that shows up in every diff.
    private enum CodingKeys: String, CodingKey {
        case key
        case modifiers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawKey = try container.decode(String.self, forKey: .key)
        guard ShortcutCombo.isUsableKey(rawKey) else {
            throw DecodingError.dataCorruptedError(
                forKey: .key, in: container,
                debugDescription: "\(rawKey) is not a key this app can bind")
        }
        key = ShortcutCombo.canonicalKey(rawKey)
        let raw = try container.decodeIfPresent([String].self, forKey: .modifiers) ?? []
        var set = Set<Modifier>()
        for name in raw {
            guard let modifier = Modifier(rawValue: name.lowercased()) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .modifiers, in: container,
                    debugDescription: "\(name) is not a modifier")
            }
            set.insert(modifier)
        }
        modifiers = set
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(modifiers.map(\.rawValue).sorted(), forKey: .modifiers)
    }
}

// MARK: - One action

/// One thing the app can do from the keyboard, described once.
///
/// **This type is the registry.** Every row below is an action the app already had — a `CommandMenu`
/// item, a `CommandGroup` item or a `.keyboardShortcut` on a view — and after this file no other
/// place spells its combination. The Mac's menu items, the ⌘K palette's hint text and the Settings →
/// Shortcuts pane all read these values, which is the only way they can be kept in agreement: before
/// this, the palette advertised ⌘⌥S for the bot panel while the menu bar bound ⌘S, and nothing said
/// which was true.
public struct ShortcutAction: Identifiable, Sendable, Equatable {

    /// Which block of the pane a row is filed under, and the order the blocks draw in.
    public enum Group: String, CaseIterable, Sendable {
        case navigation = "Navigation"
        case conversation = "Conversation"
        case message = "Message"
        case window = "Window"
    }

    /// Who owns the combination in the menu bar.
    public enum Owner: Sendable, Equatable {
        /// This app's own menu item: the registry decides the key, and a rebind updates it.
        case appMenu
        /// The system's: macOS binds it (⌘, opens Settings because the `Settings` scene says so) and
        /// an app that claimed it back would be lying about a key it does not dispatch.
        case system
    }

    /// Stable, stored identity. Never a title: renaming a row must not orphan a binding, and an id
    /// that no longer exists must be droppable from the stored file without ceremony.
    public let id: String
    /// What the pane calls it.
    public let title: String
    /// A sentence under the row's title in the pane. Says what the key *does*, not what it is.
    public let detail: String
    public let group: Group
    /// The shipped combination, or `nil` for an action that ships unbound.
    public let defaultCombo: ShortcutCombo?
    /// Whether the owner may change it. `false` for the rows macOS owns.
    public let owner: Owner
    /// The titles this action's `NSMenuItem` can carry, in the current state and its alternative —
    /// "Show Bot Panel" / "Hide Bot Panel". The menu sync finds an item by these, because SwiftUI
    /// gives us no tag to look for.
    public let menuItemTitles: [String]
    /// Everything the row does besides its key, if the action is also reachable elsewhere. Only ever
    /// the documentation the pane prints; nothing dispatches from it.
    public let note: String?

    public var isRebindable: Bool { owner == .appMenu }

    public init(id: String,
                title: String,
                detail: String,
                group: Group,
                defaultCombo: ShortcutCombo?,
                owner: Owner = .appMenu,
                menuItemTitles: [String] = [],
                note: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.group = group
        self.defaultCombo = defaultCombo
        self.owner = owner
        self.menuItemTitles = menuItemTitles
        self.note = note
    }
}

// MARK: - The registry

/// Every keyboard action the Mac app has, in one table.
///
/// The table is the *default* state of the app. What the owner has changed lives in
/// ``ShortcutDocument``; the two together are what the menu and the pane read.
public enum ShortcutRegistry {

    /// The rows, grouped and in the order the pane draws them.
    public static let actions: [ShortcutAction] = navigation + conversation + message + window

    public static func action(_ id: String) -> ShortcutAction? {
        actions.first { $0.id == id }
    }

    // MARK: Groups

    private static let navigation: [ShortcutAction] = [
        ShortcutAction(
            id: "palette.open",
            title: "Command Palette",
            detail: "The ⌘K list of everything this window can do.",
            group: .navigation,
            defaultCombo: ShortcutCombo("k", .command),
            menuItemTitles: ["Command Palette…"]),
        ShortcutAction(
            id: "chat.find",
            title: "Find in Conversation",
            detail: "Search the transcript on screen.",
            group: .navigation,
            defaultCombo: ShortcutCombo("f", .command),
            menuItemTitles: ["Find in Conversation…"]),
        ShortcutAction(
            id: "view.sidebar",
            title: "Bot Panel",
            detail: "Show or hide the list of bots down the left edge.",
            group: .navigation,
            defaultCombo: ShortcutCombo("s", .command),
            menuItemTitles: ["Show Bot Panel", "Hide Bot Panel"]),
        ShortcutAction(
            id: "view.botPanel",
            title: "Bot Actions",
            detail: "Show or hide this bot's panel on the right edge.",
            group: .navigation,
            defaultCombo: ShortcutCombo("e", .command),
            menuItemTitles: ["Show Bot Actions", "Hide Bot Actions"]),
        ShortcutAction(
            id: "bell.waiting",
            title: "Waiting for You",
            detail: "Every bot with something waiting, behind the panel's bell.",
            group: .navigation,
            defaultCombo: ShortcutCombo("n", .command, .shift),
            menuItemTitles: []),
        ShortcutAction(
            id: "bot.next",
            title: "Next Bot",
            detail: "Open the next bot in the panel's order.",
            group: .navigation,
            defaultCombo: ShortcutCombo("down", .command, .option),
            menuItemTitles: ["Next Bot"]),
        ShortcutAction(
            id: "bot.previous",
            title: "Previous Bot",
            detail: "Open the previous bot in the panel's order.",
            group: .navigation,
            defaultCombo: ShortcutCombo("up", .command, .option),
            menuItemTitles: ["Previous Bot"]),
        ShortcutAction(
            id: "bot.settings",
            title: "Bot Settings",
            detail: "The open bot's own sheet — model, soul, memory.",
            group: .navigation,
            defaultCombo: nil,
            menuItemTitles: ["Bot Settings…"]),
        ShortcutAction(
            id: "host.pair",
            title: "Pair Host",
            detail: "Add or replace the Hermes host this Mac talks to.",
            group: .navigation,
            defaultCombo: ShortcutCombo("p", .command, .shift),
            menuItemTitles: ["Pair Host…"]),
    ]

    private static let conversation: [ShortcutAction] = [
        ShortcutAction(
            id: "turn.send",
            title: "Send Message",
            detail: "Send what is in the composer.",
            group: .conversation,
            defaultCombo: ShortcutCombo("return", .command),
            menuItemTitles: ["Send Message"]),
        ShortcutAction(
            id: "turn.interrupt",
            title: "Interrupt Turn",
            detail: "Stop the answer that is being written.",
            group: .conversation,
            defaultCombo: ShortcutCombo(".", .command),
            menuItemTitles: ["Interrupt Turn"]),
        ShortcutAction(
            id: "chat.refresh",
            title: "Refresh Conversation",
            detail: "Re-read the conversation from the host — a room's rows, or this bot's session.",
            group: .conversation,
            defaultCombo: ShortcutCombo("r", .command),
            menuItemTitles: ["Refresh Conversation"]),
        ShortcutAction(
            id: "host.connect",
            title: "Connect or Disconnect",
            detail: "Open or close the socket to the paired host.",
            group: .conversation,
            defaultCombo: ShortcutCombo("r", .command, .shift),
            menuItemTitles: ["Disconnect", "Connect"]),
        ShortcutAction(
            id: "text.bigger",
            title: "Bigger Text",
            detail: "One step up the type scale, everywhere in the window.",
            group: .conversation,
            defaultCombo: ShortcutCombo("+", .command),
            menuItemTitles: ["Bigger Text"]),
        ShortcutAction(
            id: "text.smaller",
            title: "Smaller Text",
            detail: "One step down the type scale.",
            group: .conversation,
            defaultCombo: ShortcutCombo("-", .command),
            menuItemTitles: ["Smaller Text"]),
        ShortcutAction(
            id: "text.default",
            title: "Default Text Size",
            detail: "Back to the scale the app shipped with.",
            group: .conversation,
            defaultCombo: ShortcutCombo("0", .command),
            menuItemTitles: ["Default Text Size"]),
    ]

    /// The message verbs. Each one works on **the last message of that kind in the conversation on
    /// screen**, and the transcript's own right-click menu still offers the same verbs on any row —
    /// these are the keyboard's way into them, not a second menu.
    private static let message: [ShortcutAction] = [
        ShortcutAction(
            id: "message.actions",
            title: "Message Actions…",
            detail: "Opens the row menu the right-click opens, for the message the keyboard is on.",
            group: .message,
            defaultCombo: ShortcutCombo("m", .command, .shift),
            menuItemTitles: ["Message Actions…"]),
        ShortcutAction(
            id: "message.copyLast",
            title: "Copy Last Message",
            detail: "The newest message in the conversation, onto the pasteboard.",
            group: .message,
            defaultCombo: ShortcutCombo("c", .command, .shift),
            menuItemTitles: ["Copy Last Message"]),
        ShortcutAction(
            id: "message.editLast",
            title: "Edit Last Message",
            detail: "Put the last message you sent back in the composer, to send again.",
            group: .message,
            defaultCombo: ShortcutCombo("e", .command, .option),
            menuItemTitles: ["Edit Last Message"]),
        ShortcutAction(
            id: "message.deleteLast",
            title: "Delete Last Message",
            detail: "Retire the newest message from the conversation, after a confirmation.",
            group: .message,
            defaultCombo: ShortcutCombo("delete", .command),
            menuItemTitles: ["Delete Last Message"]),
    ]

    private static let window: [ShortcutAction] = [
        ShortcutAction(
            id: "app.settings",
            title: "Settings",
            detail: "This window.",
            group: .window,
            defaultCombo: ShortcutCombo(",", .command),
            owner: .system,
            menuItemTitles: ["Settings…"],
            note: "macOS opens Settings on ⌘, because the app declares a Settings scene. It is listed here so the pane shows the whole keyboard, not so it can be rebound."),
        ShortcutAction(
            id: "app.checkForUpdates",
            title: "Check for Updates",
            detail: "Ask the release feed whether a newer build exists.",
            group: .window,
            defaultCombo: nil,
            menuItemTitles: ["Check for Updates…"]),
    ]

    // MARK: Reserved

    /// Combinations macOS keeps for itself. They cannot be assigned to an app action: the menu bar
    /// would never see the key, so the row would look bound and do nothing.
    ///
    /// ⌘Q and ⌘W are the two that cost something to get wrong — quitting or closing under a
    /// half-written message — and ⌘, is here because the `Settings` scene owns it (`app.settings` is
    /// an `Owner.system` row for exactly that reason).
    public static let reserved: [ShortcutCombo] = [
        ShortcutCombo("q", .command),
        ShortcutCombo("q", .command, .shift),
        ShortcutCombo("w", .command),
        ShortcutCombo("w", .command, .shift),
        ShortcutCombo(",", .command),
        ShortcutCombo("h", .command),
        ShortcutCombo("h", .command, .option),
        ShortcutCombo("m", .command),
        ShortcutCombo("m", .command, .option),
        ShortcutCombo("`", .command),
        ShortcutCombo("tab", .command),
        ShortcutCombo("space", .command),
        ShortcutCombo("f", .command, .control),
        ShortcutCombo("3", .command, .shift),
        ShortcutCombo("4", .command, .shift),
        ShortcutCombo("5", .command, .shift),
    ]

    public static func reservedOwner(_ combo: ShortcutCombo) -> ShortcutCombo? {
        reserved.first { $0 == combo }
    }

    /// Why a combination cannot be given to `action`, or `nil` when it can.
    ///
    /// Used by ``ShortcutDocument/set(_:for:)`` so the rule is stated once, in the registry, and the
    /// pane only has to draw the answer.
    public static func rejection(of combo: ShortcutCombo,
                                 for action: ShortcutAction,
                                 in document: ShortcutDocument) -> ShortcutRejection? {
        guard action.isRebindable else { return .notRebindable(action) }
        guard !combo.modifiers.isEmpty || ShortcutCombo.functionKeys.contains(combo.key) else {
            // A bare letter is not a shortcut: it would steal typing from the composer.
            return .needsModifier(combo)
        }
        if reservedOwner(combo) != nil { return .reserved(combo) }
        if let other = document.owner(of: combo, excluding: action.id) { return .duplicate(other) }
        return nil
    }

    /// The action the pane should show for a row, by id. `nil` for an id this build does not have —
    /// which is how a binding left behind by a newer or older build is dropped rather than drawn.
    public static var ids: Set<String> { Set(actions.map(\.id)) }
}

// MARK: - Refusals

/// Why the registry would not take a combination.
///
/// Typed rather than a string so the pane can draw each case its own way and a test can assert the
/// rule rather than the wording.
public enum ShortcutRejection: Equatable, Sendable {
    /// This row is owned by macOS: `app.settings` and anything else with `owner == .system`.
    case notRebindable(ShortcutAction)
    /// A modifier is required: a bare letter would be typed into the composer instead.
    case needsModifier(ShortcutCombo)
    /// macOS keeps this one — ⌘Q, ⌘W, ⌘, …
    case reserved(ShortcutCombo)
    /// Another action already holds it. Names the holder, because "in use" without saying by what
    /// leaves the owner hunting through twenty rows.
    case duplicate(ShortcutAction)

    /// One sentence, naming the other action where there is one to name.
    public var message: String {
        switch self {
        case .notRebindable(let action):
            return "macOS owns \(action.title); it cannot be rebound here."
        case .needsModifier:
            return "Hold ⌘, ⌥, ⌃ or ⇧ with the key — a bare key would be typed into the message."
        case .reserved(let combo):
            return "\(combo.label) is reserved by macOS and cannot be assigned."
        case .duplicate(let action):
            return "\(action.title) already uses this combination."
        }
    }
}
