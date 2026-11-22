import Foundation

/// Why the inbox could not be used.
public enum ShareInboxError: Error, Equatable {
    /// The App Group entitlement is missing or the container was not created yet. Both the app and
    /// the extension see this before the group exists; it is a state, not a crash.
    case noContainer
    /// The item is larger than one payload may carry.
    case tooLarge(byteCount: Int, maximumBytes: Int)
}

/// The one description of where shares live, compiled into both the app and the extension.
///
/// Neither side holds a copy of these paths: a renamed directory would otherwise mean the
/// extension writes where the app never looks, which looks exactly like "sharing does nothing".
public struct ShareInboxStorage: Sendable {
    /// Must match `com.apple.security.application-groups` in both entitlements files.
    /// `group.<bundle id prefix>` is the convention Xcode expects for a personal team.
    public static let appGroupIdentifier = "group.dev.hermey.app"

    /// How much one shared item may carry. The App Group is a shared container on the phone's own
    /// disk, not a message queue; a 200 MB video parked there would sit until the app next ran.
    public static let maximumAttachmentBytes = 20 * 1024 * 1024

    /// `nil` when the App Group is unavailable (entitlement missing, or the extension is running
    /// in a host that never created the group). Every method then fails quietly or throws
    /// `.noContainer`, so a caller can show an instruction rather than a spinner that never ends.
    public let root: URL?

    public init(containerURL: URL?) {
        self.root = containerURL
    }

    /// A plain directory, for previews and for the tests' temporary trees.
    public init(rootDirectory: URL) {
        self.root = rootDirectory
    }

