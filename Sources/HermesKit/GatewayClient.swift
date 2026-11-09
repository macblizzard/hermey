import Foundation

/// The one API the two apps are allowed to call.
///
/// Frozen contract for the app agents: everything below is implemented in
/// `Sources/HermesKit/` by the protocol-core work. Apps talk to `GatewayClient`
/// and observe `ClientEvent` — they never touch sockets, tickets or JSON.
/// What the host did with a prompt. `queued`/`steered`/`redirected` are acceptances: the busy
/// policy (steer after the current action, redirect, or run after this turn) is the host's, and the
/// client's only job is to say which one happened.
public enum TurnDelivery: String, Sendable {
    case streaming, queued, steered, redirected, unknown
}

public protocol GatewayClientProtocol: AnyObject, Sendable {
    /// Current transport state, for the connection chip.
    var state: TransportState { get async }

    /// Events from the gateway: streamed text, tool lifecycle, approvals, lifecycle.
    var events: AsyncStream<ClientEvent> { get }

    /// Attach to a host and perform the mandatory handshake
    /// (`gateway.ready` → `client.capabilities {server_requests:true}`).
    func connect() async throws

    func disconnect() async

    // Bots
    /// The bots (Hermes **profiles**) this one gateway serves.
    ///
    /// `gateway.multiplex_profiles` is true by default, so a host is not one assistant: it is an
    /// address book of them, and every session belongs to exactly one. There is no second
    /// connection and no second ticket — just a `profile` argument on the calls below.
    func listBots() async throws -> [Bot]

    // Sessions
    /// Cheapest possible round trip: the gateway answers `{"pong": true}` without touching
    /// the session database. Used for the connection chip's latency figure — `session.list`
    /// would make the number depend on how warm the profile is (see `fixtures/NOTES.md` §4).
    func ping() async throws
    func listSessions(limit: Int) async throws -> [SessionSummary]
    /// `listSessions`, scoped to one bot.
    ///
    /// - Parameters:
    ///   - profile: the bot's `id`. `nil` means "whatever profile this gateway defaults to",
    ///     which is what an unpaired/older host can answer.
    ///   - includeHidden: **must stay `true`** on any surface with a bots pane. A normal profile
    ///     reports 0 rows under the gateway's default filter (measured: `assistant` 0 → 1,
    ///     `chief` 5, `analyst` 2, `ops` 1 with `include_hidden`), so `false` here reads as
    ///     "this bot has no sessions" instead of "this bot exists".
    func listSessions(limit: Int, profile: String?, includeHidden: Bool) async throws -> [SessionSummary]
    func resumeSession(_ id: SessionID) async throws -> SessionResume

    /// Resume inside a named bot.
    ///
    /// A multiplexed gateway (every machine-level one is: 15 profiles here) resolves a **stored**
    /// session id only within an explicit profile. Measured: `session.resume` with the stored id and
    /// no `profile` answers `4007 session not found` in under a second, while the same call with
    /// `"profile": "assistant"` succeeds — which presented as "the conversation will not open" right after
    /// creating it. Implementations that have no profile to give fall back to the single-argument form.
    func resumeSession(_ id: SessionID, profile: String?) async throws -> SessionResume
    func createSession(model: String?, provider: String?) async throws -> SessionID
    /// Create a session **inside one bot**.
    ///
    /// The gateway's `session.create` accepts `profile` and stores the resulting `profile_home`,
    /// so every later turn of that session re-binds to it (`tui_gateway/methods_session.py::
    /// _create_session`). Without the argument a new session always lands in whichever profile the
    /// gateway defaults to, which is how a user ends up typing into the wrong bot.
    func createSession(model: String?, provider: String?, profile: String?) async throws -> SessionID

    /// Create a session **inside one bot**, with a deterministic idempotency key.
    ///
    /// Two devices opening the same bot at the same moment both see "no shared pointer" and both
    /// call `session.create`; the gateway dedupes retries that carry the same key while the session
    /// is live in its process (`_IDEMPOTENCY_KEY_TTL`, 300 s), so a key like `bot-chat:<profile>`
    /// makes them converge on ONE session instead of forking the conversation. Clients with no such
    /// notion drop the key and forward the plain call.
    func createSession(model: String?, provider: String?, profile: String?,
                       idempotencyKey: String?) async throws -> SessionID
    func history(_ id: SessionID, limit: Int) async throws -> [TranscriptEntry]

