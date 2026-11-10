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
        XCTAssertEqual(model.transcript.count, 3)

        // And the answer still wins: a cache that is behind the host is refreshed, not trusted.
        client.resumeDelay = nil
        client.entries = [line("alpha"), line("beta"), line("gamma"), line("delta")]
        await model.endlessSession(for: atlas)
        await model.endlessSession(for: cody)
        XCTAssertEqual(model.transcript.count, 4, "the host's answer replaces the snapshot")
        await model.stop()
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
        let (model, _) = await opened("limit", entries: [line("x")])
        let bots = (1 ... 9).map { bot("limit-\($0)") }
        defer { forget(bots) }
        for id in bots { await model.endlessSession(for: id) }
        // Nine bots were visited; the first is gone, the last is here. Bounded, not a leak.
        XCTAssertFalse(model.restoreConversation(for: bots[0]))
        XCTAssertTrue(model.restoreConversation(for: bots[8]))
        await model.stop()
    }
}
#endif
