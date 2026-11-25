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

    /// End the reconnect ladder's pause and dial now, keeping the ladder alive if the dial fails.
    ///
    /// Used when the app learns — from a resume that died with the socket, or from a notification
    /// about a message it has not drawn yet — that waiting out the backoff would be waiting for
    /// something already known to be late.
    func retryNow() async

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

    /// Which conversation the **host** treats as this bot's one chat.
    ///
    /// Hermes keeps exactly one canonical session per profile: title exactly `Bot Chat`, born
    /// hidden, resolved by name on every open, and shared by Desktop, the TUI,
    /// `hermes -p <bot> chat -c "Bot Chat"`, cron `bot-chat` delivery and `message_agent`. Reading
    /// it here is what makes a Hermey conversation the *same* conversation as those. See
    /// `CanonicalBotChat`.
    func canonicalBotChat(forProfile profile: String) async throws -> CanonicalBotChat.HostState

    /// This bot's canonical row plus **the host's own message count** for it.
    ///
    /// The count is the reason this exists. `session.list`'s bulk rows carry `message_count`, the
    /// denormalised column, which counts only the rows still *active* — `cody`'s 6,806-message chat
    /// reports **675** there, because compaction retires the rest. The host's display count
    /// (`live_message_count`, grouped exactly the way a transcript read groups its rows) reported
    /// **6,136** for the same conversation. A ceiling read off the wrong one never fires: the chat
    /// grows past 6,000 while the app believes it is under 700.
    ///
    /// One row, one count query — asked once per open (see `AppModel.rollBotChatIfNeeded`), never
    /// per turn. `nil` means the host has no canonical row (or could not be asked): nothing to roll.
    func botChatRow(profile: String) async throws -> BotChatRow?

    /// Name an existing session `Bot Chat` — the adoption step for a bot whose conversation started
    /// life as a Hermey-only session. Throws when another row already holds the title
    /// (`CanonicalBotChat.isTitleConflict`), which the caller resolves by switching to that row.
    func titleSession(_ session: SessionID, title: String, profile: String?) async throws

    /// Mint this bot's canonical Bot Chat the way Desktop does: title `Bot Chat`, born **hidden** so
    /// it does not appear as a second row in a session list, and following the profile's own config
    /// rather than whatever model the caller happened to be on.
    ///
    /// A host that does not accept `title`/`hidden` at create answers with an error; the caller
    /// falls back to a plain `createSession`, which is the pre-canonical behaviour.
    func createCanonicalSession(profile: String, idempotencyKey: String?) async throws -> SessionID

    /// Archive a session. Used to *retire* a Bot Chat, matching Desktop: the archived row keeps its
    /// history, its name is freed for a successor, and the next open mints a fresh canonical chat.
    func archiveSession(_ session: SessionID, profile: String?) async throws

    /// Put an archived session back. The roll's undo, and nothing else's.
    ///
    /// A roll archives the chat and then mints its successor; if the mint is refused (a host that
    /// will not free the name, a dead socket in between), the bot must be left on the conversation
    /// it had rather than on one this device quietly retired. Defaulted to a refusal so a client
    /// without the route reports the half-done state instead of pretending it undid it.
    func unarchiveSession(_ session: SessionID, profile: String?) async throws

    /// `session.set_hidden` — hide a row that a list would otherwise show.
    ///
    /// The roll's one other prerequisite: the host hands the unique title `Bot Chat` to a successor
    /// only when the row holding it is **archived and hidden** (`_resolve_title_conflict`). A
    /// canonical chat is born hidden, so this is normally a no-op; an *adopted* chat can be
    /// visible, and without this the successor would be refused the name and end up auto-titled.
    func setSessionHidden(_ hidden: Bool, session: SessionID, profile: String?) async throws
    func history(_ id: SessionID, limit: Int) async throws -> [TranscriptEntry]

    /// The same read, scoped to the bot that owns the conversation.
    ///
    /// `session.history` resolves a session id **only in the host's in-memory registry**
    /// (`session_registry.py::_sess_nowait` is a plain `_sessions.get(sid)`, and its `4001` carries the
    /// comment "client should resume the stored session"). A stored id for a conversation nobody has
    /// attached therefore answers `session not found` — *with or without* a `profile`, which is what
    /// the launch prefetch's eighteen failures actually were (build 0.1.612). This call is for a
    /// conversation that already has a live pane, addressed by the **runtime** id a resume returned;
    /// warming an unseen bot is `warmResume`, never this.
    ///
    /// A client with a single profile to resolve against has nothing to scope, so the default below
    /// forwards to the unscoped read.
    func history(_ id: SessionID, limit: Int, profile: String?) async throws -> [TranscriptEntry]

    /// Warm one bot's conversation **without opening it**.
    ///
    /// `session.resume` is the only call that turns a *stored* id into rows for a conversation no
    /// transport is attached to, and it answers with the messages itself — measured on the live host:
    /// `{profile, session_id}` in, `session_id` (runtime), `resumed` (the stored id), `message_count`
    /// and `messages` back, in 0.03–0.7 s. One call is the whole warm.
    ///
    /// Deliberately **not** `resumeSession`: that one binds the connection to the profile and adopts
    /// the runtime id as *the* attached session, which is the open pane's own state. Eighteen of those
    /// at launch would leave the socket bound to whichever bot was warmed last, and every subsequent
    /// session-scoped call would be addressed with a stranger's runtime id (`4001`). A sweep is a
    /// read; it must not take the socket away from the chat on screen.
    ///
    /// A resume registers a **live session on the host**, attached to this connection's transport, and
    /// a session on a live transport is never reaped or LRU-evicted — so a client that warms must also
    /// `closeSession` the runtime id it minted, or it pins one idle agent per bot for the life of the
    /// connection. `liveSessionIDs` is how it tells what it minted from what was already there.
    ///
    /// A client that cannot separate warming from attaching answers with the ordinary resume.
    func warmResume(_ id: SessionID, profile: String) async throws -> SessionResume

    /// The runtime ids the host is holding live right now (`session.active_list`).
    ///
    /// Needed because releasing a warm resume is only safe for a session the sweep *created*: an id
    /// that was already here belongs to somebody's pane, and closing it ends their turn (measured —
    /// it waits 5 s for the turn thread, then tears the agent down). There is no other way to tell the
    /// two apart: a resume that reuses a live session answers with that session's id, not a new one.
    func liveSessionIDs() async throws -> Set<SessionID>

    /// Release one **runtime** session a warm resume created (`session.close`, which takes the runtime
    /// id and not the stored one).
    ///
    /// Idempotent from the caller's point of view: a session that is already gone is not an error
    /// worth reporting.
    func closeSession(_ id: SessionID) async throws

    /// One page of rows older than the transcript a resume already delivered.
    ///
    /// A long conversation does not fit in one WebSocket message: iOS refuses to deliver a
    /// multi-megabyte frame ("Message too long"), so the bridge ships the newest page with the
    /// resume and serves older pages from its own copy of it. `cursor` is the offset the resume (or
    /// the previous page) reported; the page comes back ending exactly where the caller's oldest
    /// row begins, so prepending it cannot leave a hole.
    func historyPage(_ id: SessionID, profile: String?, cursor: Int, limit: Int) async throws -> HistoryPage

    /// One native card (`GET /v1/cards/{id}?session=<session id>`) — the document a `::card{…}`
    /// marker names.
    ///
    /// The bridge resolves the file, because the client has the transcript and not the host's
    /// filesystem: `file` in the marker is relative to the session's working directory, and a path
    /// from a client is a path the host would have to sanitise. The id is all that travels, and the
    /// route refuses anything that is not `^[A-Za-z0-9_-]{1,40}$` before a path exists.
    ///
    /// Device-authenticated like every other `/v1` read, so it travels over the bridge pointer
    /// store rather than the JSON-RPC transport. Each refusal is a distinct `CardFetchError`, so a
    /// transcript can say `Card not available` for the right reason instead of spinning.
    ///
    /// `message` is the transcript row's own id. The host snapshots a card per
    /// `(session, message, card)`, so sending it is what keeps two messages that name one file
    /// from sharing a row — and what lets a reply still draw its card after the file is gone.
    func card(id: String, session: SessionID, message: String) async throws -> CardFetch

    /// Whether this connection has the host's `/v1` routes at all.
    ///
    /// The one question `AppModel` asks before it lets the host own a device-local thing: an
    /// unpaired app has no host to agree with, and must keep behaving exactly as it did before
    /// (reactions in `@AppStorage`). A client that can reach a bridge says so; everything else
    /// inherits `false` and loses nothing.
    var bridgeAvailable: Bool { get }

    /// `GET /v1/reactions?bot=<profile>&session=<session id>` — every reaction in one conversation,
    /// keyed by the message half of ``ReactionKey`` (`row:41`, `live:r3`).
    ///
    /// Device-authenticated like every other `/v1` read, so it rides the bridge pointer store. The
    /// host is the only place a Mac and a phone can meet: asking it is what makes a reaction the
    /// owner made on one device appear on the other.
    func reactions(bot: String, session: SessionID) async throws -> [String: Reaction]

    /// `PUT /v1/reactions` — set one reaction, or clear it with `nil`.
    ///
    /// One emoji per message, and a new one replaces the old, which is what both apps already did
    /// locally. The host persists it, then broadcasts `reaction.updated` on `/v1/ws` so the other
    /// device applies it without polling.
    func setReaction(bot: String, session: SessionID, message: String,
                     emoji: String?, by: String) async throws

    /// `POST /v1/messages/delete` — retire these messages from the conversation on every device.
    ///
    /// The engine has no message-level delete, so the host owns it: it refuses while a turn is
    /// running (409), closes the engine's live copy, and then writes `active=0, compacted=0` in one
    /// transaction. Nothing is removed from the database, and the reply carries the conversation's
    /// new display count so the app can re-resume and show the same conversation on both devices.
    func deleteMessages(bot: String, session: SessionID, messageIDs: [Int64]) async throws
        -> MessageRetireResult

    /// `POST /v1/messages/truncate` — retire this message and everything painted after it, which is
    /// what an edit-and-resend needs before it sends the new text.
    func truncateMessages(bot: String, session: SessionID, fromMessageID: Int64) async throws
        -> MessageRetireResult

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

    /// Ask one bot a question and wait for the answer (`POST /v1/bots/{profile}/ask` on the
    /// bridge).
    ///
    /// A separate turn addressed to the bot, not a message in the open conversation: the desktop
    /// pet asks without disturbing what is on screen. A host timeout is an answer —
    /// `BotAnswer.answered == false`, `reply == nil` — and a refusal arrives as
    /// `BotAskError.host` carrying the host's own sentence.
    func askBot(profile: String, question: String, from: String, timeout: Double) async throws -> BotAnswer

    /// The approval mode across every bot profile, read from the host's own configs.
    func approvalSettings() async throws -> ApprovalSettings

    /// Set one approval mode for every bot profile.
    func setApprovalMode(_ mode: ApprovalMode) async throws -> ApprovalSettings

    /// Mint a pairing invite for another device (`POST /v1/pair/start` on the bridge, authenticated
    /// as this paired device). Defaulted to a refusal: a host without the relaxed route must say so,
    /// not pretend to show a code.
    func makePairingInvite() async throws -> PairingInvite

    /// This bot's effort level and aux/vision model (`GET /v1/bots/{profile}/model-settings` on the
    /// bridge). Two facts the model catalogue cannot answer, because they live in the profile's config.
    ///
    /// Defaulted to a refusal: a client that predates the route must say it cannot see them, rather than
    /// draw every bot on "provider default" as though that were the answer.
    func modelSettings(_ profile: String) async throws -> BotModelSettings

    /// Change one or both of those (`PUT /v1/bots/{profile}/model-settings`). Only the arguments given
    /// travel, so saving the effort level cannot rewrite the vision model beside it.
    func setModelSettings(_ profile: String, effort: String?,
                          visionProvider: String?, visionModel: String?) async throws -> BotModelSettings

    /// This bot's schedules (`GET /v1/bots/{profile}/routines` on the bridge), soonest first.
    func routines(_ profile: String) async throws -> [BotRoutine]

    /// Pause or resume one of this bot's routines.
    func setRoutinePaused(_ profile: String, jobID: String, paused: Bool) async throws

    /// Create one (`POST /v1/bots/{profile}/routines` on the bridge) and return the row it made.
    func createRoutine(_ profile: String, draft: RoutineDraft) async throws -> BotRoutine

    /// What this bot remembers: its own notes and the owner's profile, read-only.
    func memory(_ profile: String) async throws -> BotMemory

    /// The owner's own note for this bot (`GET /v1/bots/{profile}/notes`).
    func notes(_ profile: String) async throws -> BotNotes

    /// Where this device's banners go while the app is shut (a Bark relay URL).
    func registerPushRelay(_ url: String) async throws

    /// The bot whose conversation is on screen, so its replies do not arrive as banners.
    func reportPresence(bot: String?) async throws

    /// One banner right now, to prove the relay works.
    func sendTestPush() async throws

    /// This bot's rendered face, so a banner can show it (`PUT /v1/push/icon/{bot}`).
    func uploadPushIcon(bot: String, png: Data, sha256: String) async throws

    /// Write the note back (`PUT`), whole: the host keeps one file and the last write wins.
    func saveNotes(_ text: String, for profile: String) async throws -> BotNotes

    /// The owner's groups of bots, and which bot sits in which (`GET /v1/bot-categories`).
    ///
    /// Host state, like the notes beside it: the phone and the Mac must show the same groups, so
    /// neither device keeps its own.
    func botCategories() async throws -> BotCategoryState
    func createBotCategory(name: String) async throws -> BotCategoryState
    func renameBotCategory(id: String, name: String) async throws -> BotCategoryState
    func deleteBotCategory(id: String) async throws -> BotCategoryState
    func setBotCategory(profile: String, categoryID: String?) async throws -> BotCategoryState
    func reorderBotCategories(ids: [String]) async throws -> BotCategoryState
    func credentialCards() async throws -> [CredentialCard]
    func answerCredentialCard(id: String, values: [String: String]) async throws
    func cancelCredentialCard(id: String) async throws

    /// `GET /v1/vault` — the names the host's vault holds, with a label and a date each, and no value.
    /// `VaultItem` has no field a value could travel in, so "the list is only names" is a property of
    /// the type rather than of the decoder.
    func vaultItems() async throws -> [VaultItem]
    /// `DELETE /v1/vault/{name}` — the name may hold one `/` (`doctolib.de/password`), which the client
    /// percent-encodes so the host's wildcard route reads it back as one name.
    func deleteVaultItem(name: String) async throws
    /// `PATCH /v1/vault/{name}` — rename an item and, when `value` is given, replace what is stored
    /// under it. One request and one host write for both halves; nothing is returned because a value
    /// only ever travels towards the host.
    func editVaultItem(name: String, rename: String, value: String?) async throws
    /// `POST /v1/credentials/cards` — ask the host for a card the owner answers.
    ///
    /// The Vault pane is the only caller and it asks for `store: true`: the value the owner types goes
    /// into the existing masked sheet and straight to the vault, which is why the pane needs no form of
    /// its own and there is still exactly one way a secret can enter the host.
    func createCredentialCard(site: String, fields: [String], store: Bool,
                              saveAs: String?, note: String?) async throws -> CredentialCard
    func integrations() async throws -> IntegrationsState
    func connectIntegration(slug: String, alias: String?) async throws -> String
    func integrationKeyFields(slug: String) async throws -> [IntegrationKeyField]
    func connectIntegrationWithKey(slug: String, values: [String: String]) async throws
    func renameIntegration(slug: String, accountID: String, alias: String) async throws
    func disconnectIntegration(slug: String, accountID: String?) async throws

    /// Findings inside every bot's conversation (`GET /v1/search`). Names are the list's business;
    /// a phrase a person remembers is this.
    func searchTranscripts(_ query: String, limit: Int, offset: Int) async throws -> BotSearchPage

    /// The recorded exchanges between two bots, oldest first (`GET /v1/bot-transfers`).
    func botTransfers(between first: String, and second: String, limit: Int) async throws -> [BotTransfer]

    /// The soul a new bot starts from (`GET /v1/bot-defaults`).
    func botDefaults() async throws -> BotDefaults

    /// Set, or clear with an empty text, the soul a new bot starts from (`PUT /v1/bot-defaults/soul`).
    func setDefaultSoul(_ text: String) async throws -> BotDefaults

    /// Every bot's config as one JSON document (`GET /v1/backup`).
    func exportBackup() async throws -> Data

    /// The same backup zipped with each bot's icon — what Import reads back.
    func exportBackupZip() async throws -> Data

    /// The text to paste into another product's bot so it writes a file this host can read.
    func importPrompt() async throws -> String

    /// `POST /v1/backup/import` — preview with `dryRun`, then apply with the same arguments.
    func importBackup(_ file: Data, mode: BotImportMode, dryRun: Bool) async throws -> BackupImportResult

    /// Rebuild a roster from that document (`POST /v1/backup/restore`).
    func restoreBackup(_ document: Data) async throws -> BackupRestoreResult

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
    /// `skills.manage {action: list}` — every skill this host offers this bot, flattened.
    ///
    /// `profiles.describe` only reports skills installed *in the bot's own folder*, which on this host
    /// is one or two; the shared library is what a bot actually works with, and the host's list already
    /// excludes the disabled ones and the ones this platform cannot run.
    func availableSkills(profile: String) async throws -> [String]

    /// Replace a bot's SOUL.md (`profiles.configure`, soul section only).
    ///
    /// Only `{name, soul}` go on the wire: sending the description or the model alongside would
    /// turn "edit the soul" into three section writes, and the bridge's allow-list is per-field.
    func configureSoul(profile: String, soul: String) async throws
    /// `profiles.configure` for the two feature lists. Both are *replacements*: what is sent is the
    /// whole set of disabled skills / enabled servers, not a delta.
    func configureFeatures(profile: String,
                           disabledSkills: [String]?,
                           enabledMCPServers: [String]?) async throws

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
    /// A client with one profile to resolve against answers the scoped read with the unscoped one.
    /// Declared as a default so every stub conformance stays valid while the real client's own
    /// three-argument `history` dispatches dynamically.
    public func history(_ id: SessionID, limit: Int, profile: String?) async throws -> [TranscriptEntry] {
        try await history(id, limit: limit)
    }

    /// A client with one shape of resume has to give the sweep the same call: the rows still arrive,
    /// only the client-side bookkeeping that this default cannot fake is skipped.
    public func warmResume(_ id: SessionID, profile: String) async throws -> SessionResume {
        try await resumeSession(id, profile: profile)
    }

    /// A client with no live-session registry — the unpaired one, a fixture, a preview — knows of
    /// nothing already held, so every warm resume it is asked for counts as its own to release.
    public func liveSessionIDs() async throws -> Set<SessionID> { [] }

    /// A client with no registry of runtime sessions has nothing to release.
    public func closeSession(_ id: SessionID) async throws {}

    /// A client with no bridge — the unpaired one, a fixture, a preview — cannot retire a message,
    /// and both menus withhold the verbs when `bridgeAvailable` is false. Reaching here is a caller
    /// that asked anyway, so it is told plainly instead of drawing a conversation that never moved.
    public func deleteMessages(bot: String, session: SessionID, messageIDs: [Int64]) async throws
        -> MessageRetireResult {
        _ = (bot, session, messageIDs)
        throw MessageRetireError.noBridge
    }

    public func truncateMessages(bot: String, session: SessionID, fromMessageID: Int64) async throws
        -> MessageRetireResult {
        _ = (bot, session, fromMessageID)
        throw MessageRetireError.noBridge
    }

    /// A client with no reconnect ladder — the unpaired one, a fixture, a preview — has nothing to
    /// bring forward: there is no scheduled attempt to end. Declared as a default so every stub
    /// conformance stays valid while the real client's own `retryNow` dispatches dynamically.
    public func retryNow() async {}

    /// No bridge, no previews. Declared as a default (not just a concrete method) so every client
    /// that has no bridge credentials — the unpaired one, the fixture, a preview — is a valid
    /// conformer while `client.botPreviews()` still dispatches dynamically for the real one.
    public func botPreviews() async throws -> [String: BotConversationPreview] { [:] }

    public func botPreviews(since marks: [String: Double]) async throws -> BotPreviewFeed { BotPreviewFeed() }

    /// No bridge, no bot management: a client without the routes fails loudly rather than
    /// reporting a delete that never happened.
    /// No bridge, no key-based integrations: an unpaired client, a fixture or a preview has nothing to ask and
    /// nowhere to send a key. Declared here so every stub conformance is valid without repeating itself.
    public func integrationKeyFields(slug: String) async throws -> [IntegrationKeyField] { [] }
    public func connectIntegrationWithKey(slug: String, values: [String: String]) async throws {
        throw BotAdminUnavailable()
    }

    public func deleteBot(_ profile: String) async throws { throw BotAdminUnavailable() }
    public func setBotEnabled(_ profile: String, enabled: Bool) async throws { throw BotAdminUnavailable() }
    public func disabledBots() async throws -> Set<String> { [] }

    /// A client with no bridge has no schedule to read: failing loudly beats an empty list over a
    /// bot that runs every night.
    public func routines(_ profile: String) async throws -> [BotRoutine] { throw BotAdminUnavailable() }
    public func setRoutinePaused(_ profile: String, jobID: String, paused: Bool) async throws {
        throw BotAdminUnavailable()
    }
    /// A client with no bridge cannot create a schedule either; the app shows the failure rather than
    /// pretending the routine exists.
    public func createRoutine(_ profile: String, draft: RoutineDraft) async throws -> BotRoutine {
        throw BotAdminUnavailable()
    }
    public func memory(_ profile: String) async throws -> BotMemory { throw BotAdminUnavailable() }
    public func notes(_ profile: String) async throws -> BotNotes { throw BotAdminUnavailable() }
    public func botCategories() async throws -> BotCategoryState { throw BotAdminUnavailable() }
    public func createBotCategory(name: String) async throws -> BotCategoryState {
        throw BotAdminUnavailable()
    }
    public func renameBotCategory(id: String, name: String) async throws -> BotCategoryState {
        throw BotAdminUnavailable()
    }
    public func deleteBotCategory(id: String) async throws -> BotCategoryState {
        throw BotAdminUnavailable()
    }
    public func setBotCategory(profile: String, categoryID: String?) async throws -> BotCategoryState {
        throw BotAdminUnavailable()
    }
    public func reorderBotCategories(ids: [String]) async throws -> BotCategoryState {
        throw BotAdminUnavailable()
    }
    public func credentialCards() async throws -> [CredentialCard] {
        throw BotAdminUnavailable()
    }
    public func answerCredentialCard(id: String, values: [String: String]) async throws {
        throw BotAdminUnavailable()
    }
    public func cancelCredentialCard(id: String) async throws {
        throw BotAdminUnavailable()
    }
    /// No bridge, no vault. Failing loudly is the point: an empty list here would read as "you have
    /// saved no secrets", which is the one thing this pane must never say by accident.
    public func vaultItems() async throws -> [VaultItem] { throw BotAdminUnavailable() }
    public func deleteVaultItem(name: String) async throws { throw BotAdminUnavailable() }
    public func editVaultItem(name: String, rename: String, value: String?) async throws {
        throw BotAdminUnavailable()
    }
    public func createCredentialCard(site: String, fields: [String], store: Bool,
                                     saveAs: String?, note: String?) async throws -> CredentialCard {
        throw BotAdminUnavailable()
    }
    public func integrations() async throws -> IntegrationsState {
        throw BotAdminUnavailable()
    }
    public func connectIntegration(slug: String, alias: String?) async throws -> String {
        throw BotAdminUnavailable()
    }
    public func renameIntegration(slug: String, accountID: String, alias: String) async throws {
        throw BotAdminUnavailable()
    }
    public func disconnectIntegration(slug: String, accountID: String?) async throws {
        throw BotAdminUnavailable()
    }
    public func searchTranscripts(_ query: String, limit: Int, offset: Int) async throws -> BotSearchPage {
        throw BotAdminUnavailable()
    }
    public func botTransfers(between first: String, and second: String, limit: Int) async throws -> [BotTransfer] {
        throw BotAdminUnavailable()
    }
    public func botDefaults() async throws -> BotDefaults { throw BotAdminUnavailable() }
    public func setDefaultSoul(_ text: String) async throws -> BotDefaults { throw BotAdminUnavailable() }
    public func exportBackup() async throws -> Data { throw BotAdminUnavailable() }
    public func exportBackupZip() async throws -> Data { throw BotAdminUnavailable() }
    public func importPrompt() async throws -> String { throw BotAdminUnavailable() }
    public func importBackup(_ file: Data, mode: BotImportMode, dryRun: Bool) async throws -> BackupImportResult {
        throw BotAdminUnavailable()
    }
    public func restoreBackup(_ document: Data) async throws -> BackupRestoreResult {
        throw BotAdminUnavailable()
    }
    public func registerPushRelay(_ url: String) async throws { throw BotAdminUnavailable() }
    public func reportPresence(bot: String?) async throws { throw BotAdminUnavailable() }
    public func sendTestPush() async throws { throw BotAdminUnavailable() }
    public func uploadPushIcon(bot: String, png: Data, sha256: String) async throws {
        throw BotAdminUnavailable()
    }
    public func saveNotes(_ text: String, for profile: String) async throws -> BotNotes {
        throw BotAdminUnavailable()
    }

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
    /// Every skill installed for this bot, with whether it is currently offered to it.
    public var skills: [ProfileSkill]
    /// Every MCP server configured for this bot, with whether it is currently started for it.
    public var mcpServers: [ProfileMCPServer]

    public init(name: String, description: String, soul: String,
                model: String? = nil, provider: String? = nil,
                skills: [ProfileSkill] = [], mcpServers: [ProfileMCPServer] = []) {
        self.name = name
        self.description = description
        self.soul = soul
        self.model = model
        self.provider = provider
        self.skills = skills
        self.mcpServers = mcpServers
    }
}

