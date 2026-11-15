#if canImport(Combine)
import Foundation
import XCTest
@testable import HermesAppKit
import HermesKit

/// One conversation per bot, shared by both devices — and by the host.
///
/// The authority is the **host's canonical Bot Chat** (`profiles.list` → `canonical_session`, the
/// session titled exactly `Bot Chat`); the bridge's pointer (`GET`/`PUT /v1/bots/{profile}/session`)
/// is a cache and the per-bot `UserDefaults` key is this device's cache. These tests pin the
/// decision order and, just as importantly, that every identity read fails open: a host or bridge
/// that cannot be reached must never cost the user their conversation or put an error on screen.
@MainActor
final class EndlessSessionSyncTests: XCTestCase {

    private func makeBot(_ label: String) -> String {
        "bot-\(label)-\(UUID().uuidString)"
    }

    private func key(_ bot: String) -> String { "hermes.endlessSession.\(bot)" }

    private func cache(_ id: String?, for bot: String) {
        if let id {
            UserDefaults.standard.set(id, forKey: key(bot))
        } else {
            UserDefaults.standard.removeObject(forKey: key(bot))
        }
    }

    // MARK: Host wins

    /// The whole point of the change: a bot whose conversation the host knows opens *that* one, and
    /// both caches are repaired to agree with it.
    func testTheHostsBotChatBeatsTheBridgePointer() async {
        let bot = makeBot("canonical-wins")
        defer { cache(nil, for: bot) }
        cache("20260101_000020_stale", for: bot)
        let host = ScriptedHost(session: "20260101_000021_canonical")
        host.canonicalChat = .canonical("20260101_000021_canonical")
        host.hostPointer = "20260101_000022_pointer"
        let model = AppModel(client: host)

        let opened = await model.endlessSession(for: bot)

        XCTAssertEqual(opened, "20260101_000021_canonical",
                       "Desktop, the TUI, cron and the official app all use the titled session")
        XCTAssertEqual(host.resumed, ["20260101_000021_canonical"])
        XCTAssertEqual(host.published.compactMap(\.id), ["20260101_000021_canonical"],
                       "the pointer is a cache now, so it is repaired to agree with the host")
        XCTAssertEqual(UserDefaults.standard.string(forKey: key(bot)), "20260101_000021_canonical")
        XCTAssertNil(model.lastSendError)
    }

    func testHostPointerBeatsTheLocalCache() async {
        let bot = makeBot("host-wins")
        defer { cache(nil, for: bot) }
        cache("20260101_000001_local", for: bot)
        let host = ScriptedHost(session: "20260101_000002_host")
        host.hostPointer = "20260101_000002_host"
        let model = AppModel(client: host)

        let opened = await model.endlessSession(for: bot)

        XCTAssertEqual(opened, "20260101_000002_host")
        XCTAssertEqual(host.resumed, ["20260101_000002_host"])
        XCTAssertTrue(host.published.isEmpty, "the bridge already knows the id it gave us")
        XCTAssertEqual(UserDefaults.standard.string(forKey: key(bot)), "20260101_000002_host",
                       "the adopted host id replaces the stale cache")
        XCTAssertNil(model.lastSendError)
    }

    func testHostPointerWinsEvenWhenTheLocalCacheIsEmpty() async {
        let bot = makeBot("host-only")
        defer { cache(nil, for: bot) }
        let host = ScriptedHost(session: "20260101_000003_shared")
        host.hostPointer = "20260101_000003_shared"
        let model = AppModel(client: host)

        let opened = await model.endlessSession(for: bot)
        XCTAssertEqual(opened, "20260101_000003_shared")
        XCTAssertEqual(UserDefaults.standard.string(forKey: key(bot)), "20260101_000003_shared")
        XCTAssertTrue(host.published.isEmpty)
    }

    // MARK: Local fallback, then publish

