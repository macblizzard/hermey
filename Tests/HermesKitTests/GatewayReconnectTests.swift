import Foundation
import XCTest
@testable import HermesKit

/// A drop is not a disconnect: the socket died under a resumed session, and the client has to come
/// back by itself — re-handshake, re-attach to the *stored* id, restate the open questions and the
/// half-written turn, then replay the deltas it missed.
final class GatewayReconnectTests: XCTestCase {

    private func policy(attempts: Int = 3) -> GatewayClient.ReconnectPolicy {
        .init(enabled: true, maxAttempts: attempts, initialDelay: 0.01, multiplier: 1, maxDelay: 0.01)
    }

    private func makeClient(_ feeder: TransportFeeder, attempts: Int = 3) -> GatewayClient {
        GatewayClient(makeTransport: { try feeder.next() }, timeouts: .testing, reconnect: policy(attempts: attempts))
    }

    func testReconnectRehandshakesAndResumesTheStoredID() async throws {
        let first = FakeGateway()
        let second = FakeGateway()
        let feeder = TransportFeeder([first.bridge(), second.bridge()])
        let client = makeClient(feeder)

        try await client.connect()
        _ = try await client.resumeSession("stored-1")
        XCTAssertEqual(client.state, .open)

        await first.drop("socket died")
        let resumed = await eventually { await second.frames(method: "session.resume").count == 1 }
        XCTAssertTrue(resumed, "the client should have reconnected on its own")

        let methods = await second.methods()
        XCTAssertEqual(methods, ["client.capabilities", "session.resume"],
                       "capabilities are per connection and the resume rebinds the session's transport")
        let params = await second.params(method: "session.resume")
        XCTAssertEqual(params?["session_id"]?.stringValue, "stored-1",
                       "a resume takes the durable id, not the runtime id it answered with")
    }

    func testReconnectRestoresTheQuestionsWithoutDrawingThemTwice() async throws {
        let first = FakeGateway()
        let second = FakeGateway()
        await first.setResult(FakeGateway.resumeResult(storedID: "stored-1",
                                                       assistant: "Hello wor",
                                                       openRequests: [FakeGateway.approvalOpenRequest]),
                              for: "session.resume")
        await second.setResult(FakeGateway.resumeResult(storedID: "stored-1",
                                                        assistant: "Hello world",
                                                        openRequests: [FakeGateway.approvalOpenRequest]),
                               for: "session.resume")
        let feeder = TransportFeeder([first.bridge(), second.bridge()])
        let client = makeClient(feeder)
        let log = EventLog()
        log.start(client.events)

        try await client.connect()
        let firstResume = try await client.resumeSession("stored-1")
        XCTAssertEqual(firstResume.openRequests.map(\.id), [.string("srq-7")])
        XCTAssertTrue(EventDigest.requests(log.all).isEmpty,
                      "a resume the app asked for returns its questions as values, not as duplicate events")

        await first.drop("socket died")
        // `.open` lands as soon as the handshake is done; the snapshot arrives with the resume after
        // it, so wait on the observable the assertion is about.
        let restored = await eventually {
            await client.reconnectSnapshot()?.inflight?.assistantText == "Hello world"
        }
        XCTAssertTrue(restored)

        // The question is still answerable, and the app was not handed a second card for it.
        let pending = await client.pendingServerRequests()
        XCTAssertEqual(pending.map(\.id), [.string("srq-7")])
        // A negative assertion, so give the log a beat to drain before trusting "nothing new".
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(EventDigest.requests(log.all).isEmpty)

        let snapshot = await client.reconnectSnapshot()
        XCTAssertEqual(snapshot?.inflight?.streaming, true)

        // Answering it after the reconnect still uses the id the backend knows.
        try await client.answer(.string("srq-7"), with: .object(["choice": .string("once")]))
        let answers = await second.answers(to: "srq-7")
        XCTAssertEqual(answers.first?["result"]?["choice"]?.stringValue, "once")
    }

    func testReconnectTearsDownAQuestionTheBackendNoLongerWaitsFor() async throws {
        let first = FakeGateway()
        let second = FakeGateway()
        await first.setResult(FakeGateway.resumeResult(storedID: "stored-1",
                                                       openRequests: [FakeGateway.approvalOpenRequest]),
                              for: "session.resume")
        let feeder = TransportFeeder([first.bridge(), second.bridge()])
        let client = makeClient(feeder)
        let log = EventLog()
        log.start(client.events)

        try await client.connect()
        _ = try await client.resumeSession("stored-1")
        let known = await client.pendingServerRequests()
        XCTAssertEqual(known.map(\.id), [.string("srq-7")])

        // The user answered it elsewhere while this client was away: the new snapshot does not list it.
        await first.drop("socket died")
        let cancelled = await log.waitUntil { EventDigest.cancellations($0).contains { $0.id == .string("srq-7") } }
        XCTAssertTrue(cancelled, "a card the agent is no longer blocked on must be torn down")
        XCTAssertEqual(EventDigest.cancellations(log.all).first?.reason, "resolved")

        let pending = await client.pendingServerRequests()
        XCTAssertTrue(pending.isEmpty)
    }

