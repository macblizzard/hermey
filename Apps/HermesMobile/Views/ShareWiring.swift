#if os(iOS)
import Foundation
import HermesKit
import HermesAppKit

/// The app's half of the share sheet: what it leaves in the App Group, and where the app picks it up.
///
/// Two jobs, both of them the app's and neither of them the extension's:
///
/// 1. **Keep the picker's list current.** The extension cannot ask who the bots are — it has no
///    pairing, no token and no socket — so `ShareBotSnapshotStore.publish` writes the roster this
///    model already holds into `Share/Bots/snapshot.json`. Called after the roster loads and after
///    it changes; identical writes are skipped, and the write itself happens off the main thread.
/// 2. **Deliver what was shared.** `ShareInboxReceiver` owns the claim/finish/restore protocol;
///    this file is only the `accept` closure, and the closure is the app's normal send path rather
///    than a second way to reach the host: select the bot (`endlessSession`), stage the payload's
///    bytes where the composer stages a picked photo (`addPendingAttachment`), put the text in the
///    draft, and call `send()`. A share is a message typed very fast, not a new transport.
///
/// Nothing here may be called on the Mac: the container, the receiver and the composer's staging
/// area are all iOS surfaces, so the whole file is compiled only for iOS.
@MainActor
enum ShareWiring {

    // MARK: - The picker's list

    /// What was last published, so a roster that arrives unchanged (the unread sweep re-reads it
    /// every 25 s) does not rewrite the file the extension may be reading at that moment.
    private static var publishedSignature: String?

    /// Write the bot list the share sheet offers, from the list this model already holds.
    ///
    /// An empty roster is *not* published: at launch `bots` is empty until the host answers, and
    /// writing that would blank a picker that worked yesterday. A host with genuinely no bots keeps
    /// the last list, whose 7-day staleness rule then tells the person to open the app.
    static func publishBots(from model: AppModel) async {
        // Annotated, not inferred: the store takes labelled tuples and a label-less `map` result is
        // a different type to the compiler.
        let bots: [(id: String, displayName: String)] = model.bots.map { (id: $0.id, displayName: $0.displayName) }
        guard !bots.isEmpty else { return }
        let defaultBotID = model.selectedBotID
        let signature = Self.signature(bots: bots, defaultBotID: defaultBotID)
        guard signature != publishedSignature else { return }

        // The file is the answer: a relaunch has no memory of what it wrote, and an unchanged
        // snapshot on disk must survive it (that is what keeps the timestamp meaningful).
        if let existing = existingSnapshot(),
           Self.matches(existing, bots: bots, defaultBotID: defaultBotID) {
            publishedSignature = signature
            return
        }
        publishedSignature = signature
        let wrote = await Task.detached(priority: .utility) { () -> Bool in
            do {
                try ShareBotSnapshotStore.publish(bots, defaultBotID: defaultBotID)
                return true
            } catch {
                return false
            }
        }.value
        // No container yet (an unpaired phone, or one whose group was not provisioned) — forget the
        // attempt so the next bot-list change tries again rather than trusting a write that failed.
        if !wrote { publishedSignature = nil }
    }

    private static func signature(bots: [(id: String, displayName: String)],
                                  defaultBotID: String?) -> String {
        let roster = bots.map { "\($0.id)\u{1F}\($0.displayName)" }.joined(separator: "\u{1E}")
        return roster + "\u{1D}" + (defaultBotID ?? "")
    }

    /// Whatever is on disk, stale or not. `maximumAge: .infinity` is the point: this is a comparison
    /// with a fresh list, not an offer to the picker.
    private static func existingSnapshot() -> ShareBotSnapshot? {
        if case .ready(let snapshot) = ShareBotSnapshotStore.load(from: .live,
                                                                 maximumAge: TimeInterval.infinity) {
            return snapshot
        }
        return nil
    }

    private static func matches(_ snapshot: ShareBotSnapshot,
                                bots: [(id: String, displayName: String)],
                                defaultBotID: String?) -> Bool {
        guard snapshot.version == ShareBotSnapshotVersion.version,
              snapshot.defaultBotID == defaultBotID,
              snapshot.bots.count == bots.count else { return false }
        // Through `ShareBot` so the comparison uses the name the file would actually hold (an empty
        // display name is written as the id, and comparing the raw empty string would rewrite the
        // same file on every launch).
        for (stored, fresh) in zip(snapshot.bots, bots) {
            guard stored.id == fresh.id,
                  stored.displayName == ShareBot(id: fresh.id,
                                                 displayName: fresh.displayName).displayName else {
                return false
            }
        }
        return true
    }

    // MARK: - Draining

    /// A pass is already running. `ShareInboxReceiver` guards its own pass too (a payload can only
    /// be claimed once), but the delivery below spans several awaits — select, read bytes, send —
    /// and a deep link arriving in the middle of a foreground drain must neither stage the same
    /// share twice nor be dropped because the running pass already listed the inbox a moment
    /// before the extension wrote its file.
    private static var isDraining = false
    /// A caller that arrived during a pass. The pass repeats once it finishes, so a payload written
    /// between "list what is queued" and "the last accept" is picked up by the same trigger that
    /// brought the app forward, not by the next launch.
    private static var drainAgain = false

