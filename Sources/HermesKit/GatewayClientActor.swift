import Foundation

/// Everything the protocol core can fail with.
///
/// Deliberately typed instead of `NSError`-ish: the UI has to distinguish "the backend answered no"
/// (show the message) from "we never heard back" (offer retry) from "the socket died" (reconnect),
/// and a rewind that the gateway refused on purpose must be able to ask for confirmation.
public enum GatewayError: Error, Sendable, Equatable, LocalizedError {
    /// No connection: the socket is down and a reconnect has not finished yet.
    case notConnected
    /// The first frame (`gateway.ready`) never arrived.
    case handshakeTimedOut
    /// A call got no response frame in time. Never reported as an empty result — a silent
    /// `session.list` on a cold profile is a timeout, not "you have no sessions"
    /// (`fixtures/NOTES.md` §4).
    case timeout(method: String, seconds: TimeInterval)
    case transportClosed(String)
    /// A JSON-RPC error frame from the backend (`-32601`, `4009`, `4028`, …).
    case rpc(RPCError)
    /// The frame was not shaped like the contractual result for that method.
    case malformedResponse(method: String)
    /// `prompt.submit` refused the cut: it would erase the whole transcript (`4028`).
    case needsEmptyTranscriptConfirmation(String)
    /// `prompt.submit` refused the cut: it would archive later user turns (`4033`).
    case needsDeepCutConfirmation(String)
    case cancelled

    /// The backend's own error, when there was one — for matching Hermes' 4009/4029 family.
    public var rpcError: RPCError? {
        if case .rpc(let error) = self { return error }
        return nil
    }

    public var message: String {
        switch self {
        case .notConnected: return "not connected"
        case .handshakeTimedOut: return "the gateway did not send gateway.ready"
        case .timeout(let method, let seconds): return "\(method) timed out after \(Int(seconds))s"
        case .transportClosed(let reason): return reason
        case .rpc(let error): return error.message
        case .malformedResponse(let method): return "\(method) returned an unexpected result"
        case .needsEmptyTranscriptConfirmation(let message): return message
        case .needsDeepCutConfirmation(let message): return message
        case .cancelled: return "cancelled"
        }
    }

    /// Without this conformance every failure surfaced to the user as the NSError bridge text
    /// — `The operation couldn't be completed. (HermesKit.GatewayError error 2.)` — which says
    /// nothing about what the gateway actually answered. `message` already carries the backend's
    /// own wording, so the UI shows that instead.
    public var errorDescription: String? { message }
}

