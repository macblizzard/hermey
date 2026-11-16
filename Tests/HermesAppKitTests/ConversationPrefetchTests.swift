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
        client.bots = [Bot(id: cody, displayName: "Cody"), Bot(id: atlas, displayName: "Atlas")]
        await model.loadBots()

        await model.prefetchConversations()

        // Cold: nothing on screen, nothing selected, and both bots cached.
        XCTAssertNil(model.selectedBotID, "a sweep must not select a bot")
        XCTAssertTrue(model.transcript.isEmpty, "a sweep must not paint anything")

        for id in [cody, atlas] {
            XCTAssertTrue(model.restoreConversation(for: id),
                          "\(id) was not warmed, so opening it would start from an empty pane")
            XCTAssertEqual(model.transcript.count, 2)
            XCTAssertEqual(model.selectedSessionID, Self.sessionID)
        }
    }

    func testAWarmBotIsNotReadAgain() async {
        let (model, client) = await opened(entries: [line("one")])
        let cody = bot("warm")
        defer { forget([cody]) }
        client.bots = [Bot(id: cody), Bot(id: bot("other"))]
        await model.loadBots()

        await model.prefetchConversations()
        let readsAfterFirst = client.historyReads
        await model.prefetchConversations()

        XCTAssertEqual(client.historyReads, readsAfterFirst,
                       "a second sweep re-read a bot that was warmed seconds ago")
    }

    func testTheOpenBotIsLeftAlone() async {
        let (model, client) = await opened(entries: [line("open")])
        let cody = bot("open"), atlas = bot("aside")
        defer { forget([cody, atlas]) }
        client.bots = [Bot(id: cody), Bot(id: atlas)]
        await model.loadBots()

        await model.endlessSession(for: cody)
        let readsBefore = client.historyReads
        await model.prefetchConversations()

        XCTAssertEqual(client.historyReads, readsBefore + 1,
                       "exactly one read: for the bot that is not on screen")
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
        // No `start()`: the transport was never dialled, so there is nothing to read from.
        let readsBefore = client.historyReads
        await model.prefetchConversations()
        XCTAssertEqual(client.historyReads, readsBefore)
    }
}
#endif
