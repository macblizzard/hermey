import Foundation

/// One bot as the share sheet may name it.
///
/// Deliberately two fields. The extension has no host connection, no token and no gateway client —
/// it cannot ask who the bots are, and it must not try. Everything it is allowed to know arrives in
/// this snapshot, written by the app while it was paired.
public struct ShareBot: Codable, Hashable, Sendable, Identifiable {
    /// The profile name, exactly as the host spells it: the `{profile}` in the send route.
    public var id: String
    public var displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = trimmed.isEmpty ? id : trimmed
    }
}

public enum ShareBotSnapshotVersion {
    public static let version = 1
}

public struct ShareBotSnapshot: Codable, Hashable, Sendable {
    public var version: Int
    public var generatedAt: Date
    public var bots: [ShareBot]
    /// The bot the app last opened, preselected here so the common share is one tap.
    public var defaultBotID: String?

    public init(generatedAt: Date = Date(), bots: [ShareBot], defaultBotID: String? = nil) {
        self.version = ShareBotSnapshotVersion.version
        self.generatedAt = generatedAt
        self.bots = bots
        self.defaultBotID = defaultBotID
    }

    public func isStale(asOf now: Date, maximumAge: TimeInterval) -> Bool {
        now.timeIntervalSince(generatedAt) > maximumAge
    }
}

/// What the picker is allowed to show, and the sentence to show when it is allowed to show nothing.
///
/// A stale list is not offered at all: a bot deleted on the host would still be in it, and a share
/// addressed to a profile that no longer exists is a 404 the owner reads as "sharing is broken".
public enum ShareBotSnapshotState: Equatable {
    case ready(ShareBotSnapshot)
    case stale(ShareBotSnapshot?)
    case missing
    /// The App Group container itself is absent, so there is no directory a snapshot could be in.
    /// Distinct from `.missing` on purpose: "the app never wrote the list" is fixed by opening the
    /// app, and this is fixed by signing the build with the app-group entitlement. Telling a person
    /// to open an app they have opened is the kind of instruction that makes a feature look broken.
    case noStorage
}

public enum ShareBotSnapshotStore {
    /// Long enough that a phone which has not opened Hermey this week still works, short enough
    /// that a bot added or renamed on the host is not invisible for a month.
    public static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    /// Called by the app whenever the bot list it holds changes. Never by the extension.
    public static func publish(_ bots: [(id: String, displayName: String)],
                               defaultBotID: String? = nil,
                               to storage: ShareInboxStorage = .live,
                               now: Date = Date()) throws {
        try storage.ensureDirectories()
        guard let url = storage.botSnapshotURL else { throw ShareInboxError.noContainer }
        let snapshot = ShareBotSnapshot(generatedAt: now,
                                        bots: bots.map { ShareBot(id: $0.id, displayName: $0.displayName) },
                                        defaultBotID: defaultBotID)
        try ShareInboxStorage.makeEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    public static func load(from storage: ShareInboxStorage,
                            now: Date = Date(),
                            maximumAge: TimeInterval = ShareBotSnapshotStore.maximumAge) -> ShareBotSnapshotState {
        // Asked first: with no container every path below is `nil`, and reporting that as "the app
        // has not written the list yet" would send the person to an app that already did.
        guard storage.isAvailable else { return .noStorage }
        guard let url = storage.botSnapshotURL,
              let data = try? Data(contentsOf: url) else { return .missing }
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data),
              probe.version == ShareBotSnapshotVersion.version,
              let snapshot = try? ShareInboxStorage.makeDecoder().decode(ShareBotSnapshot.self, from: data) else {
            // A snapshot from a newer build is not reinterpreted: the picker asks the person to open
            // the app, which is the one action that replaces this file with one we understand.
            return .missing
        }
        return snapshot.isStale(asOf: now, maximumAge: maximumAge) ? .stale(snapshot) : .ready(snapshot)
    }

    private struct VersionProbe: Decodable {
        let version: Int
    }
}
