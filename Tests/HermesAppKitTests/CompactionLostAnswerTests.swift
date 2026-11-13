#if canImport(Combine)
import Foundation
import XCTest
@testable import HermesAppKit
import HermesKit

/// A compaction is minutes of **host** work. Losing the phone's socket during one is not a failure.
///
/// Reported from a phone, 2026-11-12: Compact was tapped and the app answered "could not compact — The
/// operation couldn't be completed. Software caused connection abort". The bridge's audit log shows
/// what actually happened: `session.compress` was accepted at 16:19:51.491 and the client closed its
/// socket 186 ms later (`ws_close`, reason `client_closed`, code 1001 — iOS going away as the app left
/// the foreground). An earlier compaction on the same profile was answered `ok` after **123 s**. The
/// host was working; the answer simply had nowhere to land, and the app called that a refusal and
/// printed an errno at him.
///
/// So: a lost answer keeps the compaction state, says the host is still working, and the next
/// transcript the host hands back settles it — success if the conversation changed, an honest "I no
/// longer know" once `compactionPatience` has passed.
@MainActor
final class CompactionLostAnswerTests: XCTestCase {

    private static let sessionID = "20260101_000004_compact"

    private func line(_ text: String) -> TranscriptEntry {
        TranscriptEntry(id: "entry-\(text)-\(UUID().uuidString)", role: .assistant, text: text)
    }

    private func opened(_ label: String, entries: [TranscriptEntry]) async -> (AppModel, ScriptedHost) {
        let host = ScriptedHost(session: Self.sessionID, entries: entries)
        host.hostPointer = Self.sessionID
        let model = AppModel(client: host, hostName: "compact-\(label)-\(UUID().uuidString)")
        await model.start()
        let bot = "bot-\(label)-\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removeObject(forKey: "hermes.endlessSession.\(bot)")
            UserDefaults.standard.removeObject(forKey: "hermes.endlessSessionReset.\(bot)")
        }
        _ = await model.endlessSession(for: bot)
        return (model, host)
    }

    func testAPocketedCompactionIsNotReportedAsARefusal() async {
        let (model, host) = await opened("pocket", entries: [line("one"), line("two")])
        host.compressError = GatewayError.transportClosed(
            "The operation couldn't be completed. Software caused connection abort")

        await model.compressNow()

        XCTAssertNil(model.lastSendError, "the host did not refuse anything")
        XCTAssertTrue(model.isCompressing, "the host is still working; nothing may start a second one")
        XCTAssertEqual(model.compactionNotice, "compacting… the host keeps working while the app is away")
    }

    func testARefusalIsStillARefusal() async {
        let (model, host) = await opened("refuse", entries: [line("one")])
        host.compressError = GatewayError.rpc(RPCError(code: 4001, message: "session not found"))

        await model.compressNow()

        XCTAssertEqual(model.compactionNotice, "could not compact — session not found")
        XCTAssertFalse(model.isCompressing)
        XCTAssertNotNil(model.lastSendError)
    }

    func testTheNextTranscriptSettlesItAsCompacted() async {
        let (model, host) = await opened("settle", entries: [line("one"), line("two"), line("three")])
        host.compressError = GatewayError.notConnected
        await model.compressNow()
        XCTAssertTrue(model.isCompressing)

        // The host finished while the phone was asleep: its copy is now the compacted one.
        host.compressError = nil
        host.entries = [line("summary of the thread")]
        host.emit(.ready(replayEpoch: "probe"))

        let settled = await waitUntil { !model.isCompressing }
        XCTAssertTrue(settled, "a reconnect must settle the compaction it outlived")
        XCTAssertEqual(model.compactionNotice, "conversation compacted")
        XCTAssertEqual(model.transcript.map(\.text), ["summary of the thread"])
        XCTAssertNil(model.lastSendError)
    }

    func testAnUnchangedTranscriptDoesNotClaimSuccess() async {
        let (model, host) = await opened("waiting", entries: [line("one")])
        host.compressError = GatewayError.notConnected
        await model.compressNow()

        host.compressError = nil
        host.emit(.ready(replayEpoch: "probe"))
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertTrue(model.isCompressing, "nothing changed, so the host may still be working")
        XCTAssertEqual(model.compactionNotice, "compacting… the host keeps working while the app is away")
    }

    func testPatienceIsLongerThanTheSlowestMeasuredCompaction() {
        // Measured on this host: 74 s, 123 s, 163 s. A shorter patience would lie about real work.
        XCTAssertGreaterThan(AppModel.compactionPatience, 163)
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
