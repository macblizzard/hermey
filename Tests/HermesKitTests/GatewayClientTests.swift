import Foundation
import XCTest
@testable import HermesKit

final class GatewayClientTests: XCTestCase {

    private func makeClient(_ fake: FakeGateway,
                            timeouts: GatewayClient.Timeouts = .testing,
                            reconnect: GatewayClient.ReconnectPolicy = .disabled) -> GatewayClient {
        GatewayClient(makeTransport: { fake.bridge() }, timeouts: timeouts, reconnect: reconnect)
    }

    // MARK: Handshake

    func testHandshakeWaitsForReadyThenAdvertisesCapabilitiesOnce() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        let log = EventLog()
        log.start(client.events)

        try await client.connect()

        XCTAssertEqual(client.state, .open)
        let methods = await fake.methods()
        XCTAssertEqual(methods, ["client.capabilities"], "capabilities go out exactly once, after ready")
        let params = await fake.params(method: "client.capabilities")
        XCTAssertEqual(params?["server_requests"]?.boolValue, true)

        let advertised = await client.advertisedServerRequestMethods()
        XCTAssertEqual(advertised.count, 16)
        XCTAssertTrue(advertised.contains("approval"))
        XCTAssertTrue(advertised.contains("vault.code"))

        let sawReady = await log.waitUntil { EventDigest.readyEpochs($0) == ["probe"] }
        XCTAssertTrue(sawReady)
        // `.open` is published from the actor before `connect()` returns, but the log is filled by
        // its own task: wait for both states rather than sampling the array.
        let sawStates = await log.waitUntil { EventDigest.states($0).count == 2 }
        XCTAssertTrue(sawStates)
        XCTAssertEqual(EventDigest.states(log.all), [.connecting, .open])
    }

    func testConnectFailsWhenReadyNeverArrives() async throws {
        let fake = FakeGateway()
        await fake.configure(emitReady: false)
        let client = makeClient(fake, timeouts: .init(call: 1, sessionList: 1, sessionResume: 1, handshake: 0.2))

        do {
            try await client.connect()
            XCTFail("a socket that never says gateway.ready is not a connection")
        } catch let error as GatewayError {
            XCTAssertEqual(error, .handshakeTimedOut)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testAnOlderBackendWithoutClientCapabilitiesStillConnects() async throws {
        let fake = FakeGateway()
        await fake.silence("client.capabilities")
        // No reply at all is not version skew; it has to fail as a timeout.
        let client = makeClient(fake, timeouts: .init(call: 0.2, sessionList: 1, sessionResume: 1, handshake: 1))
        do {
            try await client.connect()
            XCTFail("an unanswered capabilities call must not be treated as success")
        } catch let error as GatewayError {
            guard case .timeout = error else { return XCTFail("expected a timeout, got \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }

        // An explicit -32601 is skew, and the session stays usable.
        let skew = FakeGateway()
        await skew.setError(RPCError(code: -32601, message: "unknown method: client.capabilities"), for: "client.capabilities")
        let client2 = makeClient(skew)
        try await client2.connect()
        XCTAssertEqual(client2.state, .open)
        let advertised = await client2.advertisedServerRequestMethods()
        XCTAssertTrue(advertised.isEmpty)
    }

    // MARK: Event envelope

    func testDeltasArriveThroughTheEventEnvelope() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        let log = EventLog()
        log.start(client.events)
        try await client.connect()

        await fake.emit(event: "message.delta", session: "rt-1", payload: .object(["text": .string("He")]), seq: 1)
        await fake.emit(event: "message.delta", session: "rt-1", payload: .object(["text": .string("llo")]), seq: 2)
        await fake.emit(event: "message.complete", session: "rt-1", payload: .object(["text": .string("Hello")]))

        let sawAll = await log.waitUntil { EventDigest.deltas($0).count == 2 && EventDigest.completions($0).count == 1 }
        XCTAssertTrue(sawAll)
        XCTAssertEqual(EventDigest.deltas(log.all), ["He", "llo"])
        XCTAssertEqual(EventDigest.completions(log.all), ["Hello"])
    }

    /// A stored session id is only resolvable inside its bot on a multiplexed gateway.
    ///
    /// Measured: `session.resume` with a stored id and no `profile` answers `4007 session not found`
    /// in under a second, while the same call carrying `"profile": "assistant"` succeeds. Omitting it is
    /// what made a freshly created conversation refuse to open.
    func testResumeCarriesTheProfileWhenTheCallerNamesOne() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        try await client.connect()

        _ = try await client.resumeSession("stored-1", profile: "assistant")

        let params = await fake.params(method: "session.resume")
        XCTAssertEqual(params?["session_id"]?.stringValue, "stored-1")
        XCTAssertEqual(params?["profile"]?.stringValue, "assistant")
    }

    /// The reconnect path has no caller to take a profile from, so the client remembers the bot.
    func testReconnectResumeReusesTheBoundProfile() async throws {
        let first = FakeGateway()
        let second = FakeGateway()
        let feeder = TransportFeeder([first.bridge(), second.bridge()])
        let client = GatewayClient(makeTransport: { try feeder.next() },
                                   timeouts: .testing,
                                   reconnect: .init(enabled: true, maxAttempts: 2,
                                                    initialDelay: 0.01, multiplier: 1, maxDelay: 0.01))
        try await client.connect()
        _ = try await client.resumeSession("stored-1", profile: "chief")

        await first.drop("socket died")
        // The reconnect is asynchronous: wait for the resume to actually arrive on the new socket.
        _ = await second.waitFor(methods: ["session.resume"])
        let resumed = await second.params(method: "session.resume")
        XCTAssertEqual(resumed?["profile"]?.stringValue, "chief",
                       "without this the reconnect resume answers 4007 and the conversation dies")
    }

    /// A live turn's events carry **no** session id on the wire — measured: `message.start` is
    /// `{"turn_id"}`, `message.delta` is `{"text","turn_id","segment","offset"}`, `thinking.delta`
    /// is `{"text"}`. One connection is attached to one session, so those events belong to it.
    /// Reading `session_id` alone yielded `""`, the UI filtered every delta out, and the window sat
    /// on "working" while the reply streamed past it.
    func testTurnEventsWithoutSessionIDAreAttributedToTheAttachedSession() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        let log = EventLog()
        log.start(client.events)
        try await client.connect()
        _ = try await client.resumeSession("stored-1")

        await fake.emit(event: "message.delta", session: "", payload: .object(["text": .string("Still")]))

        let saw = await log.waitUntil { EventDigest.deltas($0) == ["Still"] }
        XCTAssertTrue(saw)
        let attributed = log.all.compactMap { event -> String? in
            if case let .messageDelta(session, _) = event { return session }
            return nil
        }
        XCTAssertEqual(attributed, ["stored-1"],
                       "the stored id, which is what the session list and the UI compare against")
    }

    /// The exact bug the fixtures exist to prevent: a bare `method:"message.delta"` notification is
    /// not an event on this backend, and treating it as one hides every real delta behind it.
    func testBareMethodNotificationIsNotADelta() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        let log = EventLog()
        log.start(client.events)
        try await client.connect()

        await fake.emit(frame: .notification(method: "message.delta",
                                             params: .object(["session_id": .string("rt-1"),
                                                              "text": .string("nope")])))

        let sawUnknown = await log.waitUntil { EventDigest.unknownTypes($0) == ["message.delta"] }
        XCTAssertTrue(sawUnknown)
        XCTAssertTrue(EventDigest.deltas(log.all).isEmpty)
    }

    func testNullDeltaIsASegmentBoundaryNotAnEmptyChunk() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        let log = EventLog()
        log.start(client.events)
        try await client.connect()

        await fake.emit(event: "message.delta", session: "rt-1", payload: .object(["text": .null]))
        await fake.emit(event: "message.delta", session: "rt-1", payload: .object(["text": .string("x")]))

        let sawDelta = await log.waitUntil { !EventDigest.deltas($0).isEmpty }
        XCTAssertTrue(sawDelta)
        XCTAssertEqual(EventDigest.deltas(log.all), ["x"])
    }

    func testToolLifecycleIsDecoded() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        let log = EventLog()
        log.start(client.events)
        try await client.connect()

        await fake.emit(event: "tool.start", session: "rt-1",
                        payload: .object(["tool_id": .string("c1"), "name": .string("read_file"),
                                          "args": .object(["path": .string("/tmp/x")])]))
        await fake.emit(event: "tool.complete", session: "rt-1",
                        payload: .object(["tool_id": .string("c1"), "name": .string("read_file"),
                                          "duration_s": .double(0.25),
                                          "result": .object(["success": .bool(false), "error": .string("ENOENT")])]))

        let sawBoth = await log.waitUntil { !EventDigest.toolStarts($0).isEmpty && !EventDigest.toolCompletions($0).isEmpty }
        XCTAssertTrue(sawBoth)
        XCTAssertEqual(EventDigest.toolStarts(log.all).first?.name, "read_file")
        XCTAssertEqual(EventDigest.toolStarts(log.all).first?.callID, "c1")
        let completion = EventDigest.toolCompletions(log.all).first
        XCTAssertEqual(completion?.ok, false, "a tool that reports an error in its result is not ok")
        XCTAssertEqual(completion?.durationMS, 250)
    }

    func testUnknownEventTypeIsSurfacedNotDropped() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        let log = EventLog()
        log.start(client.events)
        try await client.connect()

        await fake.emit(event: "some.future.event", session: "rt-1", payload: .object(["a": .int(1)]))
        let sawUnknown = await log.waitUntil { EventDigest.unknownTypes($0) == ["some.future.event"] }
        XCTAssertTrue(sawUnknown)
    }

    func testTornFrameIsReportedAsParseError() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        let log = EventLog()
        log.start(client.events)
        try await client.connect()

        await fake.breakFrame(#"{"jsonrpc":"2.0","id":"#)
        let reported = await log.waitUntil { !EventDigest.errors($0).isEmpty }
        XCTAssertTrue(reported)
        XCTAssertEqual(EventDigest.errors(log.all).first?.code, -32700)
    }

    // MARK: Calls and correlation

    func testResponsesCorrelateByIDNotByArrivalOrder() async throws {
        let fake = FakeGateway()
        await fake.silence("session.list")
        await fake.silence("model.options")
        let client = makeClient(fake)
        try await client.connect()

        async let sessionsCall = client.listSessions(limit: 3)
        async let modelsCall = client.modelOptions()

        let bothSent = await fake.waitFor(methods: ["session.list", "model.options"])
        XCTAssertTrue(bothSent)
        guard let listID = await fake.id(method: "session.list"),
              let modelsID = await fake.id(method: "model.options") else {
            return XCTFail("requests never reached the wire")
        }

        // Answer the later request first: a client that pops a FIFO hands the caller the wrong body.
        await fake.respond(to: modelsID, result: .object([
            "providers": .array([.object(["slug": .string("solo"), "models": .array([.string("only")])])]),
        ]))
        await fake.respond(to: listID, result: .object([
            "sessions": .array([.object(["id": .string("stored-9"), "title": .string("Nine")])]),
        ]))

        let sessions = try await sessionsCall
        let models = try await modelsCall
        XCTAssertEqual(sessions.map(\.id), ["stored-9"])
        XCTAssertEqual(models.map(\.id), ["only"])
    }

    func testSilentSessionListTimesOutInsteadOfReturningAnEmptyList() async throws {
        let fake = FakeGateway()
        await fake.silence("session.list")
        let client = makeClient(fake, timeouts: .init(call: 0.3, sessionList: 0.3, sessionResume: 0.3, handshake: 1))
        try await client.connect()

        do {
            let sessions = try await client.listSessions(limit: 5)
            XCTFail("absence of a reply is not an empty list: \(sessions)")
        } catch let error as GatewayError {
            guard case .timeout(let method, _) = error else { return XCTFail("expected a timeout, got \(error)") }
            XCTAssertEqual(method, "session.list")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testConnectionLossFailsPendingCallsImmediately() async throws {
        let fake = FakeGateway()
        await fake.silence("session.list")
        let client = makeClient(fake)
        let log = EventLog()
        log.start(client.events)
        try await client.connect()

        let call = Task { try await client.listSessions(limit: 1) }
        let sent = await fake.waitFor(methods: ["session.list"])
        XCTAssertTrue(sent)

        await fake.drop("socket died")
        do {
            _ = try await call.value
            XCTFail("a dropped socket must fail the call instead of leaving it to the timeout")
        } catch let error as GatewayError {
            XCTAssertEqual(error, .transportClosed("socket died"))
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(client.state, .closed(reason: "socket died"))
        let closed = await log.waitUntil { EventDigest.states($0).contains(.closed(reason: "socket died")) }
        XCTAssertTrue(closed)
    }

    func testUnknownMethodErrorSurfacesThroughACall() async throws {
        let fake = FakeGateway()
        await fake.silence("session.list")
        let client = makeClient(fake)
        try await client.connect()

        let call = Task { try await client.listSessions(limit: 1) }
        _ = await fake.waitFor(methods: ["session.list"])
        guard let id = await fake.id(method: "session.list") else { return XCTFail("no frame") }
        await fake.respond(to: id, error: RPCError(code: -32601,
                                                   message: "unknown method: session.list — not available on this Hermes backend"))

        do {
            _ = try await call.value
            XCTFail("expected the backend's error")
        } catch let error as GatewayError {
            XCTAssertEqual(error.rpcError?.code, -32601)
            XCTAssertTrue(error.message.contains("unknown method"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: Server → client requests

    func testApprovalIsRoutedAndAnsweredWithTheSameID() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        let log = EventLog()
        log.start(client.events)
        try await client.connect()

        await fake.emit(frame: .request(RPCRequest(id: .string("srq-7"), method: "approval",
                                                   params: .object([
                                                    "session_id": .string("rt-1"),
                                                    "request_id": .string("r1"),
                                                    "command": .string("rm -rf build"),
                                                    "choices": .array([.string("once"), .string("deny")]),
                                                   ]))))
        let arrived = await log.waitUntil { !EventDigest.requests($0).isEmpty }
        XCTAssertTrue(arrived)
        let request = try XCTUnwrap(EventDigest.requests(log.all).first)
        XCTAssertEqual(request.id, .string("srq-7"))
        XCTAssertEqual(request.method, "approval")
        XCTAssertEqual(request.params["command"]?.stringValue, "rm -rf build")

        let pending = await client.pendingServerRequests()
        XCTAssertEqual(pending.map(\.id), [.string("srq-7")])

        try await client.answer(.string("srq-7"), with: .object(["choice": .string("session")]))
        let answers = await fake.answers(to: "srq-7")
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers.first?["jsonrpc"]?.stringValue, "2.0")
        XCTAssertEqual(answers.first?["result"]?["choice"]?.stringValue, "session")
        XCTAssertNil(answers.first?["error"])

        let cleared = await client.pendingServerRequests()
        XCTAssertTrue(cleared.isEmpty)
    }

    func testDeclineSendsAnErrorFrame() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        try await client.connect()

        try await client.decline(.string("srq-8"), with: RPCError(code: -32601, message: "no handler"))
        let answers = await fake.answers(to: "srq-8")
        XCTAssertEqual(answers.first?["error"]?["code"]?.intValue, -32601)
        XCTAssertNil(answers.first?["result"])
    }

    func testUnimplementedServerRequestIsRefusedWith32601() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        let log = EventLog()
        log.start(client.events)
        try await client.connect()

        await fake.emit(frame: .request(RPCRequest(id: .string("srq-9"), method: "theme.apply", params: .object([:]))))

        let refused = await eventually {
            let answers = await fake.answers(to: "srq-9")
            return answers.contains { $0["error"] != nil }
        }
        XCTAssertTrue(refused)
        let answers = await fake.answers(to: "srq-9")
        XCTAssertEqual(answers.first?["error"]?["code"]?.intValue, -32601)
        let message = answers.first?["error"]?["message"]?.stringValue ?? ""
        XCTAssertTrue(message.contains("theme.apply"))

        let sawUnknown = await log.waitUntil { EventDigest.unknownTypes($0) == ["theme.apply"] }
        XCTAssertTrue(sawUnknown, "the app should be able to log what it could not handle")
        XCTAssertTrue(EventDigest.requests(log.all).isEmpty)
    }

    func testRequestCancelEventClearsTheCard() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        let log = EventLog()
        log.start(client.events)
        try await client.connect()

        await fake.emit(frame: .request(RPCRequest(id: .string("srq-7"), method: "approval", params: .object([:]))))
        let arrived = await log.waitUntil { !EventDigest.requests($0).isEmpty }
        XCTAssertTrue(arrived)

        await fake.emit(event: "request.cancel", session: "rt-1",
                        payload: .object(["id": .string("srq-7"), "method": .string("approval"),
                                          "reason": .string("timeout")]))
        let cancelled = await log.waitUntil { !EventDigest.cancellations($0).isEmpty }
        XCTAssertTrue(cancelled)
        XCTAssertEqual(EventDigest.cancellations(log.all).first?.id, .string("srq-7"))
        XCTAssertEqual(EventDigest.cancellations(log.all).first?.reason, "timeout")

        let pending = await client.pendingServerRequests()
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: Sessions and turns

    func testListSessionsParsesRowsAndSendsTheLimit() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        try await client.connect()

        let sessions = try await client.listSessions(limit: 7)
        XCTAssertEqual(sessions.map(\.id), ["stored-1", "stored-2"])
        XCTAssertEqual(sessions[0].title, "First")
        XCTAssertEqual(sessions[0].preview, "hi")
        XCTAssertEqual(sessions[1].updatedAt, Date(timeIntervalSince1970: 1_760_000_100))
        XCTAssertFalse(sessions[0].running)

        let params = await fake.params(method: "session.list")
        XCTAssertEqual(params?["limit"]?.intValue, 7)
    }

    func testResumeCarriesInflightAndOpenRequests() async throws {
        let fake = FakeGateway()
        await fake.setResult(FakeGateway.resumeResult(storedID: "stored-1",
                                                      assistant: "Hello wor",
                                                      openRequests: [FakeGateway.approvalOpenRequest]),
                             for: "session.resume")
        let client = makeClient(fake)
        try await client.connect()

        let resume = try await client.resumeSession("stored-1")
        XCTAssertEqual(resume.id, "rt-1", "the reply's id is the runtime id every later call needs")
        XCTAssertEqual(resume.entries.count, 3)
        XCTAssertEqual(resume.entries[0].rowID, 11)
        XCTAssertEqual(resume.entries[0].role, .user)
        XCTAssertEqual(resume.entries[2].role, .tool)
        XCTAssertEqual(resume.inflight?.assistantText, "Hello wor")
        XCTAssertEqual(resume.inflight?.streaming, true)
        XCTAssertEqual(resume.openRequests.map(\.id), [.string("srq-7")])
        let answerable = await client.pendingServerRequests()
        XCTAssertEqual(answerable.map(\.id), [.string("srq-7")],
                       "a question handed back by the resume is still answerable")

        let params = await fake.params(method: "session.resume")
        XCTAssertEqual(params?["session_id"]?.stringValue, "stored-1")
    }

    /// A created session is returned by its **stored** id.
    ///
    /// Callers treat the result as a session-list identity and hand it straight to
    /// `session.resume`, which refuses a runtime id with `4007` — so returning the runtime id
    /// (the old behaviour this test used to assert) opened a "new chat" that could not be resumed.
    func testCreateSessionReturnsTheStoredID() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        try await client.connect()

        let id = try await client.createSession(model: "claude-x", provider: "anthropic")
        XCTAssertEqual(id, "stored-new", "callers resume and list by the stored id")
        let params = await fake.params(method: "session.create")
        XCTAssertEqual(params?["model"]?.stringValue, "claude-x")
        XCTAssertEqual(params?["provider"]?.stringValue, "anthropic")
    }

    /// Sending into a resumed session must address it by its **runtime** id.
    ///
    /// Measured against the real gateway: `prompt.submit` with the stored id answers
    /// `4001 session not found` in ~2 ms while the socket is perfectly healthy, which is exactly
    /// the failure the app shipped. The stored id is what the session list shows, so the client has
    /// to translate — this test pins that translation in place.
    func testSubmitAfterResumeAddressesTheRuntimeID() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        try await client.connect()

        _ = try await client.resumeSession("stored-1")
        try await client.submit(session: "stored-1", text: "hi")

        let params = await fake.params(method: "prompt.submit")
        XCTAssertEqual(params?["session_id"]?.stringValue, "rt-1",
                       "the resumed session's runtime id, not the stored id the UI holds")
        XCTAssertEqual(params?["text"]?.stringValue, "hi")
    }

    func testHistoryKeepsTheNewestRows() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        try await client.connect()

        let entries = try await client.history("rt-1", limit: 2)
        XCTAssertEqual(entries.map(\.text), ["two", "three"])
        XCTAssertEqual(entries.map(\.rowID), [12, 13])

        let params = await fake.params(method: "session.history")
        XCTAssertEqual(params?["session_id"]?.stringValue, "rt-1")
    }

    func testSubmitSteerAndInterruptUseTheirOwnMethods() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        try await client.connect()

        try await client.submit(session: "rt-1", text: "hello")
        try await client.steer(session: "rt-1", text: "also this")
        try await client.interrupt(session: "rt-1")

        let submit = await fake.params(method: "prompt.submit")
        XCTAssertEqual(submit?["session_id"]?.stringValue, "rt-1")
        XCTAssertEqual(submit?["text"]?.stringValue, "hello")
        let steer = await fake.params(method: "session.steer")
        XCTAssertEqual(steer?["text"]?.stringValue, "also this")
        let interrupt = await fake.params(method: "session.interrupt")
        XCTAssertEqual(interrupt?["session_id"]?.stringValue, "rt-1")
    }

    func testRewindCutsByRowIDAndNeverWipesSilently() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        try await client.connect()

        try await client.rewind(session: "rt-1", toRowID: 42, then: "try again")

        let params = await fake.params(method: "prompt.submit")
        XCTAssertEqual(params?["session_id"]?.stringValue, "rt-1")
        XCTAssertEqual(params?["text"]?.stringValue, "try again")
        XCTAssertEqual(params?["truncate_before_row_id"]?.intValue, 42)
        XCTAssertEqual(params?["confirm_truncate"]?.boolValue, true)
        XCTAssertEqual(params?["confirm_deep_truncate"]?.boolValue, true)
        XCTAssertNil(params?["confirm_empty_truncate"], "a whole-transcript wipe needs its own confirmation")
        XCTAssertNil(params?["truncate_before_user_ordinal"], "the durable row id is preferred")

        let survivors = await client.survivorRowIDs(for: "rt-1")
        let expected: [Int64?] = [11, nil]
        XCTAssertEqual(survivors, expected)
    }

    func testRewindSurfacesTheEmptyTranscriptGate() async throws {
        let fake = FakeGateway()
        await fake.setError(RPCError(code: 4028, message: "truncation would erase the entire session transcript"),
                            for: "prompt.submit")
        let client = makeClient(fake)
        try await client.connect()

        do {
            try await client.rewind(session: "rt-1", toRowID: 1, then: "x")
            XCTFail("4028 must not be swallowed")
        } catch let error as GatewayError {
            guard case .needsEmptyTranscriptConfirmation = error else {
                return XCTFail("expected the empty-transcript gate, got \(error)")
            }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testModelOptionsFlattenProviders() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        try await client.connect()

        let options = try await client.modelOptions()
        XCTAssertEqual(options.map(\.id), ["claude-x", "claude-y", "hermes-1"])
        XCTAssertEqual(options.map(\.provider), ["anthropic", "anthropic", "native"])
    }

    func testDisconnectClosesTheStreamAndStopsReconnecting() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake, reconnect: .init(enabled: true, maxAttempts: 2, initialDelay: 0.01, multiplier: 1, maxDelay: 0.01))
        let log = EventLog()
        log.start(client.events)
        try await client.connect()
        await client.disconnect()

        XCTAssertEqual(client.state, .closed(reason: "client closed"))
        try await Task.sleep(nanoseconds: 100_000_000)
        let connects = await fake.connectCount
        XCTAssertEqual(connects, 1, "a deliberate disconnect must not be undone by the reconnect policy")

        do {
            _ = try await client.listSessions(limit: 1)
            XCTFail("a disconnected client cannot call")
        } catch let error as GatewayError {
            XCTAssertEqual(error, .notConnected)
        }
    }
}
