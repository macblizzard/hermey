import Foundation
import SwiftUI

/// One Hermes slash command, as the client knows it.
///
/// The catalogue is a mirror of the host's command set. Commands that Hermey can perform itself carry
/// a native action; everything else is completed into the field with its argument hint so the user can
/// type the rest and send it to the host. A command we cannot perform is never silently swallowed.
public struct HermesCommand: Identifiable, Hashable, Sendable {
    public let name: String
    public let detail: String
    /// What follows the name when it needs an argument, e.g. `name` for `/model`. Nil for bare verbs.
    public let argument: String?
    public let systemImage: String
    public let action: HermesCommandAction
    /// Commands that act on the host or the gateway rather than this conversation have a marker in the
    /// list, so nobody thinks a local UI ran them.
    public let isHostCommand: Bool

    public var id: String { name }
    public var invocation: String { "/" + name + (argument == nil ? "" : " ") }

    public init(name: String, detail: String, argument: String? = nil,
                systemImage: String = "terminal", action: HermesCommandAction = .insertOnly,
                isHostCommand: Bool = false) {
        self.name = name
        self.detail = detail
        self.argument = argument
        self.systemImage = systemImage
        self.action = action
        self.isHostCommand = isHostCommand
    }
}

/// What a command does when picked. `.insertOnly` is the default: fill the composer, let the user add
/// arguments, and send. The others are the verbs Hermey already has a first-class UI or method for.
public enum HermesCommandAction: String, Hashable, Sendable {
    case insertOnly
    case help
    case newSession
    case resetConversation
    case compact
    case model
    case reasoning
    case memory
    case status
}

/// Filtering as the user types `/mod…`: prefix first, then a name containing the query, so a short
/// fragment still finds a command without making the list jump around once a prefix stops matching.
public extension Array where Element == HermesCommand {
    func matching(_ query: String) -> [HermesCommand] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return self }
        let prefixed = filter { $0.name.hasPrefix(needle) }
        return prefixed.isEmpty
            ? filter { $0.name.contains(needle) || $0.detail.lowercased().contains(needle) }
            : prefixed
    }
}