    func testLocalIDIsUsedAndPublishedWhenTheHostHasNone() async {
        let bot = makeBot("local-fallback")
        defer { cache(nil, for: bot) }
        cache("20260101_000004_local", for: bot)
        let host = ScriptedHost(session: "20260101_000004_local")
        host.hostPointer = nil
        let model = AppModel(client: host)

        let opened = await model.endlessSession(for: bot)

        XCTAssertEqual(opened, "20260101_000004_local")
        XCTAssertEqual(host.published.map(\.id), ["20260101_000004_local"],
                       "the other device can only adopt what the bridge holds")
        XCTAssertEqual(host.published.map(\.profile), [bot])
        XCTAssertEqual(host.titled.map(\.title), ["Bot Chat"],
                       "opening it is not enough — it has to be named the canonical chat")
        XCTAssertEqual(host.titled.map(\.id), ["20260101_000004_local"])
        XCTAssertEqual(host.canonicalCreates, 0,
                       "a bot that already has a conversation must not be given a second one")
    }

    func testCreatedConversationIsPublished() async {
        let bot = makeBot("create-publishes")
        defer { cache(nil, for: bot) }
        let host = ScriptedHost(session: "20260101_000005_new")
        host.hostPointer = nil
        let model = AppModel(client: host)

        let opened = await model.endlessSession(for: bot)

        XCTAssertEqual(opened, "20260101_000005_new")
        XCTAssertEqual(UserDefaults.standard.string(forKey: key(bot)), "20260101_000005_new")
        XCTAssertEqual(host.published.map(\.id), ["20260101_000005_new"])
        XCTAssertEqual(host.published.map(\.profile), [bot])
        XCTAssertEqual(host.createKeys, ["bot-chat:\(bot)"],
                       "the deterministic key is what stops two devices forking the new conversation")
    }

    /// A stored id the host has forgotten is replaced — and the replacement is published, so the
    /// other device stops reopening the dead one too.
    func testForgottenSessionIsReplacedAndTheReplacementPublished() async {
        let bot = makeBot("forgotten")
        defer { cache(nil, for: bot) }
        cache("20260101_000006_dead", for: bot)
        let host = ScriptedHost(session: "20260101_000007_alive")
        host.hostPointer = "20260101_000006_dead"
        host.resumeError = GatewayError.rpc(RPCError(code: 4001, message: "session not found"))
        let model = AppModel(client: host)

        let opened = await model.endlessSession(for: bot)

        XCTAssertEqual(opened, "20260101_000007_alive")
        XCTAssertEqual(host.published.map(\.id), ["20260101_000007_alive"])
        XCTAssertEqual(UserDefaults.standard.string(forKey: key(bot)), "20260101_000007_alive")
    }

    // MARK: Malformed / absent host values

    func testUnusableHostValueFallsBackToLocalAndIsRepaired() async {
        let bot = makeBot("malformed")
        defer { cache(nil, for: bot) }
        cache("20260101_000008_local", for: bot)
        let host = ScriptedHost(session: "20260101_000008_local")
        host.hostPointer = "  not a session/id  "
        let model = AppModel(client: host)

        let opened = await model.endlessSession(for: bot)

        XCTAssertEqual(opened, "20260101_000008_local",
                       "a value that is not a stored id must never reach session.resume")
        XCTAssertEqual(host.resumed, ["20260101_000008_local"])
        XCTAssertEqual(host.published.map(\.id), ["20260101_000008_local"])
        XCTAssertNil(model.lastSendError)
    }

    func testEmptyHostValueIsTreatedAsAbsent() async {
        let bot = makeBot("empty")
        defer { cache(nil, for: bot) }
        cache("20260101_000009_local", for: bot)
        let host = ScriptedHost(session: "20260101_000009_local")
        host.hostPointer = "   "
        let model = AppModel(client: host)

        let opened = await model.endlessSession(for: bot)
        XCTAssertEqual(opened, "20260101_000009_local")
        XCTAssertEqual(host.published.map(\.id), ["20260101_000009_local"])
    }

    // MARK: Fail open

    func testUnreachableHostAndBridgeStillOpenTheConversation() async {
        let bot = makeBot("offline")
        defer { cache(nil, for: bot) }
        cache("20260101_000010_local", for: bot)
        let host = ScriptedHost(session: "20260101_000010_local")
        host.hostPointerError = GatewayError.notConnected
        host.canonicalChatError = GatewayError.notConnected
        let model = AppModel(client: host)

        let opened = await model.endlessSession(for: bot)

        XCTAssertEqual(opened, "20260101_000010_local")
        XCTAssertTrue(host.published.isEmpty, "a read we could not trust must not overwrite the pointer")
        XCTAssertNil(model.lastSendError, "the sync leg never surfaces as a conversation error")
    }

