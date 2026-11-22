#if os(iOS)
import Foundation
import SwiftUI

/// The sheet's brain: what it can offer as a destination, what it is carrying, and the one write
/// that hands both to the app.
///
/// It owns no network client and no credential. The only way it learns a bot's name is the snapshot
/// the app left in the App Group; the only way it delivers is a file plus a URL. That is deliberate:
/// a share extension is launched into other apps' processes, runs for seconds, and is the least
/// trusted place in the app to keep a token.
@MainActor
final class ShareComposer: ObservableObject {
    /// The sentence for a build with no shared container at all. One copy: it is said in two
    /// places — the picker, and a write that could not land — and the two must not drift apart.
    static let noStorageMessage =
        "Hermey has no shared storage yet — this build's signing may not include app groups."
    /// The sentence for a container that exists with no list in it. Only *this* one asks the person
    /// to open the app, because opening it is the only thing that writes the file.
    static let missingSnapshotMessage = "Open Hermey once to fetch your bot list."

    let storage: ShareInboxStorage
    let payloadID: UUID

    @Published private(set) var bots: [ShareBot] = []
    /// The sentence shown where the list would be when there is no list to show. Each sentence
    /// names one cause, because the three causes have three different fixes.
    @Published private(set) var notice: String?
    @Published var selectedBotID: String?
    @Published private(set) var draft = ShareDraft()
    @Published private(set) var isLoading = true
    @Published private(set) var isSending = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var didSend = false

    /// Supplied by `ShareViewController`: a share extension cannot use `UIApplication.shared`, so
    /// bringing the app forward is a capability only the view controller holds.
    var openApp: (() -> Void)?

    private var didPrepare = false

    init(storage: ShareInboxStorage = .live, payloadID: UUID = UUID()) {
        self.storage = storage
        self.payloadID = payloadID
        loadBots()
    }

    // MARK: - Destinations

    private func loadBots() {
        switch ShareBotSnapshotStore.load(from: storage) {
        case .ready(let snapshot):
            bots = snapshot.bots
            if snapshot.bots.isEmpty {
                // A paired host with no profiles is odd but real; an empty list would look broken.
                notice = "No bots yet. Add one in Hermey, then share again."
            } else {
                let preferred = snapshot.defaultBotID.flatMap { id in
                    snapshot.bots.contains(where: { $0.id == id }) ? id : nil
                }
                selectedBotID = preferred ?? snapshot.bots.first?.id
            }
        case .noStorage:
            // Not "open the app": opening it cannot create a container the build never asked for.
            bots = []
            notice = Self.noStorageMessage
        case .missing:
            // A container exists and holds no list, so the app has not published one in this
            // install yet. Opening it once is the fix, and the only one.
            bots = []
            notice = Self.missingSnapshotMessage
        case .stale(let snapshot):
            bots = []
            notice = Self.staleNotice(snapshot)
        }
    }

    /// Names the staleness instead of hiding it: a week-old list is why a bot that was renamed on
    /// the host is not showing, and saying so is the difference between a bug and a rule.
    private static func staleNotice(_ snapshot: ShareBotSnapshot?, now: Date = Date()) -> String {
        guard let snapshot else {
            return "The bot list is out of date. Open Hermey to refresh it, then share again."
        }
        let days = Int(now.timeIntervalSince(snapshot.generatedAt) / (24 * 60 * 60))
        let age = days <= 1 ? "more than a day" : "\(days) days"
        return "The bot list is \(age) out of date. Open Hermey to refresh it, or tap Reload."
    }

    /// Re-reads the snapshot in place.
    ///
    /// The container is written by the app, which may have been opened while this sheet was up —
    /// from the very deep link a previous share opened, for instance. Cancelling and sharing the
    /// item again to see the new answer is work the person should not have to do.
    func reloadBots() {
        let previous = selectedBotID
        bots = []
        notice = nil
        selectedBotID = nil
        loadBots()
        // Keep the pick across a reload when it survived: the list changed, the choice need not.
        if let previous, bots.contains(where: { $0.id == previous }) {
            selectedBotID = previous
        }
    }

    var canSend: Bool {
        !isLoading && !isSending && !didSend && selectedBotID != nil && !draft.isEmpty
    }

    // MARK: - Reading the shared item

    /// Idempotent: SwiftUI may run `.task` again when the sheet reappears, and re-importing would
    /// copy the same photo into the container twice.
    func prepare(items: [NSExtensionItem]) async {
        guard !didPrepare else { return }
        didPrepare = true
        defer { isLoading = false }
        draft = await ShareItemImporter.draft(from: items, payloadID: payloadID, storage: storage)
        if draft.isEmpty {
            // The importer's own sentences name the item and the reason; the generic line is only
            // for a share that held nothing at all to begin with.
            errorMessage = draft.issueSummary
                ?? "Nothing to send: this item has no text, link or file."
        }
    }

    // MARK: - Sending

    func send() async {
        guard !isSending, !didSend,
              let botID = selectedBotID,
              let bot = bots.first(where: { $0.id == botID }),
              !draft.isEmpty else { return }
        isSending = true
        defer { isSending = false }

        let payload = SharePayload(id: payloadID,
                                   botID: bot.id,
                                   botName: bot.displayName,
                                   text: draft.text,
                                   urlString: draft.urlString,
                                   attachments: draft.attachments)
        do {
            try storage.write(payload)
        } catch {
            // Nothing was handed over, so the sheet stays open with the reason. A closed sheet would
            // read as "sent" while nothing is queued.
            errorMessage = storage.isAvailable
                ? writeFailureMessage(for: error)
                : Self.noStorageMessage
            return
        }
        didSend = true
        openApp?()
    }

    private func writeFailureMessage(for error: Error) -> String {
        if let inbox = error as? ShareInboxError,
           case .tooLarge(let byteCount, let maximumBytes) = inbox {
            return "Hermey could not take this share: \(ShareImportIssue.size(byteCount)) is over the \(ShareImportIssue.size(maximumBytes)) limit."
        }
        return "Hermey could not take this share. Try again."
    }
}
#endif
