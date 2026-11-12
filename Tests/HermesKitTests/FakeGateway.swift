import Foundation
import XCTest
@testable import HermesKit

/// A bridge with no socket behind it.
///
/// It answers like the gateway: frames are encoded to a line and decoded back through the *real*
/// codec, so a mistake in `JSONRPCCodec` or in the client's envelope handling fails these tests
/// instead of passing through a shortcut.
actor FakeGateway {
    private let continuation: AsyncStream<GatewayTransport.Event>.Continuation
    nonisolated let events: AsyncStream<GatewayTransport.Event>

    private(set) var sent: [JSONValue] = []
    private(set) var connectCount = 0

    private var readyEpoch = "probe"
    private var emitReadyOnConnect = true
    private var connectDelay: TimeInterval = 0
    private var results: [String: JSONValue] = [:]
    private var scopedResults: [String: [String: JSONValue]] = [:]
    private var errors: [String: RPCError] = [:]
    private var silent: Set<String> = []
    private var delays: [String: TimeInterval] = [:]

    init() {
        var captured: AsyncStream<GatewayTransport.Event>.Continuation!
        self.events = AsyncStream { captured = $0 }
        self.continuation = captured
    }

    nonisolated func bridge() -> TransportBridge {
        TransportBridge(
            events: events,
            connect: { [self] in try await connect() },
            send: { [self] text in try await send(text: text) },
            disconnect: { [self] reason in await disconnect(reason: reason) })
    }

    // MARK: Configuration

    func configure(readyEpoch: String? = nil, emitReady: Bool? = nil, connectDelay: TimeInterval? = nil) {
        if let readyEpoch { self.readyEpoch = readyEpoch }
        if let emitReady { self.emitReadyOnConnect = emitReady }
        if let connectDelay { self.connectDelay = connectDelay }
    }

    func setResult(_ result: JSONValue, for method: String) { results[method] = result }

    /// Answer `method` differently depending on one string parameter.
    ///
    /// This is how a test proves the per-bot scoping: `session.list` gets one body for
    /// `profile=chief` and another for `profile=analyst`, so a client that forgets the parameter —
    /// or applies the wrong bot's answer — cannot pass.
    func setResult(_ result: JSONValue, for method: String, whenParam param: String, equals value: String) {
        scopedResults[method, default: [:]][param + "\u{1F}" + value] = result
    }

    private func scopedResult(method: String, params: JSONValue?) -> JSONValue? {
        guard let scoped = scopedResults[method], let params else { return nil }
        for (key, result) in scoped {
            let parts = key.split(separator: "\u{1F}", maxSplits: 1).map(String.init)
            guard parts.count == 2, params[parts[0]]?.stringValue == parts[1] else { continue }
            return result
        }
        return nil
    }

    func setError(_ error: RPCError, for method: String) { errors[method] = error }

    /// Withdraw a scripted failure: a test that proves the client asks again after a refusal has to
    /// be able to make the second call succeed.
    func clearError(for method: String) { errors.removeValue(forKey: method) }

    /// Never answer this method — how a timeout is provoked deterministically.
    func silence(_ method: String) { silent.insert(method) }

    /// Answer `method` only after `seconds` — how a *second* caller is put in the same window as the
    /// first, deterministically. `Task.yield()` proves nothing about how far a task got, so a
    /// coalescing test that does not hold the answer is testing nothing.
    func delay(_ seconds: TimeInterval, for method: String) { delays[method] = seconds }

    // MARK: Transport

    func connect() async throws {
        connectCount += 1
        // A slow handshake is how a test parks the client in `.reconnecting` long enough to act
        // inside that window deterministically.
        if connectDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(connectDelay * 1_000_000_000))
        }
        continuation.yield(.state(.open))
        if emitReadyOnConnect {
            continuation.yield(.frame(.notification(method: "event", params: Self.readyParams(epoch: readyEpoch))))
        }
    }

    func disconnect(reason: String = "client closed") {
        continuation.yield(.state(.closed(reason: reason)))
    }

    func send(text: String) async throws {
        guard let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return }
        sent.append(frame)
        guard let method = frame["method"]?.stringValue, let id = frame["id"] else { return }
        if silent.contains(method) { return }
        if let hold = delays[method] {
            // The frame is already recorded above, so the caller's `frames(method:)` count is the
            // number of round trips actually asked for, whether or not this one has answered yet.
            try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
        }
        if let error = errors[method] {
            respond(to: id, error: error)
            return
        }
        if let scoped = scopedResult(method: method, params: frame["params"]) {
            respond(to: id, result: scoped)
            return
        }
        let result = results[method] ?? Self.defaultResult(method: method,
                                                          params: frame["params"] ?? .null,
                                                          epoch: readyEpoch)
        respond(to: id, result: result)
    }

    // MARK: Gateway → client

    func respond(to id: JSONValue, result: JSONValue? = nil, error: RPCError? = nil) {
        var object: [String: JSONValue] = ["jsonrpc": .string("2.0"), "id": id]
        if let result { object["result"] = result }
        if let error {
            object["error"] = .object(["code": .int(Int64(error.code)), "message": .string(error.message)])
        }
        emit(object: object)
    }

    func emit(line: String) {
        guard let frame = try? JSONRPCCodec.decodeLine(Data(line.utf8)) else { return }
        continuation.yield(.frame(frame))
    }

    func emit(frame: IncomingFrame) { continuation.yield(.frame(frame)) }

    func emit(event type: String, session: String = "", payload: JSONValue = .null, seq: Int? = nil) {
        var params: [String: JSONValue] = ["type": .string(type), "session_id": .string(session)]
        if payload != .null { params["payload"] = payload }
        if let seq { params["seq"] = .int(Int64(seq)) }
        continuation.yield(.frame(.notification(method: "event", params: .object(params))))
    }

    func drop(_ reason: String = "socket died") { continuation.yield(.state(.failed(reason))) }

    func close(_ reason: String = "closed by peer") { continuation.yield(.state(.closed(reason: reason))) }

    func breakFrame(_ text: String = "torn frame") { continuation.yield(.malformed(text)) }

    // MARK: Introspection

    func methods() -> [String] { sent.compactMap { $0["method"]?.stringValue } }

    func frames(method: String) -> [JSONValue] {
        sent.filter { $0["method"]?.stringValue == method }
    }

    func params(method: String) -> JSONValue? { frames(method: method).last?["params"] }

    func id(method: String) -> JSONValue? { frames(method: method).first?["id"] }

    /// Frames the client wrote that are not requests: answers to server→client requests.
    func answers(to id: String) -> [JSONValue] {
        sent.filter { $0["method"] == nil && $0["id"]?.stringValue == id }
    }

    func waitFor(methods expected: [String], timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let seen = Set(methods())
            if Set(expected).isSubset(of: seen) { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return Set(expected).isSubset(of: Set(methods()))
    }

    // MARK: Canned gateway payloads

    private func emit(object: [String: JSONValue]) {
        guard let line = try? JSONRPCCodec.encodeToString(JSONValue.object(object)) else { return }
        guard let frame = try? JSONRPCCodec.decodeLine(Data(line.utf8)) else { return }
        continuation.yield(.frame(frame))
    }

    private static func readyParams(epoch: String) -> JSONValue {
        .object([
            "type": .string("gateway.ready"),
            "session_id": .string(""),
            "payload": .object([
                "skin": .object(["name": .string("default")]),
                "change_events": .bool(true),
                "replay_epoch": .string(epoch),
            ]),
        ])
    }

    /// The recorded `client.capabilities` reply, verbatim from `fixtures/m0-handshake.ndjson`.
    static let capabilitiesResult = Fixtures.capabilitiesResult

    static func resumeResult(storedID: String,
                             runtimeID: String = "rt-1",
                             assistant: String = "Hello wor",
                             streaming: Bool = true,
                             openRequests: [JSONValue] = []) -> JSONValue {
        .object([
            "session_id": .string(runtimeID),
            "stored_session_id": .string(storedID),
            "message_count": .int(3),
            "messages": .array([
                .object(["role": .string("user"), "text": .string("hi"), "row_id": .int(11), "timestamp": .double(1_760_000_000)]),
                .object(["role": .string("assistant"), "text": .string("Hello wor"), "row_id": .int(12)]),
                .object(["role": .string("tool"), "text": .string("ran ls"), "row_id": .int(13), "tool_call_id": .string("c1")]),
            ]),
            "running": .bool(streaming),
            "inflight": .object(["user": .string("hi"), "assistant": .string(assistant), "streaming": .bool(streaming)]),
            "open_requests": .array(openRequests),
            "info": .object(["cwd": .string("/tmp")]),
        ])
    }

    /// One unmatched approval, shaped like `server_requests.open_requests`.
    static let approvalOpenRequest: JSONValue = .object([
        "id": .string("srq-7"),
        "method": .string("approval"),
        "params": .object([
            "session_id": .string("rt-1"),
            "request_id": .string("r1"),
            "command": .string("rm -rf build"),
            "choices": .array([.string("once"), .string("deny")]),
        ]),
    ])

    private static func defaultResult(method: String, params: JSONValue, epoch: String) -> JSONValue {
        switch method {
        case "client.capabilities":
            return capabilitiesResult
        case "profiles.list":
            // Shape measured on the deployed gateway: a `profiles` array, plus fields the client
            // must ignore. Entries name themselves `name`; nothing else is guaranteed.
            return .object([
                "profiles": .array([
                    .object(["name": .string("default"), "is_default": .bool(true)]),
                    .object(["name": .string("assistant")]),
                    .object(["name": .string("chief")]),
                ]),
                "bot_mode_protocol": .int(1),
                "install_id": .string("probe-install"),
            ])
        case "session.list":
            return .object(["sessions": .array([
                .object(["id": .string("stored-1"), "title": .string("First"), "preview": .string("hi"),
                         "started_at": .double(1_760_000_000), "message_count": .int(4), "source": .string("desktop")]),
                .object(["id": .string("stored-2"), "title": .string("Second"), "started_at": .int(1_760_000_100)]),
            ])])
        case "session.resume":
            return resumeResult(storedID: params["session_id"]?.stringValue ?? "")
        case "session.create":
            return .object(["session_id": .string("rt-new"), "stored_session_id": .string("stored-new"),
                            "message_count": .int(0), "messages": .array([])])
        case "session.history":
            return .object(["count": .int(3), "messages": .array([
                .object(["role": .string("user"), "text": .string("one"), "row_id": .int(11)]),
                .object(["role": .string("assistant"), "text": .string("two"), "row_id": .int(12)]),
                .object(["role": .string("user"), "text": .string("three"), "row_id": .int(13)]),
            ])])
        case "prompt.submit":
            return .object(["status": .string("streaming"), "user_row_id": .int(14),
                            "survivor_user_row_ids": .array([.int(11), .null])])
        case "model.options":
            return .object([
                "providers": .array([
                    .object(["slug": .string("anthropic"), "name": .string("Anthropic"),
                             "models": .array([.string("claude-x"), .string("claude-y")]), "is_current": .bool(true)]),
                    .object(["slug": .string("native"), "name": .string("Native"),
                             "models": .array([.string("hermes-1")])]),
                ]),
                "model": .string("claude-x"), "provider": .string("anthropic"),
            ])
        case "session.events.since":
            return .object(["events": .array([]), "latest_seq": .int(0), "truncated": .bool(false),
                            "count": .int(0), "epoch": .string(epoch), "open_requests": .array([])])
        default:
            return .object([:])
        }
    }
}

