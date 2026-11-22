#if canImport(Combine)
import Foundation
import XCTest
@testable import HermesAppKit
import HermesKit

/// Switching bots must not start from an empty pane.
///
/// The rules: leaving a bot keeps a snapshot of what was on screen, returning paints that snapshot
/// **before** the host is asked anything, the resume still runs and replaces it, a reset conversation
/// does not come back, and an unknown bot says "opening" instead of "start the conversation".
@MainActor
final class ConversationCacheTests: XCTestCase {

    private func line(_ text: String, role: TranscriptEntry.Role = .assistant) -> TranscriptEntry {
        TranscriptEntry(id: "entry-\(text)-\(UUID().uuidString)", role: role, text: text)
    }

    /// An open model whose host answers a resume with `entries`.
    ///
    /// `start()` matters: without a live transport the shared-session pointer is never asked, the
    /// model takes the create-a-draft path, and a draft is empty by definition — while the bug under
    /// test lives on the resume path.
    /// Fresh bot ids per test.
    ///
    /// The endless-session keys live in `UserDefaults`, which outlives a test method: `reset` writes
    /// a "this device forgot it" mark under the bot id, and a later test reusing the same id then
    /// refuses the host's pointer and opens a draft instead — the failure looks like a cache bug but
    /// is test pollution.
    private func bot(_ label: String) -> String { "bot-\(label)-\(UUID().uuidString)" }

    private func forget(_ ids: [String]) {
        for id in ids {
            UserDefaults.standard.removeObject(forKey: "hermes.endlessSession.\(id)")
            UserDefaults.standard.removeObject(forKey: "hermes.endlessSessionReset.\(id)")
        }
    }

    /// A session id shaped the way the host mints them — `EndlessSessionPolicy.storedID` refuses
    /// anything else, and a refused id silently drops the test onto the create-a-draft path.
    private static let sessionID = "20260101_000002_cache"

    private func opened(_ label: String,
                        entries: [TranscriptEntry]) async -> (AppModel, ScriptedHost) {
        let client = ScriptedHost(session: Self.sessionID, entries: entries)
        client.hostPointer = Self.sessionID
        let model = AppModel(client: client, hostName: "cache-\(label)-\(UUID().uuidString)")
        await model.start()
        return (model, client)
    }

    func testLeavingABotKeepsWhatWasOnScreen() async {
        let (model, _) = await opened("keep", entries: [line("one"), line("two")])
        let cody = bot("keep-cody"), atlas = bot("keep-atlas")
        defer { forget([cody, atlas]) }

        await model.endlessSession(for: cody)
        XCTAssertEqual(model.transcript.count, 2, "the conversation opened")

        // Switching away captures the bot being left; nothing about it should be thrown away.
        await model.endlessSession(for: atlas)
        XCTAssertTrue(model.restoreConversation(for: cody),
                      "the conversation just left should come back without asking the host")
        XCTAssertEqual(model.transcript.count, 2)
        await model.stop()
    }

    func testReturningPaintsBeforeTheHostAnswers() async {
        let (model, client) = await opened("paint", entries: [line("alpha"), line("beta"), line("gamma")])
        let cody = bot("paint-cody"), atlas = bot("paint-atlas")
        defer { forget([cody, atlas]) }
        await model.endlessSession(for: cody)
        await model.endlessSession(for: atlas)

        // The host is made slow on purpose: the cache is read at the top of `endlessSession`,
        // before its first suspension, so the transcript must already be back while the resume is
        // still in flight. An empty pane at this point is the 1–2 s flash that was reported.
        client.resumeDelay = .milliseconds(500)
        let switching = Task { await model.endlessSession(for: cody) }
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.transcript.count, 3,
                       "the cached conversation is painted before the host answers")
        _ = await switching.value
        XCTAssertEqual(model.transcript.count, 3,
                       "the host's page merges into the painted rows instead of replacing them")