    func testUnreachableBridgeWithNoCacheFallsBackToCreate() async {
        let bot = makeBot("offline-create")
        defer { cache(nil, for: bot) }
        let host = ScriptedHost(session: "20260101_000011_new")
        host.hostPointerError = GatewayError.notConnected
        let model = AppModel(client: host)

        let opened = await model.endlessSession(for: bot)
        XCTAssertEqual(opened, "20260101_000011_new")
        XCTAssertNil(model.lastSendError)
    }

    func testFailedPublishDoesNotStopTheConversation() async {
        let bot = makeBot("publish-fails")
        defer { cache(nil, for: bot) }
        let host = ScriptedHost(session: "20260101_000012_new")
        host.publishError = GatewayError.transportClosed("gone")
        let model = AppModel(client: host)

        let opened = await model.endlessSession(for: bot)

        XCTAssertEqual(opened, "20260101_000012_new")
        XCTAssertEqual(UserDefaults.standard.string(forKey: key(bot)), "20260101_000012_new")
        XCTAssertNil(model.lastSendError, "a failed publish only means the other device keeps its id")
    }

    // MARK: Reset

    func testResetClearsTheLocalKeyAndPublishesTheClear() async {
        let bot = makeBot("reset")
        defer {
            cache(nil, for: bot)
            UserDefaults.standard.removeObject(forKey: "hermes.endlessSessionReset.\(bot)")
        }
        cache("20260101_000013_local", for: bot)
        let host = ScriptedHost(session: "20260101_000013_local")
        let model = AppModel(client: host)

        model.resetEndlessSession(for: bot)
        // The publish is deliberately fire-and-forget so a dead bridge cannot block the button.
        for _ in 0..<50 where host.published.isEmpty {
            await Task.yield()
        }

        XCTAssertNil(UserDefaults.standard.string(forKey: key(bot)))
        XCTAssertEqual(host.published.count, 1)
        XCTAssertNil(host.published.first?.id, "clearing the pointer is a nil id, not a missing field")
        XCTAssertEqual(host.published.first?.profile, bot)
    }

    /// The bridge's route cannot clear its row (a null is a 422, "never a delete"), so a reset has
    /// to be protected on the device: otherwise the very next open adopts the old id straight back
    /// and "reset" does nothing.
    func testResetSurvivesTheBridgeStillHoldingTheOldID() async {
        let bot = makeBot("reset-vs-bridge")
        defer {
            cache(nil, for: bot)
            UserDefaults.standard.removeObject(forKey: "hermes.endlessSessionReset.\(bot)")
        }
        cache("20260101_000014_old", for: bot)
        let host = ScriptedHost(session: "20260101_000015_fresh")
        host.hostPointer = "20260101_000014_old"
        let model = AppModel(client: host)

        model.resetEndlessSession(for: bot)
        for _ in 0..<50 where host.published.isEmpty {
            await Task.yield()
        }

        let opened = await model.endlessSession(for: bot)

        XCTAssertEqual(opened, "20260101_000015_fresh", "the conversation the user dropped must not come back")
        XCTAssertEqual(host.published.compactMap(\.id), ["20260101_000015_fresh"])
        XCTAssertNil(UserDefaults.standard.string(forKey: "hermes.endlessSessionReset.\(bot)"),
                     "publishing a replacement retires the tombstone")
    }

    /// Reset must *retire* the Bot Chat, not orphan it: the host keeps calling a row it still holds
    /// the bot's chat, so a reset that only cleared local state would be undone by the next open.
    /// Archiving ends that claim and leaves the history on the host.
    func testResetRetiresTheBotChatOnTheHost() async {
        let bot = makeBot("reset-retires")
        defer {
            cache(nil, for: bot)
            UserDefaults.standard.removeObject(forKey: "hermes.endlessSessionReset.\(bot)")
        }
        cache("20260101_000016_live", for: bot)
        let host = ScriptedHost(session: "20260101_000017_next")
        host.canonicalChat = .canonical("20260101_000016_live")
        let model = AppModel(client: host)

        _ = await model.endlessSession(for: bot)
        await model.resetConversation()

        XCTAssertEqual(host.archived, ["20260101_000016_live"],
                       "archiving is what stops the host treating it as this bot's chat")
    }
}
#endif