/// One skill as `profiles.describe` reports it: installed, and on unless it is in `skills.disabled`.
public struct ProfileSkill: Sendable, Equatable, Identifiable {
    public let name: String
    public var enabled: Bool
    public var id: String { name }

    public init(name: String, enabled: Bool) {
        self.name = name
        self.enabled = enabled
    }

    /// `grill-me` reads better than `grill-me` with a stray capital; the host's names are the ids.
    public var title: String {
        name.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

/// One MCP server as `profiles.describe` reports it. `transport` is `stdio` or `http`.
public struct ProfileMCPServer: Sendable, Equatable, Identifiable {
    public let name: String
    public var enabled: Bool
    public let transport: String
    public var id: String { name }

    public init(name: String, enabled: Bool, transport: String) {
        self.name = name
        self.enabled = enabled
        self.transport = transport
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

    /// A client with no skills hub reports none, rather than inventing a list.
    func availableSkills(profile: String) async throws -> [String] { [] }

    /// Same for the feature lists: a switch that did not reach the host must move back.
    func configureFeatures(profile: String, disabledSkills: [String]?,
                           enabledMCPServers: [String]?) async throws {
        _ = (profile, disabledSkills, enabledMCPServers)
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

    /// A host that does not page transcripts answers "nothing older", so the UI just has no
    /// "load earlier" row instead of failing the open.
    func historyPage(_ id: SessionID, profile: String?, cursor: Int, limit: Int) async throws -> HistoryPage {
        _ = (id, profile, cursor, limit)
        return .none
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

    /// A client that cannot ask the host which conversation a bot has says so — `.unavailable`, not
    /// `.absent`. The difference matters: `.absent` licenses minting a new one (which on a real host
    /// that does have a Bot Chat is how a client ends up with a second, competing conversation),
    /// while `.unavailable` sends the caller down the local-cache path exactly as this app behaved
    /// before the host's Bot Chat became the authority.
    func canonicalBotChat(forProfile profile: String) async throws -> CanonicalBotChat.HostState {
        _ = profile
        return .unavailable
    }

    func approvalSettings() async throws -> ApprovalSettings {
        throw BotAdminUnavailable()
    }

    func setApprovalMode(_ mode: ApprovalMode) async throws -> ApprovalSettings {
        throw BotAdminUnavailable()
    }

    func makePairingInvite() async throws -> PairingInvite {
        throw BotAdminUnavailable()
    }

    func modelSettings(_ profile: String) async throws -> BotModelSettings {
        _ = profile
        throw BotAdminUnavailable()
    }

    func setModelSettings(_ profile: String, effort: String?,
                          visionProvider: String?, visionModel: String?) async throws -> BotModelSettings {
        _ = (profile, effort, visionProvider, visionModel)
        throw BotAdminUnavailable()
    }

    /// A client that cannot rename cannot adopt. Loud rather than silent: the caller still opens the
    /// conversation and logs that it could not be made the canonical chat.
    func titleSession(_ session: SessionID, title: String, profile: String?) async throws {
        _ = (session, title, profile)
        throw GatewayError.rpc(RPCError(code: -32601,
                                        message: "session.title is not supported by this client"))
    }

    func archiveSession(_ session: SessionID, profile: String?) async throws {
        _ = (session, profile)
        throw GatewayError.rpc(RPCError(code: -32601,
                                        message: "session.archive is not supported by this client"))
    }

    func unarchiveSession(_ session: SessionID, profile: String?) async throws {
        _ = (session, profile)
        throw GatewayError.rpc(RPCError(code: -32601,
                                        message: "session.archive is not supported by this client"))
    }

    func setSessionHidden(_ hidden: Bool, session: SessionID, profile: String?) async throws {
        _ = (hidden, session, profile)
        throw GatewayError.rpc(RPCError(code: -32601,
                                        message: "session.set_hidden is not supported by this client"))
    }

    /// A client that cannot read a canonical row cannot check a ceiling. `nil` means "do not roll":
    /// the conversation keeps working exactly as it did before this feature existed.
    func botChatRow(profile: String) async throws -> BotChatRow? {
        _ = profile
        return nil
    }

    /// No canonical create: the plain one is the honest degradation.
    func createCanonicalSession(profile: String, idempotencyKey: String?) async throws -> SessionID {
        try await createSession(model: nil, provider: nil, profile: profile,
                                idempotencyKey: idempotencyKey)
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
    /// How many rows the host holds for this session.
    ///
    /// The difference that matters: a bot's store is full of untitled, zero-message sessions (stale
    /// drafts and orphans), so "newest" is regularly an empty conversation. Picking one of those is how
    /// a bot with 545 messages opened blank.
    public let messageCount: Int

    public init(id: SessionID, title: String, updatedAt: Date? = nil, preview: String? = nil,
                running: Bool = false, messageCount: Int = 0) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.preview = preview
        self.running = running
        self.messageCount = messageCount
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

/// One canonical row, as the host answers it, with the count the ceiling reads.
///
/// `count` is `live_message_count` when the host sends one — the display count, grouped the way a
/// transcript read groups its rows — and `message_count` only from a host too old to send it. See
/// `GatewayClientProtocol.botChatRow(profile:)` for why the two are not interchangeable.
public struct BotChatRow: Hashable, Sendable {
    public let id: SessionID
    public let count: Int

    public init(id: SessionID, count: Int) {
        self.id = id
        self.count = count
    }
}

public struct SessionResume: Sendable {
    /// The runtime id every session-scoped call needs.
    public let id: SessionID
    /// The durable key — the only value a later resume accepts.
    ///
    /// The runtime id is minted per attach and dies when the host's runtime goes away, so a device that
    /// remembered *it* asked the host about a session it no longer knew and was told "not found", then
    /// opened a blank conversation. `stored_session_id` is what the host keeps.
    public let storedSessionID: SessionID?
    public let entries: [TranscriptEntry]
    /// The turn still running that history does not hold yet.
    public let inflight: InflightTurn?
    /// Approvals/clarify questions still waiting for an answer.
    public let openRequests: [ServerRequest]
    /// Offset of `entries.first` in the host's transcript, and how many rows it holds in total.
    ///
    /// A long conversation is paged: the host ships only its newest page, and `earlierCursor`
    /// (nil when the page is the whole transcript) is what `historyPage` continues from. Both were
    /// added after a 3.4 MB resume frame made a bot chat unopenable on iOS.
    public let earlierCursor: Int?
    public let historyTotal: Int

    public init(id: SessionID, entries: [TranscriptEntry], inflight: InflightTurn?, openRequests: [ServerRequest],
                earlierCursor: Int? = nil, historyTotal: Int = 0, storedSessionID: SessionID? = nil) {
        self.id = id
        self.storedSessionID = storedSessionID
        self.entries = entries
        self.inflight = inflight
        self.openRequests = openRequests
        self.earlierCursor = earlierCursor
        self.historyTotal = historyTotal
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

/// One page of an older transcript, as the bridge serves it.
///
/// `cursor` is the offset of `entries.first` in the host's transcript, or nil when the page reached
/// the start of the conversation — the app renders a "load earlier" row until it is nil.
public struct HistoryPage: Sendable, Equatable {
    public let entries: [TranscriptEntry]
    public let cursor: Int?
    public let total: Int

    public init(entries: [TranscriptEntry], cursor: Int?, total: Int) {
        self.entries = entries
        self.cursor = cursor
        self.total = total
    }

    /// A host (or stub) with nothing older to give.
    public static let none = HistoryPage(entries: [], cursor: nil, total: 0)
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

    /// This row's stable message id, for anything the host keeps per message — a reaction, a card
    /// snapshot. A host row has one; a message still streaming has only its own id, and the two
    /// namespaces are kept apart so a live id can never collide with a durable one.
    ///
    /// The rule itself is ``ReactionKey/message(rowID:entryID:)``'s and nowhere else: a second
    /// spelling here is what let a row keyed `row:41` on one device be `row:41` but `live:…` on the
    /// other, so the badge was stored under a name nothing looked up.
    public var messageID: String {
        ReactionKey.message(rowID: rowID, entryID: id)
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
    /// A reaction another device set or cleared (`reaction.updated`), or the echo of this device's
    /// own write. The host owns reactions now, so this is how the other app hears about one
    /// without polling: `emoji` is `nil` when it was removed.
    ///
    /// `message` is the message half of ``ReactionKey`` (`row:41`, `live:r3`), which is what the
    /// host keys its store by; the receiver adds its own host/bot/session to look it up.
    case reactionUpdated(bot: String, session: SessionID, message: String, emoji: String?, by: String)
    /// A host-reported failure. `session` is the conversation the frame named — normalised to the
    /// stored id, and `""` when the frame named none — because one socket serves every bot the app
    /// opens: the app starts background sessions for other bots, and an error from one of those is
    /// not news about the pane the reader is looking at.
    case error(session: SessionID, code: Int?, message: String)
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

    /// A client with no bridge (the unpaired app, a preview, a test double) cannot resolve a card
    /// file, because the file lives on the host. Saying so is what draws `Card not available` under
    /// the reply; a spinner would be a lie about work that is not happening.
    func card(id: String, session: SessionID, message: String) async throws -> CardFetch {
        throw CardFetchError.unreachable("this connection has no bridge to read cards from")
    }

    /// No bridge, no host to agree with: reactions stay on this device, exactly as they did before
    /// the host owned them. This is the *unpaired* path, not a failure.
    var bridgeAvailable: Bool { false }

    /// An unpaired app cannot read the host's reactions. Answering `[:]` would be indistinguishable
    /// from "nobody has reacted", so this throws and `AppModel` keeps the local document.
    func reactions(bot: String, session: SessionID) async throws -> [String: Reaction] {
        throw ReactionSyncError.noBridge
    }

    func setReaction(bot: String, session: SessionID, message: String,
                     emoji: String?, by: String) async throws {
        _ = (bot, session, message, emoji, by)
        throw ReactionSyncError.noBridge
    }

    /// A client with no bridge cannot ask a bot anything. `.unreachable` is the honest refusal and
    /// the sentence the balloon already knows how to show.
    func askBot(profile: String, question: String, from: String, timeout: Double) async throws -> BotAnswer {
        _ = (profile, question, from, timeout)
        throw BotAskError.unreachable
    }
}