    /// Deliver everything the extension queued, oldest first. Safe from any caller, any number of
    /// times: the receiver claims by rename, and a refusal is put back for the next pass.
    static func drain(_ model: AppModel) async {
        guard !isDraining else {
            drainAgain = true
            return
        }
        isDraining = true
        defer { isDraining = false }
        repeat {
            drainAgain = false
            await ShareInboxReceiver.shared.drain { payload in
                await deliver(payload, to: model)
            }
        } while drainAgain
    }

    // MARK: - Delivering one payload

    /// Hand one share to its bot. True only when a message actually went out.
    ///
    /// False is not "give up": the receiver renames the payload back into `Inbox/` and the next
    /// pass — the next foreground, the next `hermey://share` — tries again.
    private static func deliver(_ payload: SharePayload, to model: AppModel) async -> Bool {
        // An empty payload is not a message and never reaches this app (the sheet disables Send);
        // accepting it retires a file nobody can act on rather than wedging the queue behind it.
        guard !payload.isEmpty else { return true }
        // The gate is the socket, not `isPaired` alone: a paired phone whose host is asleep would
        // otherwise open a conversation and fail the submit, costing the owner a spinner for nothing.
        guard model.connection.isLive else { return false }
        // The composer is shared state. A send already in flight, or a file the person staged
        // themselves, would travel in our message (or ours in theirs) — wait for the next pass.
        guard !model.sending, model.pendingAttachments.isEmpty else { return false }

        // The bot this share is addressed to has to be the pane's bot, because `send()` speaks for
        // the open conversation. Opening it is also what the owner expects to see: the share lands
        // in the thread it went to, next to the message.
        let session: SessionID?
        if model.selectedBotID == payload.botID, let open = model.selectedSessionID {
            session = open
        } else {
            // [B2 navigation] the sheet's pick *is* the navigation: the person chose this bot when
            // they tapped Send, and the share belongs on screen in that bot's thread.
            session = await model.endlessSession(for: payload.botID, select: true)
        }
        guard let session,
              model.selectedBotID == payload.botID,
              model.selectedSessionID == session else { return false }

        // Bytes before the send: the receiver deletes the descriptor the moment this returns true,
        // and the asset directory is only guaranteed for the queued-and-claimed lifetime.
        var unstaged: [String] = []
        var stagedNames: [String] = []
        var stagedIDs: [UUID] = []
        for attachment in payload.attachments {
            let name = attachment.originalName ?? attachment.fileName
            guard let data = ShareInboxReceiver.shared.data(for: attachment, payloadID: payload.id) else {
                unstaged.append(name)
                continue
            }
            let before = Set(model.pendingAttachments.map(\.id))
            model.addPendingAttachment(name: name, data: data, isImage: attachment.kind == .image)
            let added = model.pendingAttachments.filter { !before.contains($0.id) }
            if added.isEmpty {
                // Refused by the composer's own rules (empty, over 8 MB, or full): named below
                // instead of dropped, which is the difference between "it went" and "it vanished".
                unstaged.append(name)
            } else {
                stagedIDs += added.map(\.id)
                stagedNames.append(name)
            }
        }

        var body = payload.messageText
        if !unstaged.isEmpty {
            let line = "Shared with this message but not attached: " + unstaged.joined(separator: ", ")
            body = body.isEmpty ? line : body + "\n\n" + line
        }
        // Nothing readable and nothing said: there is no message to make. Keep it queued — the
        // files are still on disk, and a transient read failure is not a share to throw away.
        guard !body.isEmpty || !stagedIDs.isEmpty else { return false }

        // The bubble `send()` will append, computed the same way it computes it, so the check below
        // can tell "the host took it" from "the composer swallowed it". Counted, not searched: two
        // identical shares in one queue must not let the second one's failure match the first one's
        // bubble and be reported as delivered.
        let bubble = body.isEmpty ? stagedNames.joined(separator: ", ") : body
        let matchesBefore = model.transcript.filter { $0.role == .user && $0.text == bubble }.count
        let priorDraft = model.draft
        model.draft = body
        await model.send()

        let reached = model.lastSendError == nil
            && model.pendingAttachments.isEmpty
            && model.transcript.filter({ $0.role == .user && $0.text == bubble }).count > matchesBefore

        guard reached else {
            // The attempt failed after staging: our bytes must not ride along with the person's
            // next message, and their draft must come back — the share itself is still in the queue.
            for id in stagedIDs { model.removePendingAttachment(id) }
            if model.selectedBotID == payload.botID { model.draft = priorDraft }
            return false
        }

        // The host has the bytes (the submit that carried their `@file:` references just returned),
        // so the container's copy is only taking up space. Best effort: `prune` is the backstop.
        try? ShareInboxStorage.live.removeAssets(payload.id)
        if model.draft.isEmpty, !priorDraft.isEmpty, model.selectedBotID == payload.botID {
            model.draft = priorDraft
        }
        return true
    }
}
#endif