    func testReconnectAfterARestartDeliversTheQuestionsAgain() async throws {
        let first = FakeGateway()
        let second = FakeGateway()
        await second.configure(readyEpoch: "restarted")
        await second.setResult(FakeGateway.resumeResult(storedID: "stored-1", runtimeID: "rt-2",
                                                        openRequests: [FakeGateway.approvalOpenRequest]),
                               for: "session.resume")
        let feeder = TransportFeeder([first.bridge(), second.bridge()])
        let client = makeClient(feeder)
        let log = EventLog()
        log.start(client.events)

        try await client.connect()
        _ = try await client.resumeSession("stored-1")

        await first.drop("socket died")
        let delivered = await log.waitUntil { EventDigest.requests($0).contains { $0.id == .string("srq-7") } }
        XCTAssertTrue(delivered, "a new runtime id starts from an empty set of known questions")
        let snapshot = await client.reconnectSnapshot()
        XCTAssertEqual(snapshot?.id, "rt-2")
    }

    func testMissedDeltasAreReplayedWhenTheEpochMatches() async throws {
        let first = FakeGateway()
        let second = FakeGateway()
        let feeder = TransportFeeder([first.bridge(), second.bridge()])
        let client = makeClient(feeder)
        let log = EventLog()
        log.start(client.events)

        try await client.connect()
        _ = try await client.resumeSession("stored-1")
        await first.emit(event: "message.delta", session: "rt-1", payload: .object(["text": .string("He")]), seq: 3)
        let sawLive = await log.waitUntil { EventDigest.deltas($0) == ["He"] }
        XCTAssertTrue(sawLive)

        await second.setResult(.object([
            "events": .array([
                .object(["type": .string("message.delta"), "session_id": .string("rt-1"),
                         "payload": .object(["text": .string("llo")]), "seq": .int(4)]),
                .object(["type": .string("message.complete"), "session_id": .string("rt-1"),
                         "payload": .object(["text": .string("Hello")]), "seq": .int(5)]),
            ]),
            "latest_seq": .int(5), "truncated": .bool(false), "count": .int(2),
            "epoch": .string("probe"), "open_requests": .array([]),
        ]), for: "session.events.since")

        await first.drop("socket died")
        let replayed = await log.waitUntil { EventDigest.deltas($0) == ["He", "llo"] }
        XCTAssertTrue(replayed, "the delta written during the gap must land after the reconnect")
        XCTAssertEqual(EventDigest.completions(log.all), ["Hello"])

        let params = await second.params(method: "session.events.since")
        XCTAssertEqual(params?["session_id"]?.stringValue, "rt-1")
        XCTAssertEqual(params?["last_seen"]?.intValue, 3)
    }

    func testReplayIsSkippedWhenTheBackendRestarted() async throws {
        let first = FakeGateway()
        let second = FakeGateway()
        await second.configure(readyEpoch: "restarted")
        let feeder = TransportFeeder([first.bridge(), second.bridge()])
        let client = makeClient(feeder)
        let log = EventLog()
        log.start(client.events)

        try await client.connect()
        _ = try await client.resumeSession("stored-1")
        await first.emit(event: "message.delta", session: "rt-1", payload: .object(["text": .string("He")]), seq: 9)
        let sawLive = await log.waitUntil { EventDigest.deltas($0) == ["He"] }
        XCTAssertTrue(sawLive)

        await first.drop("socket died")
        let refetched = await log.waitUntil { EventDigest.updatedSessions($0).contains("rt-1") }
        XCTAssertTrue(refetched, "the app is told to refetch instead")

        let since = await second.frames(method: "session.events.since")
        XCTAssertTrue(since.isEmpty, "a seq from another process means nothing; replay must be refused")
    }

    func testReconnectGivesUpAndReportsFailure() async throws {
        let first = FakeGateway()
        let feeder = TransportFeeder([first.bridge()])  // no second transport: the factory fails
        let client = makeClient(feeder, attempts: 1)
        let log = EventLog()
        log.start(client.events)

        try await client.connect()
        await first.drop("socket died")

        let failed = await log.waitUntil {
            EventDigest.states($0).contains { if case .failed = $0 { return true } else { return false } }
        }
        XCTAssertTrue(failed)
        if case .failed = client.state {
            // expected
        } else {
            XCTFail("expected .failed, got \(client.state)")
        }
    }

    func testCallsMadeDuringAReconnectWaitInsteadOfFailing() async throws {
        let first = FakeGateway()
        let second = FakeGateway()
        // A slow second handshake keeps the client in `.reconnecting` long enough to act inside it,
        // instead of racing a reconnect that finishes in microseconds.
        await second.configure(connectDelay: 0.3)
        let feeder = TransportFeeder([first.bridge(), second.bridge()])
        let client = GatewayClient(makeTransport: { try feeder.next() },
                                   timeouts: .testing,
                                   reconnect: .init(enabled: true, maxAttempts: 3, initialDelay: 0.2, multiplier: 1, maxDelay: 0.2))
        try await client.connect()
        _ = try await client.resumeSession("stored-1")

        await first.drop("socket died")
        let reconnecting = await eventually {
            if case .reconnecting = client.state { return true }
            return false
        }
        XCTAssertTrue(reconnecting)

        // Issued mid-reconnect: it must ride the reconnect, not fail with "not connected".
        let entries = try await client.history("rt-1", limit: 10)
        XCTAssertEqual(entries.count, 3)
        let sent = await second.frames(method: "session.history")
        XCTAssertEqual(sent.count, 1)
    }

    func testCallsAreRejectedWhileDisconnected() async throws {
        let first = FakeGateway()
        let feeder = TransportFeeder([first.bridge()])
        let client = makeClient(feeder, attempts: 1)
        try await client.connect()
        _ = try await client.resumeSession("stored-1")
        await first.drop("socket died")

        let settled = await eventually { client.state != .open }
        XCTAssertTrue(settled)
        do {
            _ = try await client.history("rt-1", limit: 10)
            XCTFail("no transport, no call")
        } catch let error as GatewayError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
