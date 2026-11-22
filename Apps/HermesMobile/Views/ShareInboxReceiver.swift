#if os(iOS)
import Combine
import Foundation

/// The app's half of share-sheet delivery.
///
/// The extension cannot talk to the host: it has no pairing, no token and no socket, and it is gone
/// before a connection could be made. So it leaves a payload in the App Group container and opens
/// `hermey://share`; this type reads what is there, hands each payload to the app's own send path,
/// and deletes it only once that path said yes.
///
/// What it guarantees, and why:
///
/// - **Claim before sending.** A payload is renamed from `Inbox/` into `Sending/` before the accept
///   closure runs. Two readers — the deep link and the foreground drain — cannot both deliver the
///   same share, because only one rename can succeed.
/// - **Marker before delete.** Acceptance writes `Delivered/<id>.done` and only then removes the
///   JSON and the bytes. A crash in between leaves a stale file that the next run deletes without
///   sending, which is the failure mode a person notices least: one message instead of two.
/// - **Put it back on refusal.** If the app cannot send — offline, host asleep — the claim is
///   renamed back into `Inbox/`, oldest still first, so a share made in a lift is delivered when
///   the phone next has a network rather than lost.
///
/// Wiring (the app's files, not this one):
///
/// ```swift
/// // once, when the bot list changes, so the sheet has something to offer
/// try? ShareBotSnapshotStore.publish(model.bots.map { ($0.id, $0.displayName) },
///                                    defaultBotID: model.selectedBotID)
///
/// // on launch and on every foreground
/// await ShareInboxReceiver.shared.drain { payload in
///     await model.deliverShared(payload)   // the parent's adapter over the send path
/// }
///
/// // in `.onOpenURL`
/// if ShareInboxReceiver.isShareInboxURL(url) { Task { await drain() } }
/// ```
@MainActor
final class ShareInboxReceiver: ObservableObject {
    static let shared = ShareInboxReceiver()
    /// The one URL the extension opens. It must stay registered in the app's `CFBundleURLTypes`
    /// under the `hermey` scheme (it already is, for `hermey://bot/<profile>`).
    static let deepLink = URL(string: "hermey://share")!

    /// The last payload the app accepted, so the shell can open that bot's conversation. Cleared by
    /// whoever consumes it; a stale value must not push a thread on the next launch.
    @Published private(set) var lastAccepted: SharePayload?
    /// A share arrived that this build could not read. The file was parked in `Rejected/`, not
    /// deleted, so it can be inspected after a version skew.
    @Published private(set) var lastError: String?
    @Published private(set) var pendingCount = 0

    private let storage: ShareInboxStorage
    private var isDraining = false

    init(storage: ShareInboxStorage = .live) {
        self.storage = storage
        self.pendingCount = storage.pendingCount()
    }

    static func isShareInboxURL(_ url: URL) -> Bool {
        url.scheme == "hermey" && url.host == "share"
    }

    /// Where an accepted payload's bytes live, for the app to read into the host attachment.
    func url(for attachment: ShareAttachment, payloadID: UUID) -> URL? {
        storage.url(for: attachment, payloadID: payloadID)
    }

    func data(for attachment: ShareAttachment, payloadID: UUID) -> Data? {
        guard let url = storage.url(for: attachment, payloadID: payloadID) else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// Delivers everything queued, oldest first. Safe to call from anywhere, any number of times.
    ///
    /// `accept` returns true only when the app has taken responsibility for the payload — queued
    /// for the host counts. It must have read any attachment bytes it still needs by the time it
    /// returns; the payload file is removed immediately after, and the bytes follow within a day.
    /// A false result stops the pass so the remaining shares keep their order and are retried
    /// together next time.
    func drain(accept: (SharePayload) async -> Bool) async {
        guard !isDraining else { return }
        isDraining = true
        defer {
            isDraining = false
            pendingCount = storage.pendingCount()
        }

        for url in storage.pendingPayloadURLs() {
            let payload: SharePayload
            do {
                payload = try storage.loadPending(at: url)
            } catch {
                // Unreadable is either corruption or a newer schema. Park it and say so; deleting
                // it would destroy the only copy of something a person deliberately shared.
                try? storage.reject(url)
                lastError = "A shared item could not be read."
                continue
            }

            // A previous run accepted this one and died before removing the file.
            if storage.isDelivered(payload.id) {
                if let claimed = try? storage.claim(url) {
                    try? storage.finish(claimed, payloadID: payload.id)
                }
                continue
            }

            guard let claimed = try? storage.claim(url) else { continue }
            let accepted = await accept(payload)
            guard accepted else {
                try? storage.restore(claimed)
                break
            }
            try? storage.finish(claimed, payloadID: payload.id)
            lastAccepted = payload
            lastError = nil
        }

        storage.prune()
    }

    func consumeLastAccepted() -> SharePayload? {
        defer { lastAccepted = nil }
        return lastAccepted
    }
}
#endif