/// Hands out the scripted transports in order — one `TransportBridge` per connection attempt.
final class TransportFeeder: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [TransportBridge]
    private var opened = 0

    init(_ bridges: [TransportBridge]) { remaining = bridges }

    func next() throws -> TransportBridge {
        lock.lock()
        defer { lock.unlock() }
        guard !remaining.isEmpty else { throw GatewayError.transportClosed("no scripted transports left") }
        opened += 1
        return remaining.removeFirst()
    }

    var used: Int {
        lock.lock()
        defer { lock.unlock() }
        return opened
    }
}

/// Collects `ClientEvent`s off the client's stream.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [ClientEvent] = []
    private var pump: Task<Void, Never>?

    func start(_ stream: AsyncStream<ClientEvent>) {
        pump = Task { [weak self] in
            for await event in stream { self?.append(event) }
        }
    }

    private func append(_ event: ClientEvent) {
        lock.lock()
        buffer.append(event)
        lock.unlock()
    }

    var all: [ClientEvent] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    /// Polls instead of using `XCTestExpectation`: the client delivers from its own task, so
    /// "wait until this shows up" is the only race-free shape. The ceiling is generous because CI
    /// runners run several test bundles at once and can starve a task for a second.
    @discardableResult
    func waitUntil(timeout: TimeInterval = 5, _ predicate: ([ClientEvent]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(all) { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return predicate(all)
    }
}

enum EventDigest {
    static func deltas(_ events: [ClientEvent]) -> [String] {
        events.compactMap { if case .messageDelta(_, let text) = $0 { return text } else { return nil } }
    }

    static func reasoningDeltas(_ events: [ClientEvent]) -> [String] {
        events.compactMap { if case .thinkingDelta(_, let text) = $0 { return text } else { return nil } }
    }

    static func completions(_ events: [ClientEvent]) -> [String] {
        events.compactMap { if case .messageComplete(_, let text) = $0 { return text } else { return nil } }
    }

    static func contextUsages(_ events: [ClientEvent]) -> [(used: Int, max: Int, percent: Double?)] {
        events.compactMap {
            if case .contextUsage(_, let used, let max, let percent) = $0 { return (used, max, percent) }
            return nil
        }
    }

    static func requests(_ events: [ClientEvent]) -> [ServerRequest] {
        events.compactMap { if case .request(let request) = $0 { return request } else { return nil } }
    }

    static func cancellations(_ events: [ClientEvent]) -> [(id: RPCID, reason: String?)] {
        events.compactMap {
            if case .requestCancelled(let id, let reason) = $0 { return (id, reason) } else { return nil }
        }
    }

    static func unknownTypes(_ events: [ClientEvent]) -> [String] {
        events.compactMap { if case .unknown(let type, _) = $0 { return type } else { return nil } }
    }

    static func states(_ events: [ClientEvent]) -> [TransportState] {
        events.compactMap { if case .state(let state) = $0 { return state } else { return nil } }
    }

    static func errors(_ events: [ClientEvent]) -> [(code: Int?, message: String)] {
        events.compactMap { if case .error(let code, let message) = $0 { return (code, message) } else { return nil } }
    }

    static func readyEpochs(_ events: [ClientEvent]) -> [String] {
        events.compactMap { if case .ready(let epoch) = $0 { return epoch } else { return nil } }
    }

    static func updatedSessions(_ events: [ClientEvent]) -> [SessionID] {
        events.compactMap { if case .sessionUpdated(let id) = $0 { return id } else { return nil } }
    }

    static func toolCompletions(_ events: [ClientEvent]) -> [(name: String?, callID: String, output: String?, ok: Bool, durationMS: Int?)] {
        events.compactMap {
            if case .toolComplete(_, let name, let callID, let output, let ok, let duration) = $0 {
                return (name, callID, output, ok, duration)
            }
            return nil
        }
    }

    static func toolStarts(_ events: [ClientEvent]) -> [(name: String, callID: String, input: String)] {
        events.compactMap {
            if case .toolStart(_, let name, let callID, let input) = $0 { return (name, callID, input) }
            return nil
        }
    }
}

/// Polls an async condition — used for "the reconnect finished" style assertions.
func eventually(timeout: TimeInterval = 5, _ condition: @escaping () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

extension GatewayClient.Timeouts {
    /// Fast enough for a unit test, still long enough that a scheduled-but-late reply wins.
    static let testing = GatewayClient.Timeouts(call: 2, sessionList: 2, sessionResume: 2, handshake: 2)
}
