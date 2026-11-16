#if canImport(Combine)
import Foundation
import XCTest
@testable import HermesAppKit
import HermesKit

/// A reply the list already announced must not be missing from the chat it belongs to.
///
/// Reported 2026-11-16: *"why is it that i get a new msg from u on bot list and notification but it
/// loads on chat much later"*. The two readers disagreed by construction —
///
/// - the **row, the dot and the banner** come from `loadBotPreviews`, which reads every bot's newest
///   message from the host every 25 s (`noteRemoteActivity`), and
/// - the **chat** comes from a resume, which `endlessSession` skipped for up to two minutes after
///   leaving a bot, on the written assumption that "anything said since arrives on the live socket".
///
/// It does not. Every branch of `AppModel.apply(_:)` returns early for a session that is not on
/// screen — correctly, the transcript belongs to one bot — so a reply to another bot was dropped
/// rather than buffered. Opening that bot on the strength of its banner painted the snapshot from
/// before the reply and made no host read at all; the message appeared when something else happened
/// to force a resume (a foreground `.ready`, a reconnect, a send), which is the "much later".
///
/// These tests hold the fix in both directions: the cache yields when the host or the socket says
/// something moved, and it still answers when neither does.
@MainActor
final class StaleConversationTests: XCTestCase {

    private func line(_ text: String, role: TranscriptEntry.Role = .assistant) -> TranscriptEntry {
        TranscriptEntry(id: "entry-\(text)-\(UUID().uuidString)", role: role, text: text)
    }

    /// Bot ids are fresh per test and their endless-session keys are cleared: the pointer lives in
    /// `UserDefaults`, which outlives a test method (see `ConversationCacheTests`).
    private func bot(_ label: String) -> String { "bot-\(label)-\(UUID().uuidString)" }

    private func forget(_ ids: [String]) {
        for id in ids {
            UserDefaults.standard.removeObject(forKey: "hermes.endlessSession.\(id)")
            UserDefaults.standard.removeObject(forKey: "hermes.endlessSessionReset.\(id)")
        }
    }

    /// An open model whose host answers a resume with `entries`.
    ///
    /// `bots` matters: `loadBotPreviews` filters the host's answer to the bots this device knows
    /// about, so a preview for an id the roster has never heard of is dropped and the sweep would
    /// prove nothing.
    private func opened(_ label: String,
                        entries: [TranscriptEntry],
                        bots: [String] = ["assistant"],
                        session: String = "20260101_000002_stale") async -> (AppModel, ScriptedHost) {
        let client = ScriptedHost(session: session, entries: entries)
        client.hostPointer = session
        client.bots = bots.map { Bot(id: $0) }
        let model = AppModel(client: client, hostName: "stale-\(label)-\(UUID().uuidString)")
        await model.start()
        return (model, client)
    }

    /// The host's own timestamp for the message it just wrote: whole seconds since 1970, which is
    /// what the bridge sends and what `AppModel.seconds(_:)` parses.
    private func preview(_ text: String, at stamp: Double = 2_000) -> BotConversationPreview {
        BotConversationPreview(text: text, role: "assistant", timestamp: stamp)
    }

    // MARK: - The reported symptom

    func testAReplyTheListAnnouncedIsInTheChatWhenItIsNextOpened() async {
        let cody = bot("stale-cody"), atlas = bot("stale-atlas")
        defer { forget([cody, atlas]) }
        let (model, client) = await opened("sweep", entries: [line("one")], bots: [cody, atlas])

        await model.endlessSession(for: cody)
        XCTAssertEqual(model.transcript.count, 1, "the conversation opened")
        // Opening a chat marks it read at the device's clock; the host's stamp below is older than
        // now by design (it is the host's own epoch), so the mark has to sit behind it for the dot
        // assertion to mean "a reply arrived", not "1970 came round again".
        model.markRead(cody, at: Date(timeIntervalSince1970: 1_000))

        // Looking at another bot when the reply lands: the socket keeps the *activity* but the
        // transcript branch drops the message, exactly as it does on a real device.
        await model.endlessSession(for: atlas)

        // Meanwhile the host wrote, and the sweep is what notices.
        client.entries = [line("one"), line("the reply")]
        client.previewFeed = BotPreviewFeed(previews: [cody: preview("the reply")], unread: [cody: 1])
        await model.loadBotPreviews(force: true)
        XCTAssertTrue(model.hasUnread(cody), "the list learned about it — that is the banner")

        // Opening that bot inside the two-minute cache window used to paint the reply's absence and
        // ask the host nothing at all.
        await model.endlessSession(for: cody)
        XCTAssertEqual(model.transcript.count, 2,
                       "the row said there was a reply; the chat must open with it")
        XCTAssertEqual(model.transcript.last?.text, "the reply")
        await model.stop()
    }

