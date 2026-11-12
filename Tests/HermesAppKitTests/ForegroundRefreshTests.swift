#if canImport(Combine)
import Foundation
import XCTest
@testable import HermesAppKit
import HermesKit

/// Returning to the app must not blank the chat, and must land at the newest message.
///
/// iOS suspends the socket whenever the app goes to the background, so every foreground sends
/// `gateway.ready` again. The old answer to that was `select(sid)`, which empties `transcript` before
/// it asks the host anything: with a miss in the in-memory cache the pane was blank for the whole
/// host read (measured 4 s on a 2,500-row chat), and because the rows were replaced after a fresh
/// layout pass the scroll view kept its offset — the reader came back to the middle of the thread.
///
/// `refreshTranscript` replaces the rows in place and says so (`transcriptReloads`), which the shell
/// turns into "land at the end".
@MainActor
final class ForegroundRefreshTests: XCTestCase {

    private func line(_ text: String) -> TranscriptEntry {
        TranscriptEntry(id: "entry-\(text)-\(UUID().uuidString)", role: .assistant, text: text)
    }

    private func bot(_ label: String) -> String { "bot-\(label)-\(UUID().uuidString)" }

    private func forget(_ ids: [String]) {
        for id in ids {
            UserDefaults.standard.removeObject(forKey: "hermes.endlessSession.\(id)")
            UserDefaults.standard.removeObject(forKey: "hermes.endlessSessionReset.\(id)")
        }
    }

    /// A host-minted id: anything else makes `EndlessSessionPolicy.storedID` refuse it and the model
    /// silently takes the create-a-draft path, where there is no resume to test.
    private static let sessionID = "20260101_000003_foreground"

    private func opened(_ label: String, entries: [TranscriptEntry]) async -> (AppModel, ScriptedHost) {
        let client = ScriptedHost(session: Self.sessionID, entries: entries)
        client.hostPointer = Self.sessionID
        let model = AppModel(client: client, hostName: "foreground-\(label)-\(UUID().uuidString)")
        await model.start()
        return (model, client)
    }

    func testAForegroundKeepsTheRowsOnScreenWhileTheHostAnswers() async throws {
        let (model, host) = await opened("keep", entries: [line("one"), line("two")])
        let cody = bot("keep")
        defer { forget([cody]) }
        _ = await model.endlessSession(for: cody)
        XCTAssertEqual(model.transcript.count, 2)

        // The host is now holding three rows and takes its time answering: the wait has to be
        // observable, and this is the only way that is deterministic.
        host.entries = [line("one"), line("two"), line("three")]
        host.resumeDelay = .milliseconds(120)
        host.emit(.ready(replayEpoch: "probe"))
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(model.transcript.count, 2,
                       "the transcript that was on screen must survive the refresh — this is the blank pane")
        XCTAssertFalse(model.transcript.isEmpty)
    }

    func testTheHostsCopyReplacesItAndSaysSo() async throws {
        let (model, host) = await opened("replace", entries: [line("one"), line("two")])
        let cody = bot("replace")
        defer { forget([cody]) }
        _ = await model.endlessSession(for: cody)

        host.entries = [line("one"), line("two"), line("three")]
        host.emit(.ready(replayEpoch: "probe"))

        let reloaded = await waitUntil { model.transcriptReloads == 1 }
        XCTAssertTrue(reloaded, "the shell needs a signal to land at the end of the thread")
        XCTAssertEqual(model.transcript.count, 3, "the host is the authority")
        XCTAssertEqual(model.transcript.last?.text, "three")
    }

    func testAReconnectDoesNotClearWhatTheReaderWasLookingAt() async throws {
        let (model, host) = await opened("unwind", entries: [line("keep me")])
        let cody = bot("unwind")
        defer { forget([cody]) }
        _ = await model.endlessSession(for: cody)

        // The resume fails: a blank pane would invent a data loss, so the rows stay.
        host.resumeError = GatewayError.notConnected
        host.emit(.ready(replayEpoch: "probe"))
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(model.transcript.map(\.text), ["keep me"])
        XCTAssertEqual(model.transcriptReloads, 0, "nothing landed, so nothing to re-settle")
    }

    private func waitUntil(timeout: Duration = .seconds(3),
                           _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
#endif