    /// Every bot's newest message, keyed by profile — read by the bridge off the host's own message
    /// table. A client with no bridge pointer answers `[:]`, which sends the caller to the
    /// gateway's coarser `session.list` preview.
    func botPreviews() async throws -> [String: BotConversationPreview]
    /// The same rows with this device's read marks applied: per-bot unread counts.
    func botPreviews(since marks: [String: Double]) async throws -> BotPreviewFeed

    /// Delete a bot's profile on the host (`POST /v1/bots/{profile}/purge` on the bridge). The
    /// bridge archives the profile before Hermes removes it.
    func deleteBot(_ profile: String) async throws

    /// Turn a bot off — its scheduled jobs paused — or back on.
    func setBotEnabled(_ profile: String, enabled: Bool) async throws

    /// Which bots are off, so the list marks them without one request per bot.
    func disabledBots() async throws -> Set<String>

    /// Group chats hosted by this gateway (`GET /v1/rooms` on the bridge).
    func rooms() async throws -> [RoomSummary]

    /// Open a group chat with a name and 2–6 bots.
    func createRoom(name: String, members: [String]) async throws -> RoomSummary

    /// One page of a room's spoken log, after `since` when the caller already has history.
    func roomPage(_ roomID: String, since: Int?) async throws -> RoomPage

    /// Post one message into a room. The bots named in the text are the ones that answer.
    func sendRoomMessage(_ roomID: String, text: String) async throws

    /// Remove a group chat for good.
    func disbandRoom(_ roomID: String) async throws

    /// Rename a group chat.
    func renameRoom(_ roomID: String, name: String) async throws

    /// Post a message with files attached.
    func sendRoomMessage(_ roomID: String, text: String, attachments: [RoomAttachment]) async throws

    // Shared conversation pointer
    /// Which stored session is **this bot's** conversation, as the bridge holds it.
    ///
    /// The pointer is shared by every paired device, which is the whole point: the phone and the
    /// Mac resume the same stored id instead of each minting its own. It is HTTP on the bridge
    /// (`GET /v1/bots/{profile}/session`), not a gateway RPC, so implementations that have no
    /// bridge credentials — previews, the unpaired client, an older host — answer `nil` and the
    /// caller falls back to its local cache.
    func sharedSessionID(forBot profile: String) async throws -> SessionID?

    /// Publish `id` as this bot's conversation so the other device adopts it; `nil` clears it.
    ///
    /// Best-effort by contract: a failure here must never block opening a conversation.
    func publishSharedSessionID(_ id: SessionID?, forBot profile: String) async throws

    // Turns
    func submit(session: SessionID, text: String) async throws -> TurnDelivery
    func steer(session: SessionID, text: String) async throws
    func interrupt(session: SessionID) async throws
    /// Rewind + resend. Must send `confirm_truncate` and prefer `truncate_before_row_id`.
    func rewind(session: SessionID, toRowID: Int64, then text: String) async throws

    // Discovery
    func modelOptions() async throws -> [ModelOption]

    /// `model.options` as the host answered it: the catalogue **and** which entry is current.
    ///
    /// The catalogue alone cannot say what the app is talking to — the reply names it in
    /// `model` + `provider`, and the first catalogue entry is just the first provider's first
    /// model (measured: `anthropic/claude-fable`, while the live turn ran `deepseek-v4.1-flash`
    /// on `opencode-go`). Reading `providers[0].models[0]` is what put the wrong chip on screen.
    func modelCatalog() async throws -> ModelCatalog

    /// `model.options` scoped to one bot.
    ///
    /// The catalogue is per profile: each bot can run a different model, so asking without a
    /// profile answers for whichever profile the gateway happens to default to.
    func modelCatalog(profile: String?) async throws -> ModelCatalog

