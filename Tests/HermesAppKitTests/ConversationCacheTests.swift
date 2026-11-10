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

    private func host(_ label: String, entries: [TranscriptEntry] = []) -> ScriptedHost {
        let client = ScriptedHost(session: "s1")
        client.entries = entries
        return client
    }

    func testLeavingABotKeepsWhatWasOnScreen() async {
        let client = host("cache", entries: [line("one"), line("two")])
        let model = AppModel(client: client, hostName: "cache-\(UUID().uuidString)")

        await model.endlessSession(for: "cody")
        XCTAssertEqual(model.transcript.count, 2)

        // Switching away captures the bot being left; nothing about it should be thrown away.
        await model.endlessSession(for: "atlas")
        XCTAssertTrue(model.restoreConversation(for: "cody"),
                      "the conversation just left should come back without asking the host")
        XCTAssertEqual(model.transcript.count, 2)
    }

    func testReturningPaintsBeforeTheHostAnswers() async {
        let client = host("paint", entries: [line("alpha"), line("beta"), line("gamma")])
        let model = AppModel(client: client, hostName: "paint-\(UUID().uuidString)")
        await model.endlessSession(for: "cody")
        await model.endlessSession(for: "atlas")

        // The host is made slow on purpose: the cache is read at the top of `endlessSession`,
        // before its first suspension, so the transcript must already be back while the resume is
        // still in flight. An empty pane at this point is the 1–2 s flash the user reported.
        client.resumeDelay = .milliseconds(500)
        let switching = Task { await model.endlessSession(for: "cody") }
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.transcript.count, 3,
                       "the cached conversation is painted before the host answers")
        _ = await switching.value
        XCTAssertEqual(model.transcript.count, 3)
    }

    func testAResetConversationDoesNotComeBackFromTheCache() async {
        let client = host("reset", entries: [line("kept")])
        let model = AppModel(client: client, hostName: "reset-\(UUID().uuidString)")
        await model.endlessSession(for: "cody")
        XCTAssertEqual(model.transcript.count, 1)

        model.resetEndlessSession(for: "cody")
        XCTAssertTrue(model.transcript.isEmpty)
        XCTAssertFalse(model.restoreConversation(for: "cody"),
                       "a conversation the user reset must not be resurrected by the cache")
    }

    func testOnlyTheMostRecentBotsAreKept() async {
        let client = host("limit", entries: [line("x")])
        let model = AppModel(client: client, hostName: "limit-\(UUID().uuidString)")
        for bot in ["b1", "b2", "b3", "b4", "b5", "b6", "b7", "b8", "b9"] {
            await model.endlessSession(for: bot)
        }
        // Nine bots were visited; the first is gone, the last is here. Bounded, not a leak.
        XCTAssertFalse(model.restoreConversation(for: "b1"))
        XCTAssertTrue(model.restoreConversation(for: "b9"))
    }
}
#endif