    public static var live: ShareInboxStorage {
        ShareInboxStorage(containerURL: FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier))
    }

    public var isAvailable: Bool { root != nil }

    // MARK: - Layout

    /// `Share/` — everything this feature owns inside the group container.
    public var shareDirectory: URL? { root?.appendingPathComponent("Share", isDirectory: true) }
    /// `Share/Inbox/` — one JSON file per share waiting for the app.
    public var inboxDirectory: URL? { shareDirectory?.appendingPathComponent("Inbox", isDirectory: true) }
    /// `Share/Inbox/Assets/<payload id>/` — the bytes, copied in while the extension is alive.
    public var assetsDirectory: URL? { inboxDirectory?.appendingPathComponent("Assets", isDirectory: true) }
    /// `Share/Inbox/Sending/` — a claim on a payload, so a second reader cannot take it too.
    public var sendingDirectory: URL? { inboxDirectory?.appendingPathComponent("Sending", isDirectory: true) }
    /// `Share/Inbox/Delivered/` — one empty marker per accepted payload, written before the JSON
    /// is deleted. This is what makes a relaunch with a stale file a no-op instead of a resend.
    public var deliveredDirectory: URL? { inboxDirectory?.appendingPathComponent("Delivered", isDirectory: true) }
    /// `Share/Inbox/Rejected/` — payloads this build cannot read. Kept, not deleted: a newer
    /// extension's file is evidence, and deleting it would hide the version skew.
    public var rejectedDirectory: URL? { inboxDirectory?.appendingPathComponent("Rejected", isDirectory: true) }
    /// `Share/Bots/snapshot.json` — the picker's only source, written by the app.
    public var botSnapshotURL: URL? {
        shareDirectory?.appendingPathComponent("Bots", isDirectory: true)
            .appendingPathComponent("snapshot.json")
    }

    // MARK: - Directories

    public func ensureDirectories() throws {
        guard root != nil else { throw ShareInboxError.noContainer }
        let directories = [shareDirectory, inboxDirectory, assetsDirectory, sendingDirectory,
                           deliveredDirectory, rejectedDirectory, botSnapshotURL?.deletingLastPathComponent()]
        for directory in directories.compactMap({ $0 }) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    // MARK: - Writing (the extension)

    /// Copies bytes into `Assets/<payload id>/` and returns the reference that goes in the payload.
    ///
    /// The caller hands over `Data`, never a URL: a URL from `loadFileRepresentation` lives in the
    /// extension's temporary directory and is gone by the time the app reads the payload.
    public func importAttachment(_ data: Data,
                                 kind: ShareAttachment.Kind,
                                 typeIdentifier: String?,
                                 originalName: String?,
                                 fileExtension: String?,
                                 for payloadID: UUID) throws -> ShareAttachment {
        guard data.count <= Self.maximumAttachmentBytes else {
            throw ShareInboxError.tooLarge(byteCount: data.count,
                                           maximumBytes: Self.maximumAttachmentBytes)
        }
        try ensureDirectories()
        guard let assets = assetsDirectory else {
            throw ShareInboxError.noContainer
        }
        let payloadDirectory = assets.appendingPathComponent(Self.identifier(payloadID), isDirectory: true)
        try FileManager.default.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)
        let attachmentID = UUID()
        let name = "\(Self.identifier(attachmentID)).\(Self.fileExtension(fileExtension ?? typeIdentifier))"
        let destination = payloadDirectory.appendingPathComponent(name)
        try data.write(to: destination, options: .atomic)
        return ShareAttachment(id: attachmentID,
                               kind: kind,
                               fileName: name,
                               typeIdentifier: typeIdentifier,
                               originalName: Self.originalName(originalName),
                               byteCount: data.count)
    }

    /// Writes the payload last: the JSON is the commit, so a reader can never see a payload whose
    /// images have not been copied in yet.
    @discardableResult
    public func write(_ payload: SharePayload) throws -> URL {
        try ensureDirectories()
        guard let inbox = inboxDirectory else { throw ShareInboxError.noContainer }
        let destination = inbox.appendingPathComponent("\(Self.identifier(payload.id)).json")
        let data = try Self.makeEncoder().encode(payload)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// Where the bytes for one attachment live. The app reads this to build the host attachment.
    public func url(for attachment: ShareAttachment, payloadID: UUID) -> URL? {
        assetsDirectory?
            .appendingPathComponent(Self.identifier(payloadID), isDirectory: true)
            .appendingPathComponent(attachment.fileName)
    }

    // MARK: - Reading (the app)

    /// Oldest first, so a burst of shares arrives in the order it was shared.
    public func pendingPayloadURLs() -> [URL] {
        guard let inbox = inboxDirectory,
              let names = try? FileManager.default.contentsOfDirectory(
                at: inbox,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { return [] }
        return names
            .filter { $0.pathExtension == SharePayloadSchema.payloadFileExtension }
            .sorted { modificationDate($0) < modificationDate($1) }
    }

    public func loadPending(at url: URL) throws -> SharePayload {
        try Self.makeDecoder().decode(SharePayload.self, from: Data(contentsOf: url))
    }

    /// Takes the file out of `Inbox/` by renaming it into `Sending/`.
    ///
    /// A rename inside one volume is atomic, so two readers racing — the deep link and the
    /// foreground drain, say — cannot both win. The loser finds nothing to claim.
    public func claim(_ url: URL) throws -> URL {
        try ensureDirectories()
        guard let sending = sendingDirectory else { throw ShareInboxError.noContainer }
        let destination = sending.appendingPathComponent(url.lastPathComponent)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: url, to: destination)
        return destination
    }

    /// Puts a claimed payload back in line. Used when the app could not accept it, so a share made
    /// offline is delivered on the next run instead of being silently dropped.
    public func restore(_ claimed: URL) throws {
        guard let inbox = inboxDirectory else { throw ShareInboxError.noContainer }
        let destination = inbox.appendingPathComponent(claimed.lastPathComponent)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            // A newer identical payload is already queued; this claim is a superseded copy.
            try fileManager.removeItem(at: claimed)
            return
        }
        try fileManager.moveItem(at: claimed, to: destination)
    }

    /// Records acceptance, *then* deletes the payload.
    ///
    /// Order matters: a crash between the two leaves a delivered marker and a stale file, and the
    /// next drain deletes without sending again. Deleting first would leave the opposite — a share
    /// that vanished without being delivered.
    ///
    /// The attachment bytes are deliberately left behind. Acceptance returns before an upload has
    /// finished, so removing them here would pull the file out from under a message that is still
    /// being sent. `prune` reclaims them a day later; `removeAssets` exists for a caller that knows
    /// the upload is done and would rather not wait.
    public func finish(_ claimed: URL, payloadID: UUID) throws {
        try markDelivered(payloadID)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: claimed.path) {
            try fileManager.removeItem(at: claimed)
        }
    }

    public func markDelivered(_ payloadID: UUID) throws {
        try ensureDirectories()
        guard let delivered = deliveredDirectory else { throw ShareInboxError.noContainer }
        let marker = delivered.appendingPathComponent("\(Self.identifier(payloadID)).done")
        try Data().write(to: marker, options: .atomic)
    }

    public func isDelivered(_ payloadID: UUID) -> Bool {
        guard let delivered = deliveredDirectory else { return false }
        return FileManager.default.fileExists(
            atPath: delivered.appendingPathComponent("\(Self.identifier(payloadID)).done").path)
    }

    public func removeAssets(_ payloadID: UUID) throws {
        guard let assets = assetsDirectory else { return }
        let directory = assets.appendingPathComponent(Self.identifier(payloadID), isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// Parks an unreadable payload instead of destroying it.
    public func reject(_ url: URL) throws {
        try ensureDirectories()
        guard let rejected = rejectedDirectory else { throw ShareInboxError.noContainer }
        let destination = rejected.appendingPathComponent(url.lastPathComponent)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: url, to: destination)
    }

    public func pendingCount() -> Int { pendingPayloadURLs().count }

    // MARK: - Housekeeping

    /// Removes what nothing points at any more. Called at the end of a drain; cheap and idempotent.
    ///
    /// A share whose app was deleted, or whose delivery marker is a week old, would otherwise sit
    /// in the group container until iOS decides the storage pressure is the user's problem.
    public func prune(now: Date = Date()) {
        let fileManager = FileManager.default
        pruneMarkers(in: deliveredDirectory, olderThan: 7 * 24 * 60 * 60, now: now)
        pruneMarkers(in: rejectedDirectory, olderThan: 7 * 24 * 60 * 60, now: now)
        guard let assets = assetsDirectory,
              let directories = try? fileManager.contentsOfDirectory(
                at: assets, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { return }
        for directory in directories {
            let id = directory.lastPathComponent
            let queued = inboxDirectory?.appendingPathComponent("\(id).json")
            let claimed = sendingDirectory?.appendingPathComponent("\(id).json")
            let isQueued = queued.map { fileManager.fileExists(atPath: $0.path) } ?? false
            let isClaimed = claimed.map { fileManager.fileExists(atPath: $0.path) } ?? false
            guard !isQueued, !isClaimed else { continue }
            // A reader may be between writing bytes and writing the JSON; give it a day.
            guard modificationDate(directory).addingTimeInterval(24 * 60 * 60) < now else { continue }
            try? fileManager.removeItem(at: directory)
        }
    }

    private func pruneMarkers(in directory: URL?, olderThan age: TimeInterval, now: Date) {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { return }
        for name in names where modificationDate(name).addingTimeInterval(age) < now {
            try? FileManager.default.removeItem(at: name)
        }
    }

    // MARK: - Helpers

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? .distantPast
    }

    /// Fresh coders per call. A shared `JSONEncoder` is not documented thread-safe, and this type
    /// is used from the app's main actor and the extension's loader at the same time.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func identifier(_ id: UUID) -> String { id.uuidString.lowercased() }

    /// A file name component from a UTI (`public.jpeg`) or an extension (`jpg`). Never a path, and
    /// never anything the filesystem would read as one.
    static func fileExtension(_ candidate: String?) -> String {
        guard let candidate, !candidate.isEmpty else { return "dat" }
        let tail = candidate.split(separator: ".").last.map(String.init) ?? candidate
        let cleaned = tail.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !cleaned.isEmpty, cleaned.count <= 8, cleaned != "data" else { return "dat" }
        return cleaned
    }

    static func originalName(_ candidate: String?) -> String? {
        guard let candidate, !candidate.isEmpty else { return nil }
        let last = (candidate as NSString).lastPathComponent
        let cleaned = last
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(120))
    }
}
