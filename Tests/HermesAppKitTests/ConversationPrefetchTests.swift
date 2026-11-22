#if canImport(Combine)
import Foundation
import XCTest
@testable import HermesAppKit
import HermesKit

/// Opening a bot after a cold start must paint, not wait.
///
/// Asked for on 2026-11-16: "when the app is booted, load all bot chats in the background, so that when
/// i go to each bot it doesnt have to load it fresh every single time after bootup".
///
/// The rules this pins: the sweep reads without opening (the transcript on screen is untouched), it
/// never mints a conversation for a bot that has none, it skips a bot that is already warm, it leaves
/// the open bot alone, and what it stores is marked so the *open* still resumes — the snapshot is there
/// to be painted while that round trip runs.
@MainActor
final class ConversationPrefetchTests: XCTestCase {

    private func line(_ text: String) -> TranscriptEntry {
        TranscriptEntry(id: "entry-\(text)-\(UUID().uuidString)", role: .assistant, text: text)
    }

    private func bot(_ label: String) -> String { "prefetch-\(label)-\(UUID().uuidString)" }

    private func forget(_ ids: [String]) {
        for id in ids {
            UserDefaults.standard.removeObject(forKey: "hermes.endlessSession.\(id)")
            UserDefaults.standard.removeObject(forKey: "hermes.endlessSessionReset.\(id)")
        }
    }

    private static let sessionID = "20260101_000003_prefetch"

    private func opened(entries: [TranscriptEntry]) async -> (AppModel, ScriptedHost) {
        let client = ScriptedHost(session: Self.sessionID, entries: entries)
        client.hostPointer = Self.sessionID
        let model = AppModel(client: client, hostName: "prefetch-\(UUID().uuidString)")
        await model.start()
        return (model, client)
    }

    func testItWarmsEveryBotWithoutOpeningAny() async {
        let (model, client) = await opened(entries: [line("one"), line("two")])
        let cody = bot("cody"), atlas = bot("atlas")
        defer { forget([cody, atlas]) }
        // `loadBots()` selects a default bot — that is what the app does — so the roster carries a
        // third id and the assertions are about the two that are *not* on screen.
        client.bots = [Bot(id: bot("selected"), displayName: "Selected"),
                       Bot(id: cody, displayName: "Cody"),
                       Bot(id: atlas, displayName: "Atlas")]
        await model.loadBots()
        let selected = try? XCTUnwrap(model.selectedBotID)
        let onScreen = model.selectedBotID

        await model.prefetchConversations()

        XCTAssertEqual(model.selectedBotID, onScreen, "a sweep must not change which bot is open")
        XCTAssertTrue(model.transcript.isEmpty, "a sweep must not paint anything")

        for id in [cody, atlas] where id != selected {
            XCTAssertTrue(model.restoreConversation(for: id),
                          "\(id) was not warmed, so opening it would start from an empty pane")
            XCTAssertEqual(model.transcript.count, 2)
            XCTAssertEqual(model.selectedSessionID, Self.sessionID)
        }
    }

    func testAWarmBotIsNotResumedAgain() async {
        let (model, client) = await opened(entries: [line("one")])
        let cody = bot("warm")
        defer { forget([cody]) }
        client.bots = [Bot(id: cody), Bot(id: bot("other"))]
        await model.loadBots()

        await model.prefetchConversations()
        let warmsAfterFirst = client.warmed.count
        await model.prefetchConversations()

        XCTAssertEqual(client.warmed.count, warmsAfterFirst,
                       "a second sweep resumed a bot that was warmed seconds ago")
    }

    func testTheOpenBotIsLeftAlone() async {
        let (model, client) = await opened(entries: [line("open")])
        let cody = bot("open"), atlas = bot("aside")
        defer { forget([cody, atlas]) }
        client.bots = [Bot(id: cody), Bot(id: atlas)]
        await model.loadBots()

        await model.endlessSession(for: cody)
        let warmsBefore = client.warmed.count
        await model.prefetchConversations()

        XCTAssertEqual(client.warmed.count, warmsBefore + 1,
                       "exactly one warm: for the bot that is not on screen")
        XCTAssertEqual(model.transcript.map(\.text), ["open"],
                       "the open conversation must not be replaced by the sweep")
    }