    func testASessionsOwnEventForcesTheReadEvenWithoutASweep() async {
        // The socket is the faster witness, and it can be the only one: no sweep has run, so
        // `botPreviewTimes` is empty and the host stamp cannot settle anything. What settles it is
        // that a `message.complete` named this session while another one was on screen.
        let codySession = "20260101_000002_cody", atlasSession = "20260101_000003_atlas"
        defer { forget(["cody", "atlas"]) }
        let (model, client) = await opened("socket", entries: [line("one")], bots: ["cody", "atlas"],
                                          session: codySession)
        client.sessionByProfile = ["cody": codySession, "atlas": atlasSession]
        client.hostPointerByProfile = ["cody": codySession, "atlas": atlasSession]

        await model.endlessSession(for: "cody")
        XCTAssertEqual(model.selectedSessionID, codySession)
        await model.endlessSession(for: "atlas")
        XCTAssertEqual(model.selectedSessionID, atlasSession, "another bot is on screen")

        client.entries = [line("one"), line("the reply")]
        client.emit(.messageComplete(session: codySession, text: "the reply"))
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(model.transcript.count, 1, "the event belonged to a bot that is not on screen")
        await model.endlessSession(for: "cody")
        XCTAssertEqual(model.transcript.count, 2,
                       "the session that spoke must be re-read, not served from its snapshot")
        await model.stop()
    }

    // MARK: - The other half: an open chat that nothing re-read

    func testAnOpenChatIsRereadWhenTheHostHasWrittenSince() async {
        // The socket carries a turn in progress and nothing else. Another device's turn, an agent
        // posting outside a run and a bot-to-bot transfer all write on the host with no event here,
        // so an idle open conversation used to stay behind while its row moved on.
        let cody = bot("stale-open")
        defer { forget([cody]) }
        let (model, client) = await opened("open", entries: [line("one")], bots: [cody])

        await model.endlessSession(for: cody)
        XCTAssertEqual(model.transcript.count, 1)

        client.entries = [line("one"), line("written elsewhere")]
        client.previewFeed = BotPreviewFeed(previews: [cody: preview("written elsewhere")], unread: [:])
        await model.loadBotPreviews(force: true)

        XCTAssertEqual(model.transcript.count, 2,
                       "the sweep saw a newer host message, so the open chat re-reads it")
        await model.stop()
    }

    func testTheSameSweepDoesNotReReadTwice() async {
        // The reconcile must settle: once the transcript contains the host's newest message, the next
        // sweep has nothing to do. A storm here would be a resume every 25 s per open conversation.
        let cody = bot("stale-settle")
        defer { forget([cody]) }
        let (model, client) = await opened("settle", entries: [line("one")], bots: [cody])

        await model.endlessSession(for: cody)
        client.previewFeed = BotPreviewFeed(previews: [cody: preview("one")], unread: [:])
        await model.loadBotPreviews(force: true)
        let afterFirst = client.resumed.count

        await model.loadBotPreviews(force: true)
        await model.loadBotPreviews(force: true)
        XCTAssertEqual(client.resumed.count, afterFirst,
                       "an unchanged host stamp must not re-open the conversation again")
        await model.stop()
    }

    func testASnapshotDoesNotClaimWhatItDoesNotContain() async {
        // The trap under the fix: a sweep can land while the conversation is open and be told to stand
        // down (`isStreaming`), leaving the list knowing about a message the transcript does not have.
        // If leaving the bot then recorded *the list's* stamp as the snapshot's, the return visit
        // would look current and serve the snapshot without its reply — the original bug, one layer
        // down. The snapshot records the stamp its own rows were read at.
        let cody = bot("stale-stream-cody"), atlas = bot("stale-stream-atlas")
        defer { forget([cody, atlas]) }
        let (model, client) = await opened("stream", entries: [line("one")], bots: [cody, atlas])

        await model.endlessSession(for: cody)
        let session = model.selectedSessionID
        client.emit(.messageDelta(session: session ?? "", text: "working on it"))
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(model.isStreaming, "a turn is in flight, so the sweep must not re-read")

        client.entries = [line("one"), line("the reply")]
        client.previewFeed = BotPreviewFeed(previews: [cody: preview("the reply")], unread: [cody: 1])
        await model.loadBotPreviews(force: true)
        XCTAssertEqual(model.transcript.count, 1, "the live turn owns the pane while it runs")

        await model.endlessSession(for: atlas)
        await model.endlessSession(for: cody)
        XCTAssertEqual(model.transcript.count, 2,
                       "a snapshot is what it contains, not what the list knew when it was taken")
        await model.stop()
    }

    // MARK: - What must not change

    func testNothingNewStillComesFromTheCache() async {
        // The reason the shortcut exists: returning to a chat you just left must be instant and must
        // not reload what is already on screen. Nothing arrived, so nothing is asked.
        let cody = bot("stale-quiet-cody"), atlas = bot("stale-quiet-atlas")
        defer { forget([cody, atlas]) }
        let (model, client) = await opened("quiet", entries: [line("one"), line("two")],
                                          bots: [cody, atlas])

        await model.endlessSession(for: cody)
        await model.endlessSession(for: atlas)
        let before = client.resumed.count
        await model.endlessSession(for: cody)
        XCTAssertEqual(model.transcript.count, 2, "the snapshot painted")
        XCTAssertEqual(client.resumed.count, before,
                       "inside the window, with nothing new, the cache is the answer")
        await model.stop()
    }
}
#endif
