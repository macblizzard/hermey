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
    let storage: ShareInboxStorage
    let payloadID: UUID

    @Published private(set) var bots: [ShareBot] = []
    /// The sentence shown where the list would be when there is no list to show.
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
        case .stale:
            bots = []
            notice = "The bot list is out of date. Open Hermey to refresh it, then share again."
        case .missing:
            bots = []
            notice = "Open Hermey once so it can list your bots here."
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
            errorMessage = "Nothing to send: this item has no text, link or image."
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
                ? "Hermey could not take this share. Try again."
                : "Hermey has no shared storage yet. Open Hermey once, then share again."
            return
        }
        didSend = true
        openApp?()
    }
}
#endif