    /// Set a bot's **profile default** model (`profiles.configure`, model section only).
    ///
    /// This does not touch an existing conversation: a live session may carry its own model
    /// override, and the host only adopts the new default for turns that are not pinned.
    func configureModel(profile: String, model: String, provider: String, confirm: Bool) async throws -> ProfileModelChange

    /// Set a bot's human-readable description (`profiles.configure`, description section only).
    ///
    /// Sends exactly `{name, description}` — no model, no provider, no other section — so the
    /// bridge's allow-list can keep this to one field of the profile. The text is stored on the
    /// host, which is what makes it follow the bot to every device. An empty string clears it.
    func configureDescription(profile: String, description: String) async throws

    /// Create a bot (`profiles.create`) — the one gateway call that writes a new profile: its name,
    /// its description and its SOUL.md. Returns the name the host actually created.
    func createProfile(name: String, description: String?, soul: String?) async throws -> String

    /// Everything the bot editor needs for one bot (`profiles.describe`): the SOUL text, the
    /// description the host stores, and the model pin.
    func describeProfile(_ profile: String) async throws -> ProfileDescription

    /// Replace a bot's SOUL.md (`profiles.configure`, soul section only).
    ///
    /// Only `{name, soul}` go on the wire: sending the description or the model alongside would
    /// turn "edit the soul" into three section writes, and the bridge's allow-list is per-field.
    func configureSoul(profile: String, soul: String) async throws

    // Compaction
    /// Attach bytes to the session's next turn.
    ///
    /// Only the byte-carrying RPCs are used: `image.attach_bytes` queues an image and
    /// `file.attach` stages a file and answers with an `@file:` reference that must be included in
    /// the prompt. The bridge refuses the path-based variants outright.
    func attach(session: SessionID, name: String, data: Data, isImage: Bool) async throws -> AttachmentReceipt

    // Compaction
    /// `session.compress` — ask the host to summarise the session into a smaller context.
    ///
    /// `session_id` must be the **runtime** id (`GatewayClient` translates a stored id), and the
    /// call is slow by nature: the host runs a real model turn to write the summary.
    func compress(session: SessionID) async throws

    /// Answer a request the gateway sent us (approval, clarify, sudo, secret…).
    func answer(_ request: ServerRequestID, with result: JSONValue) async throws
    func decline(_ request: ServerRequestID, with error: RPCError) async throws
}

extension GatewayClientProtocol {
    /// No bridge, no previews. Declared as a default (not just a concrete method) so every client
    /// that has no bridge credentials — the unpaired one, the fixture, a preview — is a valid
    /// conformer while `client.botPreviews()` still dispatches dynamically for the real one.
    public func botPreviews() async throws -> [String: BotConversationPreview] { [:] }

    public func botPreviews(since marks: [String: Double]) async throws -> BotPreviewFeed { BotPreviewFeed() }

    /// No bridge, no bot management: a client without the routes fails loudly rather than
    /// reporting a delete that never happened.
    public func deleteBot(_ profile: String) async throws { throw BotAdminUnavailable() }
    public func setBotEnabled(_ profile: String, enabled: Bool) async throws { throw BotAdminUnavailable() }
    public func disabledBots() async throws -> Set<String> { [] }

    /// A client with no gateway (fixtures, previews) cannot make bots. Failing loudly beats a
    /// sheet that closes as if something had been created.
    public func createProfile(name: String, description: String?, soul: String?) async throws -> String {
        throw BotAdminUnavailable()
    }
    public func describeProfile(_ profile: String) async throws -> ProfileDescription {
        throw BotAdminUnavailable()
    }
    public func configureSoul(profile: String, soul: String) async throws {
        throw BotAdminUnavailable()
    }
    public func rooms() async throws -> [RoomSummary] { [] }
    public func createRoom(name: String, members: [String]) async throws -> RoomSummary {
        throw BotAdminUnavailable()
    }
    public func roomPage(_ roomID: String, since: Int?) async throws -> RoomPage {
        throw BotAdminUnavailable()
    }
    public func sendRoomMessage(_ roomID: String, text: String) async throws {
        throw BotAdminUnavailable()
    }
    public func disbandRoom(_ roomID: String) async throws {
        throw BotAdminUnavailable()
    }
    public func renameRoom(_ roomID: String, name: String) async throws {
        throw BotAdminUnavailable()
    }
    public func sendRoomMessage(_ roomID: String, text: String,
                                attachments: [RoomAttachment]) async throws {
        throw BotAdminUnavailable()
    }
}