    func testABotWithNoConversationIsNotMintedInTheBackground() async {
        // The scripted host has no canonical chat and no pointer for this bot, so the plan is
        // `.create`: the sweep must skip it rather than give the person a conversation they did not
        // ask for.
        let client = ScriptedHost(session: Self.sessionID, entries: [line("x")])
        // No pointer, no canonical chat: nothing to attach a prefetch to.
        client.hostPointer = nil
        let model = AppModel(client: client, hostName: "prefetch-\(UUID().uuidString)")
        await model.start()
        let fresh = bot("fresh")
        defer { forget([fresh]) }
        client.bots = [Bot(id: fresh), Bot(id: bot("other"))]
        await model.loadBots()

        await model.prefetchConversations()

        XCTAssertFalse(model.restoreConversation(for: fresh),
                       "a bot with no conversation must stay cold until it is opened")
    }

    func testItStaysOfflineWhenTheSocketIsDown() async {
        let client = ScriptedHost(session: Self.sessionID, entries: [line("one")])
        let model = AppModel(client: client, hostName: "prefetch-\(UUID().uuidString)")
        let cody = bot("offline")
        defer { forget([cody]) }
        client.bots = [Bot(id: cody), Bot(id: bot("other"))]
        await model.loadBots()
        // No `start()`: the transport was never dialled, so `connection.isLive` is false and the
        // sweep has nothing to read through.
        let warmsBefore = client.warmed.count
        await model.prefetchConversations()
        XCTAssertEqual(client.warmed.count, warmsBefore)
    }

    func testAStaleIdIsReportedAsForgotten() async {
        // The live failure (2026-11-16 22:48, bot `aria`): resume answered 4007 and the model went
        // straight to `.create`. `openStoredConversation` is where that decision is made, so that is
        // what this pins.
        let client = ScriptedHost(session: Self.sessionID, entries: [line("old")])
        client.staleIDs = [Self.sessionID]
        let model = AppModel(client: client, hostName: "prefetch-\(UUID().uuidString)")
        await model.start()

        let outcome = await model.openStoredConversation(Self.sessionID, botID: bot("stale"), publish: false)

        guard case .forgotten = outcome else {
            return XCTFail("a 4007 must be reported as forgotten, got \(outcome)")
        }
        XCTAssertEqual(client.createdSessions.count, 0, "nothing may be minted by opening")
    }

    func testTheRecoveryIsTheBotsBotChat() async {
        // What `.forgotten` adopts: the Bot Chat by name, even when newer sessions outrank it. On this
        // host crony's list starts with two untitled zero-message rows above its 545-message Bot Chat,
        // and adopting the newest opened it blank.
        let client = ScriptedHost(session: Self.sessionID, entries: [])
        client.profileSessions = [SessionSummary(id: "20260101_000009_empty", title: "", messageCount: 0),
                                  SessionSummary(id: "20260101_000008_empty", title: "", messageCount: 0),
                                  SessionSummary(id: "20260101_000007_chat", title: CanonicalBotChat.title,
                                                 messageCount: 545)]
        let model = AppModel(client: client, hostName: "prefetch-\(UUID().uuidString)")
        await model.start()

        let recovered = await model.newestExistingConversation(for: bot("any"))

        XCTAssertEqual(recovered, "20260101_000007_chat",
                       "the Bot Chat outranks newer empty drafts")
    }

    func testWithoutABotChatTheRecoverySkipsEmptyDrafts() async {
        let client = ScriptedHost(session: Self.sessionID, entries: [])
        client.profileSessions = [SessionSummary(id: "20260101_000009_empty", title: "", messageCount: 0),
                                  SessionSummary(id: "20260101_000008_real", title: "Planning",
                                                 messageCount: 12)]
        let model = AppModel(client: client, hostName: "prefetch-\(UUID().uuidString)")
        await model.start()

        let recovered = await model.newestExistingConversation(for: bot("any"))

        XCTAssertEqual(recovered, "20260101_000008_real",
                       "a draft with no messages is not a conversation to recover")
    }