        // Past the window the host is asked again, and its answer replaces the snapshot.
        model.conversationCacheFreshness = 0
        client.resumeDelay = nil
        client.entries = [line("alpha"), line("beta"), line("gamma"), line("delta")]
        await model.endlessSession(for: atlas)
        await model.endlessSession(for: cody)
        XCTAssertEqual(model.transcript.count, 4, "a stale cache is refreshed, not trusted")
        await model.stop()
    }

    /// A relaunch must paint from the disk cache, not wait for the host.
    ///
    /// The failure this covers: with the socket live — the normal state at launch — both open paths
    /// consulted the disk cache only *after* a resume failed, so an enabled Messages cache bought
    /// nothing and every chat was still loaded the slow way, once per chat, every launch.
    func testAColdLaunchPaintsTheDiskCacheBeforeTheHostAnswers() async {
        let host = "cold-\(UUID().uuidString)"
        // One id for both launches: the endless-session pointer is stored under the bot id, and a
        // second random id would open a draft instead of the conversation the cache holds.
        let cody = bot("cold")
        defer { forget([cody]) }

        let firstClient = ScriptedHost(session: Self.sessionID, entries: [line("one"), line("two")])
        firstClient.hostPointer = Self.sessionID
        let first = AppModel(client: firstClient, hostName: host)
        await first.start()
        await first.endlessSession(for: cody)
        XCTAssertEqual(first.transcript.count, 2, "the first launch opened the conversation")
        // The transcript is written after the fact, so give the cache actor its turn.
        try? await Task.sleep(for: .milliseconds(600))
        await first.stop()

        // A second model on the same host name is what a relaunch looks like to the cache: same
        // directory, same stored session id, empty in-memory snapshots.
        let secondClient = ScriptedHost(session: Self.sessionID, entries: [line("one"), line("two")])
        secondClient.hostPointer = Self.sessionID
        secondClient.resumeDelay = .milliseconds(500)
        let second = AppModel(client: secondClient, hostName: host)
        await second.start()

        let opening = Task { await second.endlessSession(for: cody) }
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(second.transcript.count, 2,
                       "a cold launch paints the cached conversation while the resume is in flight")
        _ = await opening.value
        await second.stop()
    }

    func testAResetConversationDoesNotComeBackFromTheCache() async {
        let (model, _) = await opened("reset", entries: [line("kept")])
        let cody = bot("reset-cody")
        defer { forget([cody]) }
        await model.endlessSession(for: cody)
        XCTAssertEqual(model.transcript.count, 1)

        model.resetEndlessSession(for: cody)
        XCTAssertTrue(model.transcript.isEmpty)
        XCTAssertFalse(model.restoreConversation(for: cody),
                       "a conversation the user reset must not be resurrected by the cache")
        await model.stop()
    }

    func testOnlyTheMostRecentBotsAreKept() async {
        // Bounded, not a leak — and bounded by the cache's OWN limit, not by a number copied into the
        // test. The hardcoded nine stopped failing to evict the day the limit went from 8 to 24, which
        // is exactly the kind of pin that reports a false regression.
        let (model, _) = await opened("limit", entries: [line("x")])
        let overshoot = AppModel.conversationCacheLimitForTesting + 1
        let bots = (1 ... overshoot).map { bot("limit-\($0)") }
        defer { forget(bots) }
        for id in bots { await model.endlessSession(for: id) }
        XCTAssertFalse(model.restoreConversation(for: bots[0]),
                       "the oldest was visited \(overshoot) bots ago and must be evicted")
        XCTAssertTrue(model.restoreConversation(for: bots[overshoot - 1]))
        await model.stop()
    }

    // MARK: A cached thread is only current when the host says so

    /// Build 0.1.612: "a message arrives but the thread does not show it until you switch away and
    /// back".
    ///
    /// The host's newest-message stamp had not reached this device yet (the previews sweep had not
    /// run), so `botPreviewTimes` was nil; the cache shortcut read that as "nothing new" and skipped
    /// the resume. An unknown stamp is not proof of quiet — the return visit must read the host, and
    /// it must still paint first so the pane is never blank.
    func testReturningResumesWhenTheHostsNewestMessageIsUnknown() async {
        let (model, client) = await opened("unknown", entries: [line("old reply")])
        let cody = bot("unknown-cody"), atlas = bot("unknown-atlas")
        defer { forget([cody, atlas]) }
        await model.endlessSession(for: cody)
        await model.endlessSession(for: atlas)

        // The reply landed on the host while the owner was looking at atlas, and no previews sweep
        // has reported it yet.
        client.entries = [line("old reply"), line("reply nobody saw")]
        let resumesBefore = client.resumed.count

        await model.endlessSession(for: cody)

        XCTAssertEqual(client.resumed.count, resumesBefore + 1,
                       "a cache with no known host stamp cannot stand in for a host read")
        XCTAssertEqual(model.transcript.map(\.text), ["old reply", "reply nobody saw"],
                       "the reply is on screen without switching away and back")
    }

    /// The same fact arriving by the other door: the sweep reported a newer host message (which is
    /// what lights the row's badge), and the return visit must act on it.
    func testReturningResumesWhenTheHostReportedANewerMessage() async {
        let (model, client) = await opened("newer", entries: [line("old reply")])
        let cody = bot("newer-cody"), atlas = bot("newer-atlas")
        defer { forget([cody, atlas]) }
        let seen = Date(timeIntervalSince1970: 1_700_000_000)
        client.bots = [Bot(id: cody), Bot(id: atlas)]
        client.previewFeed = BotPreviewFeed(previews: [
            cody: BotConversationPreview(text: "old reply", role: "assistant",
                                         timestamp: seen.timeIntervalSince1970),
            atlas: BotConversationPreview(text: "old reply", role: "assistant",
                                          timestamp: seen.timeIntervalSince1970),
        ])
        await model.loadBots()

        await model.endlessSession(for: cody)
        await model.endlessSession(for: atlas)

        // A reply lands on cody: the host's own stamp moves, and the sweep says so.
        client.entries = [line("old reply"), line("reply nobody saw")]
        client.previewFeed = BotPreviewFeed(previews: [
            cody: BotConversationPreview(text: "reply nobody saw", role: "assistant",
                                         timestamp: seen.addingTimeInterval(60).timeIntervalSince1970),
        ])
        await model.loadBotPreviews(force: true)
        let resumesBefore = client.resumed.count

        await model.endlessSession(for: cody)

        XCTAssertEqual(client.resumed.count, resumesBefore + 1,
                       "the host has a message the snapshot does not contain")
        XCTAssertEqual(model.transcript.map(\.text), ["old reply", "reply nobody saw"])
    }

    /// The unread door: the badge is up, so something arrived after the snapshot — even when the
    /// host's stamp this device last heard is the one the snapshot holds.
    func testReturningResumesWhenTheBotHasUnreadActivity() async {
        let (model, client) = await opened("unread", entries: [line("old reply")])
        let cody = bot("unread-cody"), atlas = bot("unread-atlas")
        defer { forget([cody, atlas]) }
        let seen = Date(timeIntervalSince1970: 1_700_000_000)
        client.bots = [Bot(id: cody), Bot(id: atlas)]
        client.previewFeed = BotPreviewFeed(previews: [
            cody: BotConversationPreview(text: "old reply", role: "assistant",
                                         timestamp: seen.timeIntervalSince1970),
            atlas: BotConversationPreview(text: "old reply", role: "assistant",
                                          timestamp: seen.timeIntervalSince1970),
        ])
        await model.loadBots()

        await model.endlessSession(for: cody)
        await model.endlessSession(for: atlas)
        await model.loadBotPreviews(force: true)
        // The badge is what the person acts on; the thread must agree with it.
        client.entries = [line("old reply"), line("reply nobody saw")]
        model.markUnread(cody)
        let resumesBefore = client.resumed.count

        await model.endlessSession(for: cody)

        XCTAssertEqual(client.resumed.count, resumesBefore + 1,
                       "an unread bot cannot open onto a thread that does not contain the unread")
        XCTAssertEqual(model.transcript.map(\.text), ["old reply", "reply nobody saw"])
    }

    /// And the other half of the rule: when the host's own stamp says the snapshot already contains
    /// its newest message, the cache answers and the thread is not reloaded.
    ///
    /// The confirmation may land *after* the snapshot was captured (this is the common order: open
    /// the bot, leave it, the sweep then reports the message that was already on screen). A capture
    /// cannot record a host stamp, so the stamp alone reads as "the host has written since" — the
    /// list's third line names the message, and the snapshot's last row is that message, which is
    /// what makes the visit quiet (`AppModel.holdsNewestLine`).
    func testACacheTheHostConfirmsIsCurrentIsNotReloaded() async {
        let (model, client) = await opened("quiet", entries: [line("only reply")])
        let cody = bot("quiet-cody"), atlas = bot("quiet-atlas")
        defer { forget([cody, atlas]) }
        let seen = Date(timeIntervalSince1970: 1_700_000_000)
        client.bots = [Bot(id: cody), Bot(id: atlas)]
        client.previewFeed = BotPreviewFeed(previews: [
            cody: BotConversationPreview(text: "only reply", role: "assistant",
                                         timestamp: seen.timeIntervalSince1970),
            atlas: BotConversationPreview(text: "only reply", role: "assistant",
                                          timestamp: seen.timeIntervalSince1970),
        ])
        await model.loadBots()

        await model.endlessSession(for: cody)
        await model.endlessSession(for: atlas)
        await model.loadBotPreviews(force: true)
        let resumesBefore = client.resumed.count

        await model.endlessSession(for: cody)

        XCTAssertEqual(client.resumed.count, resumesBefore,
                       "the host's newest message is the one the snapshot holds: no reload")
        XCTAssertEqual(model.transcript.map(\.text), ["only reply"])
    }
}
#endif