public typealias SessionID = String
public typealias ServerRequestID = RPCID

/// One bot: a Hermes **profile**.
///
/// One bot's editor snapshot (`profiles.describe`): the SOUL text the app edits, the description
/// the list shows, and the model pin the host stores for it.
public struct ProfileDescription: Sendable, Equatable {
    public var name: String
    public var description: String
    public var soul: String
    public var model: String?
    public var provider: String?

    public init(name: String, description: String, soul: String,
                model: String? = nil, provider: String? = nil) {
        self.name = name
        self.description = description
        self.soul = soul
        self.model = model
        self.provider = provider
    }
}

/// Measured against the deployed gateway: `profiles.list` answers
/// `{"profiles":[…], "bot_mode_protocol":…, "install_id":…}` with 15 entries for this host, and
/// `session.list {profile:"<name>", include_hidden:true}` returns that bot's own rows. So the bot
/// switcher is one call plus one argument — never a second connection.
///
/// `id` is the wire value (what `profile` accepts), never a prettified label, so selecting a bot
/// is a lookup rather than a string transform.
public struct Bot: Identifiable, Hashable, Sendable {
    /// The profile name exactly as the host reported it; the value `session.list` takes as `profile`.
    public let id: String
    /// The same name, spelled out for callers that think in profiles rather than bots.
    public let name: String
    /// What the switcher renders. Falls back to `name` when the host sends no label of its own.
    public let displayName: String
    /// A one-token label for compact chrome (menu bar item, navigation title).
    public let label: String
    /// One or two characters for the avatar circle ("assistant" → "C", "ops-team" → "OT").
    public let avatarInitials: String
    /// A human-readable line about the bot, stored on the host and shared by every device
    /// (`profiles.list` sends it, `profiles.configure` writes it). `nil` when the host has none.
    public let description: String?

    public init(id: String,
                name: String? = nil,
                displayName: String? = nil,
                label: String? = nil,
                avatarInitials: String? = nil,
                description: String? = nil) {
        let resolvedName = Self.trimmed(name) ?? id
        let resolvedDisplay = Self.trimmed(displayName) ?? resolvedName
        self.id = id
        self.name = resolvedName
        self.displayName = resolvedDisplay
        self.label = Self.trimmed(label) ?? resolvedDisplay
        self.avatarInitials = Self.trimmed(avatarInitials) ?? Self.initials(for: resolvedDisplay)
        self.description = Self.trimmed(description)
    }

    /// A copy carrying a new host description, keeping every other field as the host reported it.
    public func withDescription(_ value: String?) -> Bot {
        Bot(id: id, name: name, displayName: displayName, label: label,
            avatarInitials: avatarInitials, description: value)
    }

    /// First letter of the name, or of its first two words ("assistant" → "C", "night-ops" → "NO").
    /// An avatar is never sent on the wire, so it is derived rather than decoded.
    static func initials(for text: String) -> String {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.count >= 2, let first = words[0].first, let second = words[1].first {
            return String([first, second]).uppercased()
        }
        return String(text.prefix(1)).uppercased()
    }