    func testTheHostsBotChatWinsOverARememberedId() async {
        // The host names the endless chat ("Bot Chat", at most one per bot) and reports it as
        // canonical; the host's own client resolves that name on every open instead of remembering an
        // id. This device had a different idea — a runtime id in UserDefaults — and resuming it is how
        // a conversation became "not found".
        let client = ScriptedHost(session: "20260101_000003_stale", entries: [line("from cache")])
        client.hostPointer = "20260101_000003_stale"
        client.profileSessions = [SessionSummary(id: "20260101_000007_other", title: "Something else"),
                                  SessionSummary(id: Self.sessionID, title: CanonicalBotChat.title)]
        let model = AppModel(client: client, hostName: "prefetch-\(UUID().uuidString)")
        await model.start()
        let cody = bot("canonical")
        defer { forget([cody]) }
        UserDefaults.standard.set("20260101_000003_stale", forKey: "hermes.endlessSession.\(cody)")
        client.bots = [Bot(id: cody)]
        await model.loadBots()

        await model.endlessSession(for: cody)

        XCTAssertEqual(client.resumed.last, Self.sessionID,
                       "the id the host calls the Bot Chat is the one that must be resumed")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "hermes.endlessSession.\(cody)"), Self.sessionID,
                       "and it replaces the stale local memory")
    }

    func testAFreshlySweptBotIsNotReadAgainOnOpen() async {
        // "even though all chats now shows the preloaded chat history, it seems to load again once i'm
        // inside the bot chat" — the sweep's snapshot was stamped `.distantPast`, so `latestHostStamp`
        // beat it for every bot and the open resumed anyway. A sweep read seconds ago is the host's
        // current state; opening it must paint and stop.
        let client = ScriptedHost(session: Self.sessionID, entries: [line("warm one"), line("warm two")])
        client.hostPointer = Self.sessionID
        let model = AppModel(client: client, hostName: "prefetch-\(UUID().uuidString)")
        await model.start()
        let selected = bot("selected"), cody = bot("swept")
        defer { forget([selected, cody]) }
        client.bots = [Bot(id: selected), Bot(id: cody)]
        await model.loadBots()

        await model.prefetchConversations()
        let resumesAfterSweep = client.resumed.count

        await model.endlessSession(for: cody)

        XCTAssertEqual(client.resumed.count, resumesAfterSweep,
                       "opening a bot the sweep just read must not resume it again")
        XCTAssertEqual(model.transcript.count, 2, "and its conversation is on screen")
    }

    func testSwitchingBotsDoesNotShowTheOtherBotsChat() async {
        // Reported as "come back to cody and it shows the other bot's chat": the pane restored the
        // target's snapshot *before* the model had switched, so `captureConversation(for:)` filed those
        // rows under the bot being left. The model owns the order now.
        let client = ScriptedHost(session: Self.sessionID, entries: [line("cody's line")])
        client.hostPointer = Self.sessionID
        client.sessionByProfile = [:]
        let model = AppModel(client: client, hostName: "prefetch-\(UUID().uuidString)")
        await model.start()
        let cody = bot("cody"), atlas = bot("atlas")
        defer { forget([cody, atlas]) }
        client.bots = [Bot(id: cody), Bot(id: atlas)]
        await model.loadBots()

        await model.endlessSession(for: cody)
        let codyLines = model.transcript.map(\.text)

        await model.endlessSession(for: atlas)
        await model.endlessSession(for: cody)

        XCTAssertEqual(model.transcript.map(\.text), codyLines,
                       "returning to a bot shows that bot's conversation, never the one just left")
        XCTAssertEqual(model.selectedBotID, cody)
    }

    // MARK: The launch sweep (build 0.1.612)

    /// The failure the owner's log names: `cache prefetch of tinker failed: session not found`, once
    /// per bot, every launch.
    ///
    /// `session.history` resolves only sessions the host is *holding live* — `_sess_nowait` is a plain
    /// `_sessions.get(sid)` — so every bot answer was refused and nothing was ever pre-warmed. The
    /// sweep asks for a **resume** now, scoped to the bot that owns the conversation.
    func testThePrefetchResumesScopedToTheBotAndNeverReadsHistory() async {
        let (model, client) = await opened(entries: [line("one")])
        let cody = bot("scoped")
        let selected = bot("scoped-selected")
        defer { forget([cody]) }
        client.bots = [Bot(id: selected), Bot(id: cody)]
        // Covered by the bridge, so the list's own third-line read does not add a call of its own.
        client.previewFeed = BotPreviewFeed(previews: [
            cody: BotConversationPreview(text: "one", role: "assistant"),
            selected: BotConversationPreview(text: "one", role: "assistant"),
        ])
        await model.loadBots()

        await model.prefetchConversations()

        XCTAssertEqual(client.warmed.map { $0.profile }, [cody],
                       "the sweep resumed a conversation without naming the bot it belongs to")
        XCTAssertEqual(client.warmed.map { $0.id }, [Self.sessionID])
        XCTAssertEqual(client.historyReads, 0,
                       "session.history is for a session the host already holds live; a sweep is not")
        XCTAssertTrue(model.restoreConversation(for: cody), "and the page the resume carried was filed")
    }

    /// A stale id is a signal, not a report: the conversation was re-minted, so this device's id is
    /// dropped and the host is asked which one this bot has now.
    func testAStalePrefetchIDIsResolvedAgainInsteadOfReported() async {
        let client = ScriptedHost(session: Self.sessionID, entries: [line("warm")])
        client.hostPointer = Self.sessionID
        let stale = "20260101_000004_stale"
        let selected = bot("stale-selected")
        client.previewFeed = BotPreviewFeed(previews: [
            selected: BotConversationPreview(text: "x", role: "assistant"),
        ])
        // First identity read: the row this device remembered. Second: the one the host kept.
        client.profileSessionsByCall = [
            [SessionSummary(id: stale, title: CanonicalBotChat.title)],
            [SessionSummary(id: Self.sessionID, title: CanonicalBotChat.title)],
        ]
        client.warmStaleIDs = [stale]
        let model = AppModel(client: client, hostName: "prefetch-\(UUID().uuidString)")
        await model.start()
        let cody = bot("stale")
        defer { forget([cody]) }
        client.bots = [Bot(id: selected), Bot(id: cody)]
        await model.loadBots()

        await model.prefetchConversations()

        XCTAssertEqual(client.warmed.map { $0.id }, [stale, Self.sessionID],
                       "the stale id is asked once, then the conversation the host names now")
        XCTAssertEqual(client.createdSessions.count, 0,
                       "a stale id must never be answered by minting a blank conversation")
        XCTAssertTrue(model.restoreConversation(for: cody))
        XCTAssertEqual(model.transcript.count, 1)
    }

    /// A warm resume registers a **live session** on the host, attached to this connection's
    /// transport — and a session on a live transport is never reaped or LRU-evicted. Nineteen
    /// resumes a launch would pin nineteen idle records, each scheduling an agent build, for as long
    /// as the app is connected. So the sweep releases each one it minted, by the **runtime** id the
    /// resume answered with (a stored id is not a key in the host's registry).
    func testTheSweepReleasesEveryRuntimeSessionItMinted() async {
        let (model, client) = await opened(entries: [line("one")])
        let cody = bot("released"), atlas = bot("also-released")
        defer { forget([cody, atlas]) }
        client.bots = [Bot(id: bot("selected")), Bot(id: cody), Bot(id: atlas)]
        client.previewFeed = BotPreviewFeed(previews: [
            cody: BotConversationPreview(text: "one", role: "assistant"),
            atlas: BotConversationPreview(text: "one", role: "assistant"),
            bot("selected"): BotConversationPreview(text: "one", role: "assistant"),
        ])
        await model.loadBots()

        await model.prefetchConversations()

        XCTAssertEqual(client.liveSessionReads, 1,
                       "the sweep must ask the host what it already holds, once, before warming")
        XCTAssertEqual(client.closedSessions, ["rt-1", "rt-2"],
                       "the runtime ids the resumes answered with are the ones that must be released")
        XCTAssertTrue(client.closedSessions.allSatisfy { $0 != Self.sessionID },
                      "a release is addressed by the runtime id, never the stored one")
        XCTAssertTrue(model.restoreConversation(for: cody), "and the rows are still filed")
        XCTAssertTrue(model.restoreConversation(for: atlas))
    }

    /// The other half of the release rule: a conversation the host was already holding live belongs
    /// to a pane — this device's other window, or another device's — and closing it ends their turn.
    /// Measured on the live host: `session.close` waits 5 s for the turn thread, then tears the agent
    /// down. The sweep must leave those alone.
    func testASessionThatWasAlreadyLiveIsNotClosed() async {
        let (model, client) = await opened(entries: [line("one")])
        let cody = bot("live-elsewhere")
        defer { forget([cody]) }
        client.bots = [Bot(id: bot("selected")), Bot(id: cody)]
        client.previewFeed = BotPreviewFeed(previews: [
            cody: BotConversationPreview(text: "one", role: "assistant"),
            bot("selected"): BotConversationPreview(text: "one", role: "assistant"),
        ])
        // The host is already holding this conversation's runtime session, and says so.
        client.liveSessions = ["rt-already"]
        client.storedByLiveID = ["rt-already": Self.sessionID]
        await model.loadBots()

        await model.prefetchConversations()

        XCTAssertEqual(client.warmed.count, 1, "the bot is still warmed — its transcript is a read")
        XCTAssertEqual(client.closedSessions, [],
                       "the sweep closed a session somebody else was holding")
        XCTAssertTrue(model.restoreConversation(for: cody))
    }
}
#endif
