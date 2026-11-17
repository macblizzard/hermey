import Foundation

/// The host's approval mode, applied to every bot profile at once.
///
/// The three spellings are the host's own (`hermes_cli.approval_mode`): `manual` asks every time,
/// `smart` lets the host decide which calls need a person, and `off` never asks. The app's labels are
/// friendlier, but the wire value is never translated into something the terminal guard would ignore.
public enum ApprovalMode: String, CaseIterable, Sendable, Equatable {
    case manual
    case smart
    case off

    public var title: String {
        switch self {
        case .manual: return "Ask always"
        case .smart: return "Auto"
        case .off: return "Allow always"
        }
    }

    /// The option we recommend when nothing has been chosen yet. Smart still asks for the actions the
    /// host considers dangerous — it is the safe default, unlike `off`.
    public static let recommended: ApprovalMode = .smart

    public var detail: String {
        switch self {
        case .manual: return "Ask for approval on every guarded action"
        case .smart: return "Hermes decides which actions really need approval"
        case .off: return "Run every guarded action without asking (unsafe)"
        }
    }
}

/// What the bridge reported for the fleet. `mixed` is a real state: profiles can be edited on the
/// host or by another device, so a single-mode assumption would hide a mismatch.
public struct ApprovalSettings: Equatable, Sendable {
    public let mode: ApprovalMode?
    public let profiles: [String: ApprovalMode]
    /// Profiles with no explicit mode set on the host. The app uses this to apply the recommended
    /// default once, rather than showing Auto while the host still enforces its fallback.
    public let unset: [String]
    public let updated: [String]
    public let failed: [String: String]

    public init(mode: ApprovalMode?, profiles: [String: ApprovalMode], unset: [String] = [],
                updated: [String] = [], failed: [String: String] = [:]) {
        self.mode = mode
        self.profiles = profiles
        self.unset = unset
        self.updated = updated
        self.failed = failed
    }

    static func decode(_ data: Data) -> ApprovalSettings? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var profiles: [String: ApprovalMode] = [:]
        if let raw = object["profiles"] as? [String: String] {
            for (name, mode) in raw {
                guard let parsed = ApprovalMode(rawValue: mode) else { return nil }
                profiles[name] = parsed
            }
        }
        let mode = (object["mode"] as? String).flatMap(ApprovalMode.init(rawValue:))
        var failed: [String: String] = [:]
        if let raw = object["failed"] as? [String: String] { failed = raw }
        return ApprovalSettings(mode: mode,
                                profiles: profiles,
                                unset: object["unset"] as? [String] ?? [],
                                updated: object["updated"] as? [String] ?? [],
                                failed: failed)
    }
}