/// The production client.
///
/// One actor owns one connection at a time. It correlates JSON-RPC ids, bounds every call with a
/// timeout, performs the mandatory `gateway.ready` → `client.capabilities` handshake, unwraps the
/// `method:"event"` envelope, routes server→client requests (or refuses them with `-32601` so the
/// agent fails in one round trip), and re-attaches after a drop so no approval card or half-written
/// turn is lost.
public actor GatewayClient: GatewayClientProtocol {

    // MARK: - Tuning

    public struct Timeouts: Sendable, Equatable {
        /// Every ordinary call. `session.list` and `session.resume` can be slow on a cold profile,
        /// which is why they are separate — 60 s of silence from `session.list` was observed on a
        /// real gateway, so the ceiling has to be generous but finite.
        public var call: TimeInterval
        public var sessionList: TimeInterval
        public var sessionResume: TimeInterval
        public var handshake: TimeInterval
        /// `session.compress` is a real model turn on the host (write a summary of the session), so
        /// it is bounded like a resume rather than like a bookkeeping call.
        public var compress: TimeInterval

        public init(call: TimeInterval = 30,
                    sessionList: TimeInterval = 120,
                    sessionResume: TimeInterval = 120,
                    handshake: TimeInterval = 20,
                    compress: TimeInterval = 120) {
            self.call = call
            self.sessionList = sessionList
            self.sessionResume = sessionResume
            self.handshake = handshake
            self.compress = compress
        }
    }

    public struct ReconnectPolicy: Sendable, Equatable {
        public var enabled: Bool
        public var maxAttempts: Int
        public var initialDelay: TimeInterval
        public var multiplier: Double
        public var maxDelay: TimeInterval

        public init(enabled: Bool = true,
                    maxAttempts: Int = 5,
                    initialDelay: TimeInterval = 0.5,
                    multiplier: Double = 2,
                    maxDelay: TimeInterval = 30) {
            self.enabled = enabled
            self.maxAttempts = maxAttempts
            self.initialDelay = initialDelay
            self.multiplier = multiplier
            self.maxDelay = maxDelay
        }

        public static let disabled = ReconnectPolicy(enabled: false, maxAttempts: 0)
    }

    /// Builds a *fresh* transport per connection. A bridge carries one `AsyncStream`; reusing it
    /// after a drop delivers nothing, so reconnects must mint a new one (new socket, new URL
    /// ticket in the real app).
    public typealias TransportFactory = @Sendable () async throws -> TransportBridge

    /// Server→client request methods this client can surface to the UI. Everything else is answered
    /// `-32601` immediately — the backend's `server_requests.send` treats an error response as "the
    /// renderer cannot do this" and the tool fails fast instead of waiting out clarify's 300 s.
    public static let answerableServerRequests: Set<String> = [
        "approval", "clarify", "sudo", "secret", "vault.code", "terminal.read",
    ]

    // MARK: - Identity of a connection

    private struct PendingCall {
        let method: String
        let signal: OneShotSignal<JSONValue?>
    }

    /// Where a session's replay watermark came from. A `seq` is only comparable inside one server
    /// process, so the epoch travels with it — comparing a stale watermark against a restarted
    /// backend silently returns nothing (`event_replay.py`).
    private struct Watermark {
        let seq: Int
        let epoch: String?
    }

    private let makeTransport: TransportFactory
    /// The bridge-owned answer to "which stored session is this bot's conversation". `nil` for a
    /// client with no bridge credentials; every read then answers `nil` and every publish is a
    /// no-op, which is exactly the pre-sync behaviour.
    private let sessionPointer: BotSessionPointerStore?
    private let timeouts: Timeouts
    private let policy: ReconnectPolicy
    private let stateBox = TransportStateBox()
    private nonisolated let eventHub = ClientEventHub()

    /// Each read registers a fresh, independent, bounded live subscription. Cancelling one
    /// observer never finishes another subscription or the transport's event pump.
    public nonisolated var events: AsyncStream<ClientEvent> { eventHub.subscribe() }

    // MARK: - Mutable connection state

    private var transport: TransportBridge?
    private var pump: Task<Void, Never>?
    private var connectionGeneration = 0
    private var connectTask: Task<Void, Error>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectGeneration = 0
    private var isIntentionalDisconnect = false

    private var sawReady = false
    private var readySignal: OneShotSignal<Void>?
    private var replayEpoch: String?
    private var advertised: Set<String> = []

    private var nextRequestIDSuffix: Int64 = 0
    private var pending: [RPCID: PendingCall] = [:]
    private var openServerRequests: [ServerRequestID: ServerRequest] = [:]
    private var watermarks: [SessionID: Watermark] = [:]

    /// The runtime id every session-scoped call needs, and the durable id only `session.resume`
    /// accepts. They are different values on the wire and both have to be remembered.
    /// The bot this connection is bound to. A stored session id is only resolvable inside its
    /// profile on a multiplexed gateway, and the reconnect path has no other way to know which.
    private var boundProfile: String?
    private var attachedRuntimeID: SessionID?
    private var attachedStoredID: SessionID?
    private var lastSnapshot: SessionResume?
    private var rewindSurvivors: [SessionID: [Int64?]] = [:]

    public init(makeTransport: @escaping TransportFactory,
                sessionPointer: BotSessionPointerStore? = nil,
                timeouts: Timeouts = Timeouts(),
                reconnect: ReconnectPolicy = ReconnectPolicy()) {
        self.makeTransport = makeTransport
        self.sessionPointer = sessionPointer
        self.timeouts = timeouts
        self.policy = reconnect
    }

    // MARK: - GatewayClientProtocol

    /// Readable without `await`: the connection chip polls it, and the protocol's `get async`
    /// requirement is satisfied by a nonisolated synchronous getter.
    public nonisolated var state: TransportState { stateBox.current }

    public func connect() async throws {
        isIntentionalDisconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectGeneration += 1
        if case .open = stateBox.current, sawReady { return }
        if let existing = connectTask {
            try await existing.value
            return
        }
        // A socket that exists but has not finished its handshake is NOT "no connection": dialing a
        // second one here abandoned the first (deallocated `URLSessionWebSocketTask` → close 1001
        // "client closed"), which is what a normal `start()` from a view `.task` during a handshake
        // or a reconnect used to do. The gateway then published the turn's `message.delta` frames to
        // the abandoned socket and the reply only appeared after the next resume re-read history.
        if transport != nil {
            if case .failed = stateBox.current { /* fall through and dial a replacement */ }
            else {
                try await waitForExistingSocket()
                return
            }
        }
        let task = Task { try await self.performConnect() }
        connectTask = task
        defer { connectTask = nil }
        try await task.value
    }

    public func disconnect() async {
        isIntentionalDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectGeneration += 1
        failAllPending(GatewayError.transportClosed("client closed"))
        failReady(GatewayError.transportClosed("client closed"))
        await dropConnection(reason: "client closed")
        setState(.closed(reason: "client closed"))
    }

    // MARK: Sessions

    public func ping() async throws {
        let result = try await perform("ping", params: .object([:]), timeout: timeouts.call)
        guard result?["pong"]?.boolValue == true else {
            throw GatewayError.malformedResponse(method: "ping")
        }
    }

    public func listBots() async throws -> [Bot] {
        let result = try await perform("profiles.list", params: .object([:]), timeout: timeouts.call)
        return try GatewayPayloadDecoder.bots(result)
    }

    public func listSessions(limit: Int) async throws -> [SessionSummary] {
        try await listSessions(limit: limit, profile: nil, includeHidden: true)
    }

    /// `include_hidden` is sent on *every* path, including the unscoped one: without it a normal
    /// profile answers 0 rows on this backend (measured: `assistant` 0 with the filter, 1 with it), and
    /// "no sessions" is a lie the UI would render as an empty bot.
    public func listSessions(limit: Int, profile: String?, includeHidden: Bool) async throws -> [SessionSummary] {
        var params: [String: JSONValue] = [
            "limit": .int(Int64(limit)),
            "include_hidden": .bool(includeHidden),
        ]
        if let profile, !profile.isEmpty {
            params["profile"] = .string(profile)
        }
        let result = try await perform("session.list", params: .object(params), timeout: timeouts.sessionList)
        return try GatewayPayloadDecoder.sessionSummaries(result)
    }

    public func resumeSession(_ id: SessionID) async throws -> SessionResume {
        try await resumeSession(id, profile: nil)
    }

    public func resumeSession(_ id: SessionID, profile: String?) async throws -> SessionResume {
        if let profile, !profile.isEmpty { boundProfile = profile }
        let resumed = try await performResume(id, profile: profile ?? boundProfile)
        attach(resumed, announced: false)
        return resumed.resume
    }

    public func createSession(model: String?, provider: String?) async throws -> SessionID {
        try await createSession(model: model, provider: provider, profile: nil)
    }

    public func createSession(model: String?, provider: String?, profile: String?) async throws -> SessionID {
        try await createSession(model: model, provider: provider, profile: profile, idempotencyKey: nil)
    }

    public func createSession(model: String?, provider: String?, profile: String?,
                              idempotencyKey: String?) async throws -> SessionID {
        var params: [String: JSONValue] = [:]
        if let model { params["model"] = .string(model) }
        if let provider { params["provider"] = .string(provider) }
        // `profile` binds the new session to that bot for its whole life: the gateway stores the
        // resulting profile_home and re-binds HERMES_HOME on every turn.
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        // A deterministic key lets a second device that opened the same bot at the same moment land
        // on this session instead of minting a twin (`methods_session.py` dedupes within 300 s while
        // the session is live).
        if let idempotencyKey, !idempotencyKey.isEmpty { params["idempotency_key"] = .string(idempotencyKey) }
        let result = try await perform("session.create", params: .object(params), timeout: timeouts.sessionResume)
        guard let runtimeID = result?["session_id"]?.stringValue else {
            throw GatewayError.malformedResponse(method: "session.create")
        }
        let storedID = result?["stored_session_id"]?.stringValue ?? runtimeID
        if let profile, !profile.isEmpty { boundProfile = profile }
        attachedRuntimeID = runtimeID
        attachedStoredID = storedID
        // Return the **stored** id: every caller treats the result as a session-list identity and
        // hands it to `session.resume`, which refuses a runtime id (`4007`). Returning the runtime
        // id here made "new chat" open a session that could not be resumed.
        return storedID
    }

    public func history(_ id: SessionID, limit: Int) async throws -> [TranscriptEntry] {
        let result = try await perform("session.history",
                                       params: .object(["session_id": .string(id)]),
                                       timeout: timeouts.call)
        return try GatewayPayloadDecoder.history(result, limit: limit)
    }

    // MARK: Shared conversation pointer

    /// The bridge's answer, not the gateway's: the pointer is HTTP on the bridge surface, so it
    /// travels through a `BotSessionPointerStore` rather than a JSON-RPC method. No store (tests,
    /// previews, a client built without bridge credentials) means "nothing known", which sends the
    /// caller to its local cache.
    public func sharedSessionID(forBot profile: String) async throws -> SessionID? {
        guard let sessionPointer else { return nil }
        return try await sessionPointer.storedSessionID(for: profile)
    }

    /// The bridge's read of every bot's newest message. No pointer store means no bridge to ask,
    /// which is the empty answer the caller falls back from.
    public func botPreviews() async throws -> [String: BotConversationPreview] {
        guard let sessionPointer else { return [:] }
        return try await sessionPointer.previews()
    }

    /// Fire-and-forget by nature, but `throws` so the caller can log that the other device will
    /// keep its own pointer. Never retried here: an unreachable bridge is the caller's problem to
    /// ignore, not something to queue behind a conversation that already opened.
    public func publishSharedSessionID(_ id: SessionID?, forBot profile: String) async throws {
        guard let sessionPointer else { return }
        try await sessionPointer.publish(storedSessionID: id, for: profile)
    }

    /// Bot management is the bridge's, like the pointer: no store means an older host, which
    /// must fail loudly instead of faking a delete.
    public func deleteBot(_ profile: String) async throws {
        guard let sessionPointer else { throw BotAdminUnavailable() }
        try await sessionPointer.deleteBot(profile)
    }

    public func setBotEnabled(_ profile: String, enabled: Bool) async throws {
        guard let sessionPointer else { throw BotAdminUnavailable() }
        try await sessionPointer.setBotEnabled(profile, enabled: enabled)
    }

    public func disabledBots() async throws -> Set<String> {
        guard let sessionPointer else { return [] }
        return try await sessionPointer.disabledBots()
    }

    /// Rooms are the bridge's, like the pointer and bot management.
    public func rooms() async throws -> [RoomSummary] {
        guard let sessionPointer else { return [] }
        return try await sessionPointer.rooms()
    }

    public func createRoom(name: String, members: [String]) async throws -> RoomSummary {
        guard let sessionPointer else { throw BotAdminUnavailable() }
        return try await sessionPointer.createRoom(name: name, members: members)
    }

    public func roomPage(_ roomID: String, since: Int?) async throws -> RoomPage {
        guard let sessionPointer else { throw BotAdminUnavailable() }
        return try await sessionPointer.roomPage(roomID, since: since)
    }

    public func sendRoomMessage(_ roomID: String, text: String) async throws {
        guard let sessionPointer else { throw BotAdminUnavailable() }
        try await sessionPointer.sendRoomMessage(roomID, text: text)
    }

    public func disbandRoom(_ roomID: String) async throws {
        guard let sessionPointer else { throw BotAdminUnavailable() }
        try await sessionPointer.disbandRoom(roomID)
    }

    public func renameRoom(_ roomID: String, name: String) async throws {
        guard let sessionPointer else { throw BotAdminUnavailable() }
        try await sessionPointer.renameRoom(roomID, name: name)
    }

    public func sendRoomMessage(_ roomID: String, text: String,
                                attachments: [RoomAttachment]) async throws {
        guard let sessionPointer else { throw BotAdminUnavailable() }
        try await sessionPointer.sendRoomMessage(roomID, text: text, attachments: attachments)
    }

    // MARK: Turns

    public func submit(session: SessionID, text: String) async throws -> TurnDelivery {
        // `status` comes back streaming / queued / steered / redirected; all four mean the prompt was
        // accepted, and the difference is what the app tells the user happened to their message.
        let result = try await perform("prompt.submit",
                                       params: .object(["session_id": .string(addressableID(session)), "text": .string(text)]),
                                       timeout: timeouts.call)
        let status: String
        switch result {
        case .object(let fields): status = fields["status"]?.stringValue ?? ""
        default: status = ""
        }
        return TurnDelivery(rawValue: status.lowercased()) ?? .unknown
    }

    public func steer(session: SessionID, text: String) async throws {
        _ = try await perform("session.steer",
                              params: .object(["session_id": .string(addressableID(session)), "text": .string(text)]),
                              timeout: timeouts.call)
    }

    public func interrupt(session: SessionID) async throws {
        _ = try await perform("session.interrupt",
                              params: .object(["session_id": .string(addressableID(session))]),
                              timeout: timeouts.call)
    }

    /// The id the gateway will accept for the session the caller is holding.
    ///
    /// The session list hands out **stored** ids (`20261103_063640_d774e4`), but a live turn is
    /// addressed by the **runtime** id that `session.resume` / `session.create` returns
    /// (`4586a350`). Submitting the stored id to a resumed session is refused with
    /// `4001 session not found` in ~2 ms — measured against the real gateway, and exactly the
    /// failure the app showed. After a resume both ids are known, so translate here rather than
    /// making every call site remember which one it has.
    private func addressableID(_ session: SessionID) -> SessionID {
        if let stored = attachedStoredID, let runtime = attachedRuntimeID, session == stored {
            return runtime
        }
        return session
    }

    /// Rewind + resend, cut at a durable row id.
    ///
    /// `truncate_before_row_id` is preferred over the legacy ordinal because a row id cannot drift
    /// when the transcript is compacted. `confirm_deep_truncate` is sent because pointing at a row
    /// *is* the confirmation — everything after it goes, which the caller already showed. The empty
    /// case is deliberately not confirmed here: wiping the whole transcript needs its own explicit
    /// answer, delivered through the overload below.
    public func rewind(session: SessionID, toRowID: Int64, then text: String) async throws {
        try await rewind(session: session, toRowID: toRowID, then: text, confirmingEmptyTranscript: false)
    }

    /// The same rewind, after the user agreed that the cut erases the entire transcript (`4028`).
    public func rewind(session: SessionID,
                       toRowID: Int64,
                       then text: String,
                       confirmingEmptyTranscript: Bool) async throws {
        var params: [String: JSONValue] = [
            "session_id": .string(session),
            "text": .string(text),
            "truncate_before_row_id": .int(toRowID),
            "confirm_truncate": .bool(true),
            "confirm_deep_truncate": .bool(true),
        ]
        if confirmingEmptyTranscript {
            params["confirm_empty_truncate"] = .bool(true)
        }
        do {
            let result = try await perform("prompt.submit", params: .object(params), timeout: timeouts.call)
            // After a cut the gateway re-mints row ids for any survivor it had to rewrite; the UI
            // holds the old ones in its cached bubbles.
            if let survivors = result?["survivor_user_row_ids"]?.arrayValue {
                rewindSurvivors[session] = survivors.map { $0.intValue }
            }
        } catch let error as GatewayError {
            throw Self.rewindError(error)
        }
    }

    // MARK: Discovery

    public func modelOptions() async throws -> [ModelOption] {
        let result = try await perform("model.options", params: .object([:]), timeout: timeouts.call)
        return try GatewayPayloadDecoder.modelOptions(result)
    }

    public func modelCatalog() async throws -> ModelCatalog {
        let result = try await perform("model.options", params: .object([:]), timeout: timeouts.call)
        return try GatewayPayloadDecoder.modelCatalog(result)
    }

    public func modelCatalog(profile: String?) async throws -> ModelCatalog {
        var params: [String: JSONValue] = [:]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        let result = try await perform("model.options", params: .object(params), timeout: timeouts.call)
        return try GatewayPayloadDecoder.modelCatalog(result)
    }

    /// `profiles.configure`, model section only. The bridge refuses every other section, so this
    /// can change a bot's model and nothing else about it.
    public func configureModel(profile: String, model: String, provider: String,
                               confirm: Bool) async throws -> ProfileModelChange {
        var params: [String: JSONValue] = [
            "name": .string(profile),
            "model": .string(model),
            "provider": .string(provider),
        ]
        if confirm { params["confirm_expensive_model"] = .bool(true) }
        let result = try await perform("profiles.configure", params: .object(params),
                                       timeout: timeouts.sessionResume)
        if result?["confirm_required"]?.boolValue == true {
            let message = result?["confirm_message"]?.stringValue
            return .confirmationRequired(message: message ?? "The host wants confirmation for this model.")
        }
        guard result?["ok"]?.boolValue != false else {
            throw GatewayError.malformedResponse(method: "profiles.configure")
        }
        let applied = result?["applied"]?.objectValue
        return .applied(model: applied?["model"]?.stringValue ?? model,
                        provider: applied?["provider"]?.stringValue ?? provider)
    }

    /// `profiles.configure`, description section only.
    ///
    /// Exactly two params go on the wire — `name` and `description`. Sending the model fields too
    /// (with the values the client last saw) would turn a description edit into a model change and
    /// could trip the host's expensive-model confirmation for no reason.
    public func configureDescription(profile: String, description: String) async throws {
        let result = try await perform("profiles.configure", params: .object([
            "name": .string(profile),
            "description": .string(description),
        ]), timeout: timeouts.sessionResume)
        if result?["confirm_required"]?.boolValue == true {
            // A description is never an expensive model; if the host asks, something is wrong.
            throw GatewayError.malformedResponse(method: "profiles.configure")
        }
        guard result?["ok"]?.boolValue != false else {
            throw GatewayError.malformedResponse(method: "profiles.configure")
        }
    }

    // MARK: Bot lifecycle

    /// `profiles.create` — one call that makes a bot, with its identity already in place.
    ///
    /// `mirror_credentials` is left at the host default (on): a bot without a provider answers
    /// nothing, and the owner asked to *create* a bot, not to configure a model.
    public func createProfile(name: String, description: String?, soul: String?) async throws -> String {
        var params: [String: JSONValue] = ["name": .string(name)]
        if let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["description"] = .string(description)
        }
        if let soul, !soul.isEmpty { params["soul"] = .string(soul) }
        let result = try await perform("profiles.create", params: .object(params),
                                       timeout: timeouts.sessionResume)
        guard result?["ok"]?.boolValue != false,
              let created = result?["name"]?.stringValue, !created.isEmpty else {
            throw GatewayError.malformedResponse(method: "profiles.create")
        }
        return created
    }

    /// `profiles.describe` — the editor snapshot for one bot.
    public func describeProfile(_ profile: String) async throws -> ProfileDescription {
        let result = try await perform("profiles.describe", params: .object(["name": .string(profile)]),
                                       timeout: timeouts.sessionResume)
        guard let result else { throw GatewayError.malformedResponse(method: "profiles.describe") }
        return ProfileDescription(
            name: result["name"]?.stringValue ?? profile,
            description: result["description"]?.stringValue ?? "",
            soul: result["soul"]?.stringValue ?? "",
            model: result["model"]?["default"]?.stringValue,
            provider: result["model"]?["provider"]?.stringValue
        )
    }

    /// `profiles.configure`, soul section only.
    public func configureSoul(profile: String, soul: String) async throws {
        let result = try await perform("profiles.configure", params: .object([
            "name": .string(profile),
            "soul": .string(soul),
        ]), timeout: timeouts.sessionResume)
        if result?["confirm_required"]?.boolValue == true {
            // A SOUL.md is never an expensive model; if the host asks, something is wrong.
            throw GatewayError.malformedResponse(method: "profiles.configure")
        }
        guard result?["ok"]?.boolValue != false else {
            throw GatewayError.malformedResponse(method: "profiles.configure")
        }
    }

    // MARK: Attachments

    /// The client's decoded-byte ceiling; refused here as well so the user sees the limit
    /// instead of a rejected frame. In sync with `AttachmentBudget.maximumBytes` in the phone
    /// app: 8 MiB decodes from ~10.7 MiB of base64, safely under the 16 MiB websocket frame.
    private static let maxAttachmentBytes = 8 * 1024 * 1024

    public func attach(session: SessionID, name: String, data: Data,
                       isImage: Bool) async throws -> AttachmentReceipt {
        guard !data.isEmpty, data.count <= Self.maxAttachmentBytes else {
            throw GatewayError.rpc(RPCError(code: -32000,
                                            message: "attachment must be 1 byte to 8 MB"))
        }
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\\0\n\r")) == nil else {
            throw GatewayError.rpc(RPCError(code: -32000, message: "invalid attachment name"))
        }
        let encoded = data.base64EncodedString()
        let method = isImage ? "image.attach_bytes" : "file.attach"
        var params: [String: JSONValue] = ["session_id": .string(addressableID(session))]
        if isImage {
            params["filename"] = .string(name)
            params["content_base64"] = .string(encoded)
        } else {
            params["name"] = .string(name)
            params["data_url"] = .string("data:application/octet-stream;base64," + encoded)
        }
        let result = try await perform(method, params: .object(params), timeout: timeouts.sessionResume)
        guard result?["attached"]?.boolValue == true else {
            throw GatewayError.malformedResponse(method: method)
        }
        // Images are queued by the host; only a staged file produces a reference the prompt needs.
        // Either way the reply names where the host put it, which is the name the transcript will
        // quote back — the handle that lets a picture survive a relaunch.
        return AttachmentReceipt(refText: isImage ? nil : result?["ref_text"]?.stringValue,
                                 path: result?["path"]?.stringValue)
    }

    // MARK: Compaction

    /// `session.compress` with the **runtime** id.
    ///
    /// The host addresses a live session by the id `session.resume` handed back; a stored id is
    /// refused with `4001` even on a healthy socket (the same translation `prompt.submit` needs).
    /// The reply carries no transcript, so the caller re-resumes to see the compacted history.
    public func compress(session: SessionID) async throws {
        _ = try await perform("session.compress",
                              params: .object(["session_id": .string(addressableID(session))]),
                              timeout: timeouts.compress)
    }

    // MARK: Server → client requests

    public func answer(_ request: ServerRequestID, with result: JSONValue) async throws {
        try await sendResponse(id: request, result: result, error: nil)
    }

    public func decline(_ request: ServerRequestID, with error: RPCError) async throws {
        try await sendResponse(id: request, result: nil, error: error)
    }

    // MARK: - Additions (not in the frozen protocol, safe for the apps to ignore)

    /// The snapshot the automatic reconnect just produced for the attached session.
    ///
    /// A reconnecting app cannot call `resumeSession` itself without racing the client, and the
    /// `ClientEvent` enum has no "resumed" case (the turn's text must not arrive as a fake delta).
    /// Apps read the inflight bubble and the restored question cards from here.
    public func reconnectSnapshot() -> SessionResume? { lastSnapshot }

    /// Survivor row ids from the last rewind of *session*, positionally matching the user turns the
    /// gateway kept; `nil` entries mean "drop the cached id for that turn".
    public func survivorRowIDs(for session: SessionID) -> [Int64?]? { rewindSurvivors[session] }

    /// Server→client requests still awaiting an answer on this connection.
    public func pendingServerRequests() -> [ServerRequest] {
        openServerRequests.values.sorted { $0.id.description < $1.id.description }
    }

    /// The server→client methods this backend said it may send (`client.capabilities` reply).
    public func advertisedServerRequestMethods() -> [String] { advertised.sorted() }

    // MARK: - Handshake

    private func performConnect(retrying: Bool = false) async throws {
        let generation = beginConnection()
        // A reconnect already told the UI `.reconnecting(attempt:)`; downgrading the chip to plain
        // `.connecting` mid-retry reads as "we lost it again".
        if !retrying { setState(.connecting) }

        let bridge: TransportBridge
        do {
            bridge = try await makeTransport()
        } catch {
            setState(.failed(String(describing: error)))
            throw GatewayError.transportClosed("could not create transport: \(error)")
        }

        transport = bridge
        do {
            try await bridge.connect()
        } catch {
            transport = nil
            setState(.failed(String(describing: error)))
            throw GatewayError.transportClosed("connect failed: \(error)")
        }

        startPump(bridge, generation: generation)
        do {
            try await waitForReady(generation: generation)
            try await advertiseCapabilities()
        } catch {
            // A socket that opened and then failed the handshake must not be left half-alive: the
            // chip would sit on "connecting" while nothing is listening.
            let message = (error as? GatewayError)?.message ?? String(describing: error)
            await dropConnection(reason: "handshake failed")
            setState(.failed(message))
            throw error
        }
        setState(.open)
    }

    /// Wait for a socket that is **already dialed** to finish its handshake, without touching
    /// `readySignal` (the connect/reconnect task that owns the handshake holds that).
    ///
    /// A caller that arrives mid-handshake must not dial a second socket: the first one is then
    /// released by `beginConnection`, the OS closes it as 1001 "client closed", and any event the
    /// gateway had already routed to it (a streaming turn) is lost.
    private func waitForExistingSocket() async throws {
        let deadline = Date().addingTimeInterval(timeouts.handshake)
        while Date() < deadline {
            if sawReady { return }
            // The socket went away: whoever owns the dial reports its own outcome through the state
            // events, and turning that into an error here would paint a failure over a reconnect.
            if transport == nil { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if sawReady { return }
        throw GatewayError.transportClosed("gateway did not become ready")
    }

    /// `gateway.ready` is always the first frame, so waiting for it is what turns "socket opened"
    /// into "this is a Hermes gateway". A socket that opens and never speaks is a failure, not a
    /// slow connection.
    private func waitForReady(generation: Int) async throws {
        if sawReady { return }
        let signal = OneShotSignal<Void>()
        readySignal = signal
        let limit = timeouts.handshake
        let timer = Self.armTimer(seconds: limit) { [weak self] in
            await self?.expireReady(generation: generation)
        }
        defer { timer?.cancel() }
        do {
            try await signal.wait()
        } catch {
            if readySignal === signal { readySignal = nil }
            throw error
        }
    }

    /// Exactly once per connection, *after* ready. Without it the gateway refuses every
    /// approval/clarify/sudo it would otherwise send us and the agent waits out its deadline.
    private func advertiseCapabilities() async throws {
        do {
            let result = try await perform("client.capabilities",
                                           params: .object(["server_requests": .bool(true)]),
                                           timeout: timeouts.call)
            advertised = Set((result?["server_requests"]?.arrayValue ?? []).compactMap { $0.stringValue })
        } catch let error as GatewayError {
            // An older backend answers -32601 here. That is a version skew, not a dead connection:
            // keep the session usable and let approvals fail fast on the server.
            if case .rpc(let rpc) = error, rpc.code == -32601 {
                advertised = []
                return
            }
            throw error
        }
    }

    // MARK: - Frame pump

    private func startPump(_ bridge: TransportBridge, generation: Int) {
        pump?.cancel()
        pump = Task.detached(priority: .userInitiated) { [weak self] in
            for await event in bridge.events {
                guard let self else { return }
                let keepGoing = await self.handle(event, generation: generation)
                if !keepGoing { return }
            }
            await self?.streamEnded(generation: generation)
        }
    }

    /// Returns `false` when this pump should stop (superseded connection or a lost socket).
    private func handle(_ event: GatewayTransport.Event, generation: Int) async -> Bool {
        guard generation == connectionGeneration else { return false }
        switch event {
        case .state(let transportState):
            switch transportState {
            case .open:
                // The socket is up; the client does not report `.open` until the handshake is done.
                return true
            case .closed(let reason), .failed(let reason):
                return connectionLost(reason: reason)
            case .idle, .connecting, .reconnecting:
                return true
            }
        case .frame(let frame):
            await handle(frame)
            return generation == connectionGeneration
        case .malformed(let line):
            // -32700 is the gateway's own parse-error code; a torn frame is the same class of event.
            yield(.error(code: -32700, message: "malformed frame: \(line)"))
            return true
        }
    }

    private func handle(_ frame: IncomingFrame) async {
        switch frame {
        case .response(let id, let result, let error):
            if let error {
                settle(id: id, .failure(GatewayError.rpc(error)))
            } else {
                settle(id: id, .success(result))
            }
        case .notification(let method, let params):
            // The envelope: method is always "event" and the real name is inside params.type.
            if method == "event" {
                handleEvent(params)
            } else {
                yield(.unknown(type: method, payload: params))
            }
        case .request(let request):
            await route(request)
        }
    }

    /// The key the replay bookkeeping uses — deliberately **not** the attribution key.
    ///
    /// `watermarks` is compared against `session.events.since`, which addresses the session by its
    /// **runtime** id, so this must stay on the wire identity. Keying it by the stored id silently
    /// disabled replay: the watermark for the runtime id was never found, `last_seen` went missing,
    /// and deltas written during a disconnect were never fetched (caught by
    /// `testMissedDeltasAreReplayedWhenTheEpochMatches`).
    private func watermarkKey(_ explicit: String?) -> SessionID {
        if let explicit, !explicit.isEmpty { return explicit }
        return attachedRuntimeID ?? attributedSession(explicit)
    }

    /// Which session an event belongs to.
    ///
    /// Measured on the wire: the events of a live turn carry **no** session id at all — their
    /// envelope is `{"type":"message.delta","payload":{"text","turn_id","segment","offset"}}`, and
    /// `message.start` is `{"turn_id"}`, `thinking.delta` is `{"text"}`. One connection is attached
    /// to one session, so those events belong to it. Reading `session_id` alone yielded `""`, and a
    /// UI that filters events by session therefore dropped every delta: the reply streamed past a
    /// window stuck on "working".
    ///
    /// An explicit id is still honoured when present (other surfaces do send one), and it is
    /// normalized to the *stored* id because that is the identity the session list and the UI use —
    /// the runtime id is only an address for calls.
    private func attributedSession(_ explicit: String?) -> SessionID {
        if let explicit, !explicit.isEmpty {
            if explicit == attachedRuntimeID, let stored = attachedStoredID { return stored }
            return explicit
        }
        return attachedStoredID ?? ""
    }

    private func handleEvent(_ params: JSONValue) {
        guard let type = params["type"]?.stringValue else {
            yield(.unknown(type: "", payload: params))
            return
        }
        let session = attributedSession(params["session_id"]?.stringValue)
        let payload = params["payload"] ?? .null

        if let seq = params["seq"]?.intValue {
            watermarks[watermarkKey(params["session_id"]?.stringValue)] = Watermark(seq: Int(seq), epoch: replayEpoch)
        }

        if type == "gateway.ready" {
            replayEpoch = payload["replay_epoch"]?.stringValue
            sawReady = true
            let signal = readySignal
            readySignal = nil
            signal?.settle(.success(()))
            yield(.ready(replayEpoch: replayEpoch))
            return
        }

        if type == "request.cancel" {
            guard let id = RPCID(json: payload["id"]) else {
                yield(.unknown(type: type, payload: payload))
                return
            }
            openServerRequests.removeValue(forKey: id)
            yield(.requestCancelled(id: id, reason: payload["reason"]?.stringValue))
            return
        }

        if let events = GatewayEventDecoder.events(type: type, session: session, payload: payload) {
            for event in events { yield(event) }
        } else {
            yield(.unknown(type: type, payload: payload))
        }
    }

    private func route(_ request: RPCRequest) async {
        guard Self.answerableServerRequests.contains(request.method) else {
            // The agent is blocked on this frame right now. Refusing explicitly beats dropping it:
            // the tool fails in one round trip instead of waiting out its deadline.
            let refusal = RPCError(code: -32601,
                                   message: "unknown method: \(request.method) — not available in this client")
            try? await sendResponse(id: request.id, result: nil, error: refusal)
            yield(.unknown(type: request.method, payload: request.params ?? .null))
            return
        }
        let serverRequest = ServerRequest(id: request.id, method: request.method, params: request.params ?? .null)
        openServerRequests[request.id] = serverRequest
        yield(.request(serverRequest))
    }

    private func streamEnded(generation: Int) {
        guard generation == connectionGeneration else { return }
        _ = connectionLost(reason: "transport stream ended")
    }

    // MARK: - Calls

    private func perform(_ method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue? {
        // A call made while the socket is coming back waits for that attempt instead of failing:
        // the UI's refresh-on-reconnect would otherwise race the client and surface a spurious
        // "not connected". The reconnect is bounded by its own policy, so this cannot hang forever.
        if transport == nil, !isIntentionalDisconnect, let reconnect = reconnectTask {
            await reconnect.value
        }
        guard transport != nil, !isIntentionalDisconnect else { throw GatewayError.notConnected }
        let id = RPCID.int(nextRequestID())
        let signal = OneShotSignal<JSONValue?>()
        pending[id] = PendingCall(method: method, signal: signal)
        let timer = Self.armTimer(seconds: timeout) { [weak self] in
            await self?.expire(id: id, method: method, seconds: timeout)
        }
        defer { timer?.cancel() }

        // The waiter has to be parked before the frame goes out: the response can arrive while the
        // send is still suspended, and a signal created afterwards would drop it.
        async let answer = signal.wait()
        do {
            try await send(id: id, method: method, params: params)
        } catch {
            pending.removeValue(forKey: id)
            signal.settle(.failure(error))
            _ = try? await answer
            throw error
        }
        return try await answer
    }

    private func send(id: RPCID, method: String, params: JSONValue?) async throws {
        guard let transport else { throw GatewayError.notConnected }
        let line = try JSONRPCCodec.encodeToString(RPCRequest(id: id, method: method, params: params))
        do {
            try await transport.send(text: line)
        } catch {
            throw GatewayError.transportClosed("send failed: \(error)")
        }
    }

    private func sendResponse(id: RPCID, result: JSONValue?, error: RPCError?) async throws {
        guard let transport else { throw GatewayError.notConnected }
        do {
            try await transport.send(text: JSONRPCCodec.encodeToString(RPCResponse(id: id, result: result, error: error)))
        } catch {
            throw GatewayError.transportClosed("send failed: \(error)")
        }
        openServerRequests.removeValue(forKey: id)
    }

    private func settle(id: RPCID, _ result: Result<JSONValue?, Error>) {
        guard let call = pending.removeValue(forKey: id) else { return }  // late answer after a timeout
        call.signal.settle(result)
    }

    private func expire(id: RPCID, method: String, seconds: TimeInterval) {
        guard let call = pending.removeValue(forKey: id) else { return }
        call.signal.settle(.failure(GatewayError.timeout(method: method, seconds: seconds)))
    }

    private func failAllPending(_ error: Error) {
        let calls = Array(pending.values)
        pending.removeAll()
        for call in calls { call.signal.settle(.failure(error)) }
    }

    private func failReady(_ error: Error) {
        let signal = readySignal
        readySignal = nil
        signal?.settle(.failure(error))
    }

    private func expireReady(generation: Int) {
        guard generation == connectionGeneration, !sawReady else { return }
        failReady(GatewayError.handshakeTimedOut)
    }

    private func nextRequestID() -> Int64 {
        nextRequestIDSuffix += 1
        return nextRequestIDSuffix
    }

    // MARK: - Connection lifecycle

    private func beginConnection() -> Int {
        connectionGeneration += 1
        pump?.cancel()
        pump = nil
        // Never drop a live socket on the floor: a released `URLSessionWebSocketTask` is closed by
        // the OS as 1001 "client closed" while the gateway still believes it is attached, so a turn
        // in flight streams into nothing. Close it deliberately — the bytes cost nothing and the
        // gateway then re-attaches on the next resume instead of publishing to a dead peer.
        if let replaced = transport {
            transport = nil
            Task { await replaced.disconnect(reason: "connection replaced") }
        }
        sawReady = false
        failReady(GatewayError.transportClosed("connection replaced"))
        return connectionGeneration
    }

    /// Retire the current socket without touching the reconnect policy or the pending set.
    private func dropConnection(reason: String) async {
        connectionGeneration += 1
        pump?.cancel()
        pump = nil
        sawReady = false
        let closing = transport
        transport = nil
        await closing?.disconnect(reason: reason)
    }

    private func connectionLost(reason: String) -> Bool {
        failReady(GatewayError.transportClosed(reason))
        failAllPending(GatewayError.transportClosed(reason))
        transport = nil
        // `openServerRequests` deliberately survives: the agent is still blocked on those questions,
        // and the resume after the reconnect reconciles them (delivering the ones this app has not
        // seen, tearing down the ones the backend no longer waits on).

        guard !isIntentionalDisconnect, policy.enabled else {
            setState(.closed(reason: reason))
            return false
        }
        scheduleReconnect(after: reason)
        return false
    }

    private func scheduleReconnect(after reason: String) {
        guard reconnectTask == nil else { return }
        reconnectGeneration += 1
        let generation = reconnectGeneration
        reconnectTask = Task { [weak self] in
            await self?.runReconnect(after: reason, generation: generation)
        }
    }

    private func runReconnect(after reason: String, generation: Int) async {
        // Only the current reconnect clears the slot: a cancelled one finishing late must not wipe
        // the handle of the attempt that replaced it.
        defer {
            if generation == reconnectGeneration { reconnectTask = nil }
        }
        var attempt = 0
        while attempt < policy.maxAttempts {
            attempt += 1
            if isIntentionalDisconnect || Task.isCancelled { return }
            let delay = min(policy.initialDelay * pow(policy.multiplier, Double(attempt - 1)), policy.maxDelay)
            setState(.reconnecting(attempt: attempt))
            if delay > 0 {
                try? await Task.sleep(nanoseconds: Self.nanoseconds(delay))
            }
            if isIntentionalDisconnect || Task.isCancelled { return }
            do {
                try await performConnect(retrying: true)
                try await restoreAfterReconnect()
                return
            } catch {
                if isIntentionalDisconnect || Task.isCancelled { return }
            }
        }
        let message = "could not reconnect to the gateway (\(reason))"
        setState(.failed(message))
    }

    /// Re-attach, then replay the gap.
    ///
    /// `session.resume` is not optional here: the gateway routes a session's events to the transport
    /// it last attached, so a plain reconnect without a resume keeps writing to the dead socket.
    /// The resume reply is also the only place `inflight` (the turn half-written when we dropped)
    /// and `open_requests` (questions still blocking the agent) are restated in full.
    private func restoreAfterReconnect() async throws {
        guard let storedID = attachedStoredID else { return }
        let previousRuntimeID = attachedRuntimeID
        let watermark = previousRuntimeID.flatMap { watermarks[$0] }

        let resumed = try await performResume(storedID, profile: boundProfile)
        // A different runtime id is a different backend process: every question the old one was
        // blocked on died with it, so nothing it asked is still answerable.
        if let previous = previousRuntimeID, previous != resumed.runtimeID {
            for id in Array(openServerRequests.keys) {
                openServerRequests.removeValue(forKey: id)
                yield(.requestCancelled(id: id, reason: "resolved"))
            }
        }
        attach(resumed, announced: true)
        // Missed deltas, when the backend is the same process (same replay epoch) and the ring has
        // not truncated. Everything else means "you cannot patch this incrementally" and the app is
        // told to refetch — a silent, stale transcript is worse than a reload.
        guard let watermark,
              let epoch = replayEpoch,
              watermark.epoch == epoch,
              previousRuntimeID == resumed.runtimeID else {
            yield(.sessionUpdated(resumed.runtimeID))
            return
        }
        do {
            let replay = try await eventReplay(session: resumed.runtimeID, lastSeen: watermark.seq)
            if replay.truncated || (replay.epoch != epoch && !replay.epoch.isEmpty) {
                yield(.sessionUpdated(resumed.runtimeID))
                return
            }
            for event in replay.events { handleEvent(event) }
            watermarks[resumed.runtimeID] = Watermark(seq: replay.latestSeq, epoch: epoch)
        } catch {
            yield(.sessionUpdated(resumed.runtimeID))
            yield(.error(code: nil, message: "event replay failed: \(error)"))
        }
    }

    private func eventReplay(session: SessionID, lastSeen: Int) async throws -> GatewayPayloadDecoder.EventReplay {
        let result = try await perform("session.events.since",
                                       params: .object(["session_id": .string(session),
                                                        "last_seen": .int(Int64(lastSeen))]),
                                       timeout: timeouts.call)
        return try GatewayPayloadDecoder.eventReplay(result)
    }

    private func performResume(_ id: SessionID, profile: String?) async throws -> GatewayPayloadDecoder.Resume {
        var params: [String: JSONValue] = ["session_id": .string(id)]
        // A stored id is only resolvable inside its bot on a multiplexed gateway; omitting this is
        // "4007 session not found" even for a session the same socket created a second earlier.
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        let result = try await perform("session.resume",
                                       params: .object(params),
                                       timeout: timeouts.sessionResume)
        return try GatewayPayloadDecoder.sessionResume(result, requestedID: id)
    }

    private func attach(_ resumed: GatewayPayloadDecoder.Resume, announced: Bool) {
        attachedRuntimeID = resumed.runtimeID
        attachedStoredID = resumed.storedID
        lastSnapshot = resumed.resume
        reconcileOpenRequests(resumed.resume.openRequests, announced: announced)
    }

    /// Bring the client's open-question set in line with an authoritative `open_requests` list.
    ///
    /// A question the app already had is not delivered twice (the gateway's own replay re-delivers
    /// "as if newly arrived", and a reducer that appends blindly would draw two approval cards); a
    /// question the backend no longer lists was answered or withdrawn while we were away, so the
    /// card is torn down rather than left waiting on an agent that moved on.
    private func reconcileOpenRequests(_ requests: [ServerRequest], announced: Bool) {
        let listed = Set(requests.map(\.id))
        for request in requests where openServerRequests[request.id] == nil {
            openServerRequests[request.id] = request
            if announced { yield(.request(request)) }
        }
        let stale = Array(openServerRequests.keys).filter { !listed.contains($0) }
        for id in stale {
            openServerRequests.removeValue(forKey: id)
            if announced { yield(.requestCancelled(id: id, reason: "resolved")) }
        }
    }

    // MARK: - Plumbing

    private func setState(_ new: TransportState) {
        stateBox.set(new)
        yield(.state(new))
    }

    private func yield(_ event: ClientEvent) {
        eventHub.yield(event)
    }

    private static func rewindError(_ error: GatewayError) -> GatewayError {
        guard case .rpc(let rpc) = error else { return error }
        switch rpc.code {
        case 4028: return .needsEmptyTranscriptConfirmation(rpc.message)
        case 4033: return .needsDeepCutConfirmation(rpc.message)
        default: return error
        }
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        guard seconds > 0, seconds.isFinite else { return 0 }
        return UInt64(min(seconds * 1_000_000_000, 9_000_000_000_000_000_000))
    }

    /// Arms a one-shot timer; `nil` when the caller asked for no bound at all.
    private static func armTimer(seconds: TimeInterval,
                                 _ body: @escaping @Sendable () async -> Void) -> Task<Void, Never>? {
        guard seconds > 0, seconds.isFinite else { return nil }
        let delay = nanoseconds(seconds)
        return Task.detached {
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await body()
        }
    }
}

#if canImport(Darwin)
extension GatewayClient {
    /// The real thing: a WebSocket per connection, a fresh one per reconnect so each gets its own
    /// single-use ticket from `urlProvider`.
    ///
    /// Darwin-only: `URLSessionWebSocketTask` has no Linux counterpart, and the Linux build exists
    /// to typecheck the protocol core against a fake transport.
    public static func webSocket(urlProvider: @escaping GatewayTransport.URLProvider,
                                 session: URLSession = .shared,
                                 sessionPointer: BotSessionPointerStore? = nil,
                                 timeouts: Timeouts = Timeouts(),
                                 reconnect: ReconnectPolicy = ReconnectPolicy()) -> GatewayClient {
        GatewayClient(makeTransport: {
            GatewayTransport(urlProvider: urlProvider, session: session).bridge()
        }, sessionPointer: sessionPointer, timeouts: timeouts, reconnect: reconnect)
    }
}
#endif