    static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public extension GatewayClientProtocol {
    /// Conformers with no notion of a bot (previews, the unpaired stub, tests) keep the global call.
    func modelCatalog(profile: String?) async throws -> ModelCatalog {
        try await modelCatalog()
    }

    /// Stubs have no profiles to configure; say so instead of pretending the change landed.
    func configureModel(profile: String, model: String, provider: String, confirm: Bool) async throws -> ProfileModelChange {
        _ = (profile, model, provider, confirm)
        throw GatewayError.rpc(RPCError(code: -32601,
                                        message: "this client cannot configure a profile"))
    }

    /// Same for a description: a stub that cannot write it must not report success.
    func configureDescription(profile: String, description: String) async throws {
        _ = (profile, description)
        throw GatewayError.rpc(RPCError(code: -32601,
                                        message: "this client cannot configure a profile"))
    }

    /// Stubs never carry bytes anywhere.
    func attach(session: SessionID, name: String, data: Data, isImage: Bool) async throws -> AttachmentReceipt {
        _ = (session, name, data, isImage)
        throw GatewayError.rpc(RPCError(code: -32601,
                                        message: "this client cannot attach files"))
    }

    /// Conformers with no notion of a bot (previews, the unpaired stub, tests) keep the plain call.
    func resumeSession(_ id: SessionID, profile: String?) async throws -> SessionResume {
        try await resumeSession(id)
    }

    /// A client that cannot carry an idempotency key still creates the session; it just cannot
    /// coalesce two devices opening the same bot at the same instant.
    func createSession(model: String?, provider: String?, profile: String?,
                       idempotencyKey: String?) async throws -> SessionID {
        _ = idempotencyKey
        return try await createSession(model: model, provider: provider, profile: profile)
    }

    /// Without bridge credentials there is no shared pointer to read: say "nothing known" so the
    /// caller uses its local cache, rather than inventing an id or failing the open.
    func sharedSessionID(forBot profile: String) async throws -> SessionID? {
        _ = profile
        return nil
    }

    /// A client that cannot write the pointer accepts the publish as a no-op. Reporting success is
    /// honest here — the id it was handed is what this client will keep using locally, and no
    /// caller acts on this beyond logging a failure.
    func publishSharedSessionID(_ id: SessionID?, forBot profile: String) async throws {
        _ = (id, profile)
    }
}

public struct SessionSummary: Identifiable, Hashable, Sendable {
    public let id: SessionID
    public let title: String
    public let updatedAt: Date?
    public let preview: String?
    public let running: Bool

    public init(id: SessionID, title: String, updatedAt: Date? = nil, preview: String? = nil, running: Bool = false) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.preview = preview
        self.running = running
    }

    /// What a row should render when the host has no title yet.
    ///
    /// Measured on this host: 10 of the default bot's 17 sessions are untitled, so a sidebar that
    /// prints `title` draws a column of question marks and reads as broken. Titles arrive from the
    /// gateway only once a turn has been summarised, so the honest fallbacks are, in order: the
    /// first line of the preview, then an explicit "Untitled session".
    public var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return trimmedTitle }
        if let preview {
            let line = preview.split(separator: "\n").first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !line.isEmpty { return String(line.prefix(60)) }
        }
        return "Untitled session"
    }
}

public struct SessionResume: Sendable {
    public let id: SessionID
    public let entries: [TranscriptEntry]
    /// The turn still running that history does not hold yet.
    public let inflight: InflightTurn?
    /// Approvals/clarify questions still waiting for an answer.
    public let openRequests: [ServerRequest]

    public init(id: SessionID, entries: [TranscriptEntry], inflight: InflightTurn?, openRequests: [ServerRequest]) {
        self.id = id
        self.entries = entries
        self.inflight = inflight
        self.openRequests = openRequests
    }

    /// Whether a turn is *still running* on the host, as the resume reported it.
    ///
    /// This is the authority the UI has to adopt after a resume: a turn that finished while the
    /// socket was down leaves no `message.complete` for us to receive, so a client that keeps its
    /// own streaming flag sits on "Thinking…" forever. `inflight` nil (nothing running) and
    /// `streaming: false` (a finished-but-unflushed turn) both mean "nothing more is coming".
    public var isStreaming: Bool { inflight?.streaming == true }

    /// The partial assistant text worth keeping when `isStreaming` is false — a turn that settled
    /// unattended still wrote something, and dropping it would blank the last bubble.
    public var liveText: String { inflight?.assistantText ?? "" }
}

public struct InflightTurn: Sendable {
    public let userText: String
    public let assistantText: String
    public let streaming: Bool

    public init(userText: String, assistantText: String, streaming: Bool) {
        self.userText = userText
        self.assistantText = assistantText
        self.streaming = streaming
    }
}

