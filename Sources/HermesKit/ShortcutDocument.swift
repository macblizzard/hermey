import Foundation

// MARK: - What one row is bound to

/// A row's stored state: a combination, or "deliberately unbound".
///
/// The second case is not the absence of a value. An action that ships with a key and has been
/// cleared by its owner must stay cleared; an action that ships with no key and has never been
/// touched is the default. Storing `nil` for both would make clearing impossible — the default would
/// silently come back on the next launch.
public enum ShortcutBinding: Equatable, Sendable, Codable {
    case combo(ShortcutCombo)
    case unassigned

    public var combo: ShortcutCombo? {
        if case .combo(let combo) = self { return combo }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .unassigned
            return
        }
        self = .combo(try ShortcutCombo(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .combo(let combo): try container.encode(combo)
        case .unassigned: try container.encodeNil()
        }
    }
}

// MARK: - The stored document

/// The owner's own bindings, resolved against ``ShortcutRegistry``.
///
/// **Shape.** One JSON document in the app's `UserDefaults`, keyed by action *id*:
///
/// ```json
/// {
///   "version": 1,
///   "bindings": {
///     "turn.send": { "key": "return", "modifiers": ["command"] },
///     "bot.settings": null
///   }
/// }
/// ```
///
/// The document holds **overrides only**: an id with no row is at its shipped default, so a build
/// that adds an action does not need a migration, and a build that removes one leaves a key the
/// loader ignores.
///
/// **Unknown ids tolerate, corrupt values drop.** A file written by a newer build can name an action
/// this one has never heard of, and a hand-edited file can contain a key that is not a key. Neither
/// may cost the owner every other binding, so decoding is per entry: a row that does not parse is
/// discarded and the rest of the document stands. ``LenientBinding`` is where that happens.
public struct ShortcutDocument: Equatable, Sendable {

    /// The schema version. Bumped only when the *document* changes shape, never when an action is
    /// added: overrides are keyed by id, so adding rows is not a migration.
    public static let version = 1

    /// Stored overrides, by action id. Absent = the registry's default.
    public private(set) var bindings: [String: ShortcutBinding]

    public init(bindings: [String: ShortcutBinding] = [:]) {
        self.bindings = bindings
    }

    /// The shipped state: no overrides at all.
    public static let standard = ShortcutDocument()

    // MARK: Reading

    /// The combination a row currently has, or `nil` when it has none.
    ///
    /// The one place default and override meet. Every reader — the menu, the palette, the pane —
    /// goes through here, so none of them can disagree about what a key does.
    public func resolved(_ id: String) -> ShortcutCombo? {
        guard let action = ShortcutRegistry.action(id) else { return nil }
        if let stored = bindings[id] { return stored.combo }
        return action.defaultCombo
    }

    /// Whether this row has been changed from what the app shipped with.
    public func isCustomised(_ id: String) -> Bool {
        guard let stored = bindings[id], let action = ShortcutRegistry.action(id) else { return false }
        return stored.combo != action.defaultCombo
    }

    /// Whether anything at all has been changed — what enables "Restore Defaults".
    public var hasCustomisations: Bool {
        ShortcutRegistry.actions.contains { isCustomised($0.id) }
    }

    /// The action holding `combo`, if any. The conflict test, stated once.
    public func owner(of combo: ShortcutCombo, excluding excluded: String? = nil) -> ShortcutAction? {
        for action in ShortcutRegistry.actions where action.id != excluded {
            if resolved(action.id) == combo { return action }
        }
        return nil
    }

    // MARK: Writing

    /// Bind `combo` (or nothing, for `.unassigned`) to `action`, or say why not.
    ///
    /// A refusal changes nothing: the document is only mutated after every rule has passed, so a
    /// rejected press cannot leave half a binding behind.
    @discardableResult
    public mutating func set(_ binding: ShortcutBinding, for id: String) -> ShortcutRejection? {
        guard let action = ShortcutRegistry.action(id) else { return nil }
        if case .combo(let combo) = binding {
            if let rejection = ShortcutRegistry.rejection(of: combo, for: action, in: self) {
                return rejection
            }
        } else {
            guard action.isRebindable else { return .notRebindable(action) }
        }
        bindings[id] = binding
        return nil
    }

    /// Put one row back to its shipped combination.
    public mutating func reset(_ id: String) {
        bindings.removeValue(forKey: id)
    }

    /// Put every row back.
    public mutating func restoreDefaults() {
        bindings.removeAll()
    }

    /// Drop anything this build cannot draw: an id that no longer exists, or a binding equal to the
    /// default (which is the same state, spelled shorter).
    public mutating func prune() {
        bindings = bindings.filter { id, binding in
            guard let action = ShortcutRegistry.action(id) else { return false }
            return binding.combo != action.defaultCombo
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case version
        case bindings
    }

    /// A row that fails to parse is dropped instead of failing the whole document.
    ///
    /// `Decodable` normally propagates a child's error, and one hand-edited character in one row
    /// would then erase every other binding the owner had set. This wrapper swallows it, and
    /// ``ShortcutDocument/init(from:)`` keeps only the rows that arrived.
    private struct LenientBinding: Decodable {
        let binding: ShortcutBinding?

        init(from decoder: Decoder) throws {
            binding = try? ShortcutBinding(from: decoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A version from the future is read, not refused: overrides are additive, so the rows this
        // build understands are still the owner's rows.
        _ = try container.decodeIfPresent(Int.self, forKey: .version)
        let raw = try container.decodeIfPresent([String: LenientBinding].self, forKey: .bindings) ?? [:]
        var kept: [String: ShortcutBinding] = [:]
        for (id, wrapper) in raw {
            guard let binding = wrapper.binding else { continue }
            guard ShortcutRegistry.action(id) != nil else { continue }
            kept[id] = binding
        }
        bindings = kept
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ShortcutDocument.version, forKey: .version)
        try container.encode(bindings, forKey: .bindings)
    }
}

// MARK: - Where it lives

/// The document, in the app's own `UserDefaults`.
///
/// One key, one document, per app — the same arrangement as ``BotChatCeiling`` and for the same
/// reason: a keyboard belongs to the device it is plugged into, not to the host it is talking to, so
/// this is not stored on the host and not per bot. The key is namespaced (`hermey.`) so the file
/// cannot collide with a preference another build owns.
public struct ShortcutStore {

    /// The one key.
    public static let defaultsKey = "hermey.shortcuts"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored document, or the shipped one. A file that is not JSON at all is treated as the
    /// shipped one: there is nothing in it worth a crash, and the next write replaces it.
    public func load() -> ShortcutDocument {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return .standard }
        guard let document = try? JSONDecoder().decode(ShortcutDocument.self, from: data) else {
            return .standard
        }
        return document
    }

    public func save(_ document: ShortcutDocument) {
        guard let data = try? JSONEncoder().encode(document) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Forget everything: the next launch is a fresh install's.
    public func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