public struct TranscriptEntry: Identifiable, Hashable, Sendable {
    public enum Role: String, Sendable {
        case user, assistant, tool, system
        /// The model's reasoning for the turn. Never sent by the host as a row — the client
        /// synthesises it when a turn ends, so the reasoning stops vanishing with the answer.
        case reasoning
    }

    /// What a `role: "tool"` row carries besides its text.
    ///
    /// The host's projection for a tool row is `{role, name, context, args?, labels?, tool_call_id,
    /// content?}` — there is no `text` at all, and `content` (the result) is only included for the
    /// editing tools. A decoder that reads `text`/`content` alone therefore renders every one of
    /// these as a nameless "Tool" card with nothing behind it, which is exactly what it did.
    public struct ToolDetail: Hashable, Sendable {
        /// The wire `name`: `terminal`, `read_file`, `patch`.
        public let name: String
        /// The host's ~80-character preview of the arguments, for the card's one-line summary.
        public let context: String?
        /// The arguments in full (pretty JSON) — the call itself, so it is always worth showing.
        public let args: String?
        /// The tool's own result, when this projection included one (edit tools only).
        public let content: String?
        /// Display labels the host pre-composed for the call, in its own order.
        public let labels: [String]

        public init(name: String,
                    context: String? = nil,
                    args: String? = nil,
                    content: String? = nil,
                    labels: [String] = []) {
            self.name = name
            self.context = context
            self.args = args
            self.content = content
            self.labels = labels
        }

        /// What a tapped card should open: the result when the host sent one, else the call itself.
        public var detail: String? {
            if let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return content
            }
            return args
        }
    }

    public let id: String
    public let rowID: Int64?
    public let role: Role
    public let text: String
    public let at: Date?
    /// Present on `role: "tool"` rows that came from the host's projection.
    public let tool: ToolDetail?
    /// The message as the user wrote it: the host's `@image:` reference lines are bookkeeping, not
    /// part of the sentence, and a bubble that prints them shows an absolute path where the picture
    /// (or its name) belongs.
    public var displayText: String {
        role == .user ? MessageRefs.display(text) : text
    }

    /// What travelled with a user message. The host returns no attachment metadata for the
    /// transcript, so this is the client's own memory of the send (see `SentAttachmentVault`).
    public var attachments: [SentAttachment]

    public init(id: String,
                rowID: Int64? = nil,
                role: Role,
                text: String,
                at: Date? = nil,
                tool: ToolDetail? = nil,
                attachments: [SentAttachment] = []) {
        self.id = id
        self.rowID = rowID
        self.role = role
        self.text = text
        self.at = at
        self.tool = tool
        self.attachments = attachments
    }
}

public struct ModelOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let provider: String
    public let label: String

    public init(id: String, provider: String, label: String) {
        self.id = id
        self.provider = provider
        self.label = label
    }
}

/// What the host answered after receiving bytes.
///
/// Images are queued for the next turn and need nothing further; a file yields an `@file:`
/// reference that has to travel in the prompt, so the caller must not drop it.
public struct AttachmentReceipt: Equatable, Sendable {
    public let refText: String?
    /// Where the host put the file. For an image this is the only identity the later transcript
    /// will quote — `@image:<path>` — so it is what the bytes are cached under.
    public let path: String?

    public init(refText: String?, path: String? = nil) {
        self.refText = refText
        self.path = path
    }
}

/// The outcome of asking the host to change a bot's default model.
///
/// `profiles.configure` answers `{ok, applied, confirm_required?, confirm_message?}`: a model the
/// host considers expensive is refused the first time and only lands when the same call is repeated
/// with `confirm_expensive_model: true`. A transport-level success is not an applied change, so the
/// client returns this instead of a bare `Void`.
public enum ProfileModelChange: Equatable, Sendable {
    case applied(model: String, provider: String)
    /// The host wants explicit consent before it will honour this model.
    case confirmationRequired(message: String)
}

/// What `model.options` actually answers: everything the host can run, plus the one it *is*
/// running.
///
/// Measured body: `{"providers":[{"slug":"anthropic","models":["claude-fable",…]}, …],
/// "model":"deepseek-v4.1-flash", "provider":"opencode-go"}`. The top-level pair is the answer to
/// "what am I talking to"; `providers[].models[]` is a menu, in host order, and its first entry is
/// not the current model.
public struct ModelCatalog: Equatable, Sendable {
    /// The model the next turn will use. `nil` when the host did not name one.
    public let current: ModelOption?
    public let options: [ModelOption]

    public init(current: ModelOption?, options: [ModelOption]) {
        self.current = current
        self.options = options
    }
}

/// A request the *gateway* sends the client and blocks on.
public struct ServerRequest: Identifiable, Sendable {
    public let id: ServerRequestID
    public let method: String
    public let params: JSONValue

    public init(id: ServerRequestID, method: String, params: JSONValue) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// Everything the UI reacts to. Note the wrapped `event` envelope: on the wire these
/// arrive as `method:"event"` with `params.type` + `params.payload` (see
/// `fixtures/NOTES.md`), never as `method:"message.delta"`.
public enum ClientEvent: Sendable {
    case ready(replayEpoch: String?)
    case state(TransportState)
    case messageDelta(session: SessionID, text: String)
    /// Commentary the model wrote *beside* a tool call, sealed by the host as its own segment
    /// (`message.interim`). It is the "on it — checking the release" line between a sent message
    /// and the answer; a client that does not model it shows tool cards and silence instead.
    case interimMessage(session: SessionID, text: String, alreadyStreamed: Bool, key: String)
    case messageComplete(session: SessionID, text: String)
    /// The model's reasoning, a stream of its own: `thinking.delta` arrives *without*
    /// `message.delta` text and with an empty `text` heartbeat. Mixing it into the reply would
    /// show the model thinking out loud in the answer bubble.
    case thinkingDelta(session: SessionID, text: String)
    case toolStart(session: SessionID, name: String, callID: String, input: String)
    case toolProgress(session: SessionID, callID: String, text: String)
    case toolComplete(session: SessionID, name: String?, callID: String, output: String?, ok: Bool, durationMS: Int?)
    /// `message.complete`'s `usage`: how full the context is. `percent` is the host's own rounded
    /// figure when it sent one.
    case contextUsage(session: SessionID, used: Int, max: Int, percent: Double?)
    case request(ServerRequest)
    case requestCancelled(id: ServerRequestID, reason: String?)
    case sessionUpdated(SessionID)
    case error(code: Int?, message: String)
    /// Any event we do not model yet. Kept so a Hermes upgrade never breaks the client.
    case unknown(type: String, payload: JSONValue)
}

// MARK: - Defaults that keep the frozen contract source-compatible

public extension GatewayClientProtocol {
    /// Unscoped fallback for a client that cannot address a profile — today that is only the
    /// unpaired app, whose every verb already throws `noHost`.
    ///
    /// It delegates to the single-argument call *on purpose*: a client that can scope must
    /// implement this overload, because quietly ignoring `profile` is exactly how one bot's rows
    /// end up under another bot's name.
    func listSessions(limit: Int, profile: String?, includeHidden: Bool) async throws -> [SessionSummary] {
        try await listSessions(limit: limit)
    }

    /// A client with no host cannot enumerate bots. Failing is honest; `[]` would render as
    /// "your host has no bots", which is a different and wrong story.
    func listBots() async throws -> [Bot] {
        throw GatewayError.notConnected
    }

    /// Unscoped fallback for a client that cannot address a profile (the unpaired app, previews).
    /// A client that *can* scope must implement the profile-aware overload.
    func createSession(model: String?, provider: String?, profile: String?) async throws -> SessionID {
        try await createSession(model: model, provider: provider)
    }

    /// A client that cannot tell which model is current only has its menu. Reported as "no current
    /// model" rather than guessing `options.first` — guessing is the chip bug.
    func modelCatalog() async throws -> ModelCatalog {
        ModelCatalog(current: nil, options: try await modelOptions())
    }

    /// Compaction is a host capability this build may not have (an unpaired client has no host at
    /// all). Failing honestly keeps "compacted" from being shown over a transcript nothing touched.
    func compress(session: SessionID) async throws {
        throw GatewayError.notConnected
    }
}
