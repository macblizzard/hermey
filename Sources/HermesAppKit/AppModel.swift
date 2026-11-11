#if canImport(Combine)
import Foundation
import Combine
import HermesKit
#if canImport(os)
import os
#endif

/// Shared application state for both apps.
///
/// One `AppModel` per window (macOS) or per app (iOS). It owns *what the user sees*:
/// the connection chip, the session list, the open transcript, the live approval.
/// It owns no sockets and no JSON — all of that is `GatewayClientProtocol`.
///
/// Ownership note: this file is the contract between the macOS and iOS screens. Add
/// to it freely; do not rename or remove members without updating both apps.
@MainActor
public final class AppModel: ObservableObject {

    // MARK: Connection

    public enum Connection: Equatable {
        case idle, connecting, connected, reconnecting(attempt: Int), failed(String), offline

        public var label: String {
            switch self {
            case .idle: return "not connected"
            case .connecting: return "connecting"
            case .connected: return "direct"
            case .reconnecting(let n): return "reconnecting (\(n))"
            case .failed(let why): return why
            case .offline: return "offline"
            }
        }

        public var isLive: Bool { self == .connected }
    }

    @Published public private(set) var connection: Connection = .idle
    @Published public private(set) var hostName: String = "hermes"
    /// Round-trip time of the last `ping`, for the connection chip.
    @Published public private(set) var latencyMS: Int?

    // MARK: Bots

    /// Every bot (Hermes profile) this host serves, in the host's own order.
    ///
    /// Empty until `loadBots()` succeeds. A host that predates `profiles.list` leaves this empty
    /// and the app falls back to one unscoped session list — degraded, but not broken.
    @Published public private(set) var bots: [Bot] = []
    @Published public private(set) var botsLoading = false
    /// The bot whose sessions and transcript are on screen. `nil` means "not chosen yet", which
    /// is also what an unscoped `session.list` means.
    @Published public private(set) var selectedBotID: String?
    /// Why the bot directory could not be read. The bot pane says so rather than "no bots".
    @Published public private(set) var botsError: String?

    // MARK: Sessions

    @Published public private(set) var sessions: [SessionSummary] = []
    @Published public private(set) var sessionsLoading = false
    @Published public var selectedSessionID: SessionID?
    /// Sessions this app created that the host has not persisted yet (see `newSession`).
    ///
    /// `session.create` deliberately writes no row until the first prompt, so a draft cannot be
    /// resumed: the host answers `4007 session not found` and the pane used to paint that as a
    /// dead host. Drafts are adopted locally and leave this set once `prompt.submit` has persisted
    /// the row.
    @Published public private(set) var draftSessionIDs: Set<SessionID> = []
    @Published public private(set) var transcript: [TranscriptEntry] = []
    /// Where "load earlier" continues from, and how many rows the whole conversation holds.
    ///
    /// A long conversation is paged: the host ships only its newest page, because one 3.4 MB
    /// `session.resume` frame is a message iOS refuses to deliver ("Message too long") and the bot
    /// chat then never opens. `earlierCursor` is nil when the transcript on screen is the whole
    /// conversation, so the UI only offers the row when there is something behind it.
    @Published public private(set) var earlierCursor: Int?
    @Published public private(set) var historyTotal = 0
    @Published public private(set) var loadingEarlier = false
    /// Bumped on every prepend, so a view can tell "older rows arrived" from "a new turn landed"
    /// and keep the reading position instead of jumping to the bottom.
    @Published public private(set) var earlierLoads = 0
    /// The row the reader was looking at when a page was prepended (the fold), for re-anchoring.
    @Published public private(set) var earlierAnchor: TranscriptEntry.ID?
    @Published public private(set) var runningSessions: Set<SessionID> = []

    // MARK: Live turn

    /// Text still streaming into the last assistant bubble.
    @Published public private(set) var streamingText: String = ""
    /// Turn/segment keys of the interim commentaries already written into the transcript, so a
    /// re-sent seal does not become a second bubble.
    private var sealedInterimKeys = Set<String>()
    @Published public private(set) var isStreaming = false

    /// The model's reasoning for the turn in flight, accumulated **separately** from the reply.
    ///
    /// `thinking.delta` is its own stream on the wire (`{"text"}` — plus an empty `{"text":""}`
    /// heartbeat while the model is still deliberating) and never appears in `message.delta`.
    /// Appending it to `streamingText` would print the model's notes inside the answer, which is
    /// why it was dropped instead of merged; dropping it left reasoning invisible.
    @Published public private(set) var reasoningText: String = ""

    /// Tools called during the turn on screen, in the order they started.
    ///
    /// `tool.start` and `tool.complete` are separate events and a turn can be interrupted between
    /// them, so a start with no matching complete stays `isRunning`. The cards are only *live*
    /// state: at the end of the turn they are flushed into `transcript` as `.tool` rows
    /// (`flushLiveTools`), which is what makes them survive the next resume and keeps them above
    /// the answer instead of under it.
    @Published public private(set) var liveTools: [LiveTool] = []

    public struct LiveTool: Identifiable, Equatable {
        /// `tool_id` from the wire — the identity `tool.complete` matches against.
        public let id: String
        public var name: String
        public var input: String
        public var output: String?
        public var isRunning: Bool
        public var durationMS: Int?

        public init(id: String,
                    name: String,
                    input: String = "",
                    output: String? = nil,
                    isRunning: Bool = true,
                    durationMS: Int? = nil) {
            self.id = id
            self.name = name
            self.input = input
            self.output = output
            self.isRunning = isRunning
            self.durationMS = durationMS
        }
    }

    // MARK: Model and context

    /// What the host says it is running, for the header chip.
    ///
    /// `model.options` names the running model at the top level (`model` + `provider`:
    /// `deepseek-v4.1-flash` / `opencode-go`); `providers[0].models[0]` is only the first entry of
    /// the menu, and on this host that is an Anthropic model the app was never using.
    @Published public private(set) var modelLabel: String?

    /// Tokens the context held after the last completed turn, and the window it is filling.
    @Published public private(set) var contextUsed: Int?
    @Published public private(set) var contextMax: Int?

    /// A compaction is running on the host. It is a real model turn, so the UI shows a quiet note
    /// rather than a spinner — and nothing may start a second one while it runs.
    @Published public private(set) var isCompressing = false
    /// One-line outcome of the last compaction, for the conversation header. Not an error, so it
    /// does not go in `lastSendError`.
    @Published public private(set) var compactionNotice: String?

    // MARK: Preferences

    /// Every one of these is persisted under its own key so the two apps and every window agree.
    @Published public var showReasoning: Bool {
        didSet { Self.defaults.set(showReasoning, forKey: Keys.showReasoning) }
    }
    /// Whether the chat draws a card for every command the bot runs — and the card's output with it.
    ///
    /// Off means the cards are not rows of the conversation at all. It used to hide only the body,
    /// which read as the switch doing nothing. The defaults key keeps its old name so an existing
    /// install's choice is honoured rather than silently reset.
    @Published public var showToolCalls: Bool {
        didSet { Self.defaults.set(showToolCalls, forKey: Keys.showToolCalls) }
    }
    /// Tokens at which a completed turn compacts the conversation. `0` disables it.
    @Published public var autoCompactTokens: Int {
        didSet { Self.defaults.set(autoCompactTokens, forKey: Keys.autoCompactTokens) }
    }

    /// 200k tokens: the point where a long conversation starts refusing turns, and early enough
    /// that the summary still fits comfortably behind the reply.
    public static let defaultAutoCompactTokens = 200_000

    enum Keys {
        static let showReasoning = "hermes.showReasoning"
        static let reasoningExpanded = "hermey.showReasoningExpanded"
        static let showToolCalls = "hermes.showToolOutput"
        static let autoCompactTokens = "hermes.autoCompactTokens"
        /// One stored session id per bot — the endless-chat contract (`docs/ENDLESS-CHAT.md` §2).
        static let endlessSessionPrefix = "hermes.endlessSession."
        /// The id this device reset, until something newer is published. The bridge's PUT has no
        /// "clear" (`bot_sessions.py`: a null is a 422, "never a delete"), so without this a reset
        /// device would adopt the very conversation it just forgot on its next open.
        static let endlessResetPrefix = "hermes.endlessSessionReset."
    }

    static let defaults = UserDefaults.standard

    // MARK: Questions the agent is blocked on

    @Published public private(set) var pendingRequests: [ServerRequest] = []

    /// True while a conversation is being resumed from the host and there is nothing to show yet.
    ///
    /// Switching bots used to clear the pane and then wait for a round trip, which the view painted
    /// as "Start the conversation with …" — a lie about a conversation that exists. This flag lets
    /// the pane say what is actually happening, and it is false the moment anything is on screen.
    @Published public private(set) var isOpeningConversation = false

    /// What a bot's conversation looked like the last time it was on screen.
    ///
    /// Switching bots has to clear everything the previous bot left behind (its transcript under
    /// another bot's name is worse than a blank pane), so the old behaviour was: wipe, then wait
    /// for `resumeSession` to answer — 1–2 s of an empty chat every single time, including going
    /// back to a conversation that was on screen five seconds earlier. Almost none of that state
    /// changed while it was away. Keeping one snapshot per bot turns the switch into a paint, with
    /// the round trip demoted to a silent refresh that replaces it when it lands.
    public struct ConversationSnapshot {
        public var sessionID: SessionID
        public var entries: [TranscriptEntry]
        public var earlierCursor: Int?
        public var historyTotal: Int
        public var openRequests: [ServerRequest]
        public var contextUsed: Int?
        public var contextMax: Int?
    }

    private var conversationCache: [String: ConversationSnapshot] = [:]
    /// Bots in the order they were last *left*, so the cache can shed the oldest instead of growing
    /// with every bot the user ever clicked. Eight transcripts of a few hundred rows is small;
    /// unbounded is not.
    private var conversationCacheOrder: [String] = []
    private static let conversationCacheLimit = 8

    // MARK: Composer

    /// Last message exchanged per bot, so the list can order by real activity rather than by
    /// whichever chat was merely opened. Persisted per host: it is a UI fact, not host state.
    @Published public private(set) var botActivity: [String: Date] = [:]
    /// The bot whose conversation is on screen right now; `nil` while the list is showing.
    @Published public private(set) var visibleBotID: String?
    /// Bots with a reply the user has not looked at yet. Local, like the rest of the list state.
    @Published public private(set) var unreadBots: Set<String> = []

    /// The first line of each bot's newest message, for the bot list's third line.
    ///
    /// Only the host knows this: a bot the user has not opened has no transcript on this device,
    /// and `session.list` answers a `preview` — the newest message, flattened. Keyed by bot id so
    /// a switch never shows one bot's line under another's name.
    @Published public private(set) var botPreviews: [String: String] = [:]

    /// How many turns each bot wrote after this device last looked at it.
    ///
    /// Absent and zero are the same thing: nothing waiting. The count comes from the host (it reads
    /// the profile's message table), so it survives the app being closed — a badge that only counted
    /// what this device happened to witness would be empty every morning.
    @Published public private(set) var unreadCounts: [String: Int] = [:]

    /// When each bot's newest message landed, by the host's clock. The list shows it beside the
    /// third line: without a time, "the brief from 06:30" and "the one from last Tuesday" look
    /// identical in a row that has room for one sentence.
    @Published public private(set) var botPreviewTimes: [String: Date] = [:]
    /// Hidden bots disappear from the list without touching the host: this is a view preference.
    @Published public private(set) var hiddenBots: Set<String> = []

    /// Bots the user pinned to the top of the list on this host. Like activity this is a UI
    /// preference, not host state, so it is persisted per host in UserDefaults. Several pins keep
    /// the host's order among themselves; anything unpinned stays in activity order.
    @Published public private(set) var pinnedBots: Set<String> = []

    @Published public var draft: String = ""
    /// Picked but not yet sent. Held locally so a cancelled composer leaves nothing on the host.
    @Published public private(set) var pendingAttachments: [PendingAttachment] = []
    @Published public private(set) var sending = false

    /// Set when a send failed, so the UI can offer "retry" instead of losing the draft.
    @Published public private(set) var lastSendError: String?

    private let client: GatewayClientProtocol
    private var eventTask: Task<Void, Never>?
    /// Bumped whenever the selected bot changes. An in-flight `session.list` compares it before
    /// publishing, so a slow answer for the bot we left cannot overwrite the bot we are on.
    private var botEpoch = 0

    public init(client: GatewayClientProtocol, hostName: String = "hermes") {
        self.client = client
        self.hostName = hostName
        // A default only applies to a key nobody wrote: `defaults.bool(forKey:)` answers `false`
        // for an unset key, which would ship reasoning and tool output hidden on first launch.
        let defaults = Self.defaults
        showReasoning = defaults.object(forKey: Keys.showReasoning) as? Bool ?? true
        reasoningExpandedByDefault = defaults.object(forKey: Keys.reasoningExpanded) as? Bool ?? false
        showToolCalls = defaults.object(forKey: Keys.showToolCalls) as? Bool ?? true
        autoCompactTokens = defaults.object(forKey: Keys.autoCompactTokens) as? Int
            ?? Self.defaultAutoCompactTokens
    }

    // MARK: Lifecycle

    /// Connect, then learn the bots, then read the selected bot's sessions.
    ///
    /// The order is the contract: every session row is scoped to one profile, so a list fetched
    /// before the bot is known would have to be thrown away (or worse, shown).
    public func start() async {
        connection = .connecting
        do {
            try await client.connect()
            connection = .connected
            await observeEvents()
            loadBotActivity()
            loadLastRead()
            loadRoomReadSeq()
            loadHiddenBots()
            loadPinnedBots()
            await loadBots()
            await loadModelLabel()
            await loadSessions()
        } catch {
            connection = .failed(error.localizedDescription)
            ClientLog.note("connect to \(hostName) failed: \(error.localizedDescription)",
                           level: .error, category: "connection")
        }
    }

    public func stop() async {
        eventTask?.cancel()
        eventTask = nil
        await client.disconnect()
        connection = .offline
    }

    // MARK: Sessions

    /// Read the bot directory (Hermes profiles) and settle on a default selection.
    ///
    /// Not fatal on failure: an older host answers `session.list` but not `profiles.list`, and one
    /// unscoped list is still better than a dead window. The reason is kept in `botsError` so the
    /// bot pane can say what happened instead of implying this host has no bots.
    public func loadBots() async {
        botsLoading = true
        defer { botsLoading = false }
        do {
            let loaded = try await client.listBots()
            bots = loaded
            botsError = nil
            if selectedBotID == nil || !loaded.contains(where: { $0.id == selectedBotID }) {
                selectedBotID = Self.defaultBot(in: loaded, hostName: hostName)?.id
            }
            // The bot list's third line belongs to the list, so it is loaded with the list: a
            // caller that only knows about `loadBots` (connect, a pull-to-refresh) still gets it,
            // which is exactly what the desktop app was missing.
            await loadBotPreviews()
        } catch {
            botsError = error.localizedDescription
            ClientLog.note("profiles.list failed: \(error.localizedDescription)",
                           level: .error, category: "bots")
        }
    }

    /// The bot to open with: the host name itself when it is also a profile (a host paired as
    /// `assistant` should land on `assistant`), otherwise the first bot the host listed.
    static func defaultBot(in bots: [Bot], hostName: String) -> Bot? {
        let wanted = hostName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return bots.first { $0.id.lowercased() == wanted || $0.name.lowercased() == wanted }
            ?? bots.first
    }

    /// The selected bot's sessions.
    ///
    /// `includeHidden` is deliberately not exposed here: on this backend a normal profile returns
    /// zero rows without it, so a bots surface that omits it shows every bot as empty.
    public func loadSessions() async {
        let bot = selectedBotID
        let epoch = botEpoch
        sessionsLoading = true
        defer { if epoch == botEpoch { sessionsLoading = false } }
        do {
            let loaded = try await client.listSessions(limit: 50, profile: bot, includeHidden: true)
            // Rows requested for the bot we have since left are *another bot's* sessions. Landing
            // them under this name is exactly the mix the switcher exists to prevent.
            guard epoch == botEpoch else { return }
            sessions = loaded
        } catch {
            guard epoch == botEpoch else { return }
            // A silent gateway must not look like "no sessions" — surface it.
            connection = .failed("could not load sessions: \(error.localizedDescription)")
            ClientLog.note("session.list failed for \(bot ?? "no profile"): \(error.localizedDescription)",
                           level: .error, category: "sessions")
        }
    }

    /// Fill in the bot list's preview lines, one `session.list` per bot.
    ///
    /// Cheap only if it stays lazy and bounded: bots already cached are skipped, and four calls
    /// are in flight at a time. On a host with fifteen profiles a serial sweep is fifteen round
    /// trips deep before the list stops being two lines per row, and a cold profile can take
    /// seconds to answer its first `session.list`.
    public func loadBotPreviews(force: Bool = false) async {
        let ids = bots.map(\.id)
        guard !ids.isEmpty else { return }

        // First source: the bridge, which reads the host's own message table and answers every
        // bot in one request. It is the *newest* message whatever role wrote it — the gateway's
        // `session.list` preview is the first **user** message of the session (a title stand-in),
        // which is why a row built from it repeated the opening request for days.
        var covered: Set<String> = []
        // The marks travel with the request: the host counts what it wrote after them, in the same
        // read that produces the third line. A bot this device has never opened has no mark, and
        // `noteRemoteActivity` seeds one on first sight — so a fresh install does not badge every
        // row (the same rule the unread dot already follows).
        let marks: [String: Double] = lastRead.reduce(into: [:]) { into, pair in
            if ids.contains(pair.key) { into[pair.key] = pair.value.timeIntervalSince1970 }
        }
        let feed = (try? await client.botPreviews(since: marks)) ?? BotPreviewFeed()
        unreadCounts = feed.unread.filter { ids.contains($0.key) }
        let fromBridge = feed.previews
        if !fromBridge.isEmpty {
            for (bot, preview) in fromBridge where ids.contains(bot) {
                covered.insert(bot)
                if let line = Self.previewLine(preview.text) { botPreviews[bot] = line }
                // The host's own timestamp for the newest message, so both devices order the list
                // the same way. Ordering by local activity meant a reply read on the phone never
                // moved that bot up on the Mac.
                if let at = Self.seconds(preview.timestamp) {
                    recordActivity(for: bot, at: at)
                    noteRemoteActivity(for: bot, at: at)
                    botPreviewTimes[bot] = at
                }
            }
        }

        // Second source, for the bots the bridge did not cover (an older bridge, or a profile with
        // no conversation row yet): the gateway's coarse preview, which is still better than an
        // empty third line.
        let wanted = ids.filter { !covered.contains($0) && (force || botPreviews[$0] == nil) }
        guard !wanted.isEmpty else { return }
        let client = self.client
        let batch = 4
        var start = 0
        while start < wanted.count {
            let chunk = Array(wanted[start ..< min(start + batch, wanted.count)])
            start += batch
            await withTaskGroup(of: (String, SessionSummary?).self) { group in
                for bot in chunk {
                    group.addTask {
                        let rows = try? await client.listSessions(limit: 1,
                                                                 profile: bot,
                                                                 includeHidden: true)
                        return (bot, rows?.first)
                    }
                }
                for await (bot, row) in group {
                    guard let row else { continue }
                    // A bot that answers nothing keeps whatever it had: absence is not "empty".
                    if let line = Self.previewLine(row.preview) { botPreviews[bot] = line }
                    if let at = row.updatedAt {
                        recordActivity(for: bot, at: at)
                        noteRemoteActivity(for: bot, at: at)
                        botPreviewTimes[bot] = at
                    }
                }
            }
        }
    }

    /// Retry a dropped connection without losing the open session.
    public func retryConnection() async {
        let previous = selectedSessionID
        await start()
        if let previous, sessions.contains(where: { $0.id == previous }) {
            await select(previous)
        }
    }

    /// A host timestamp as a `Date`. Hosts write epoch seconds; a value that large in milliseconds
    /// is a different schema, not a date in the year 57000, so it is normalised here rather than
    /// trusted.
    static func seconds(_ raw: Double?) -> Date? {
        guard let raw, raw > 0 else { return nil }
        let value = raw > 100_000_000_000 ? raw / 1000 : raw
        return Date(timeIntervalSince1970: value)
    }

    /// The one line a bot row has room for: first non-blank line, clipped.
    public static func previewLine(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line, !line.isEmpty else { return nil }
        return String(line.prefix(120))
    }

    /// Switch bots.
    ///
    /// Everything on screen belongs to the bot it came from — the transcript, the pending
    /// questions, the half-streamed turn, the running set — so all of it is dropped *before* the
    /// new bot's list is fetched. A failed load therefore leaves an empty pane, never the previous
    /// bot's conversation under the new bot's name.
    public func selectBot(_ id: String?) async {
        let resolved = id ?? Self.defaultBot(in: bots, hostName: hostName)?.id
        guard resolved != selectedBotID else {
            await loadSessions()
            return
        }
        captureConversation(for: selectedBotID)
        resetForBotSwitch()
        selectedBotID = resolved
        // Picking a bot is picking a different conversation: the room it is replacing must not come
        // back when the next launch restores the pane.
        activeRoom = nil
        if let resolved { restoreConversation(for: resolved) }
        await loadSessions()
    }

    /// Remember what is on screen for the bot being left.
    ///
    /// Called before anything is cleared: at this point `transcript` still holds the rows the user
    /// was reading, which is exactly what should come back instantly on a return visit.
    func captureConversation(for botID: String?) {
        guard let botID, let sessionID = selectedSessionID, !transcript.isEmpty else { return }
        conversationCache[botID] = ConversationSnapshot(sessionID: sessionID,
                                                       entries: transcript,
                                                       earlierCursor: earlierCursor,
                                                       historyTotal: historyTotal,
                                                       openRequests: pendingRequests,
                                                       contextUsed: contextUsed,
                                                       contextMax: contextMax)
        conversationCacheOrder.removeAll { $0 == botID }
        conversationCacheOrder.append(botID)
        while conversationCacheOrder.count > Self.conversationCacheLimit {
            conversationCache.removeValue(forKey: conversationCacheOrder.removeFirst())
        }
    }

    /// Put a remembered conversation back on screen, before any network call is made.
    @discardableResult
    func restoreConversation(for botID: String) -> Bool {
        guard let snapshot = conversationCache[botID] else { return false }
        selectedSessionID = snapshot.sessionID
        transcript = snapshot.entries
        earlierCursor = snapshot.earlierCursor
        historyTotal = snapshot.historyTotal
        pendingRequests = snapshot.openRequests
        contextUsed = snapshot.contextUsed
        contextMax = snapshot.contextMax
        return true
    }

    private func resetForBotSwitch() {
        botEpoch += 1
        selectedSessionID = nil
        // Drafts are scoped to the bot that created them (a draft has no profile on the host yet).
        draftSessionIDs = []
        sessions = []
        transcript = []
        earlierCursor = nil
        historyTotal = 0
        loadingEarlier = false
        earlierAnchor = nil
        streamingText = ""
        reasoningText = ""
        liveTools = []
        isStreaming = false
        runningSessions = []
        pendingRequests = []
        contextUsed = nil
        contextMax = nil
        compactionNotice = nil
        sending = false
        lastSendError = nil
    }

    public func select(_ id: SessionID) async {
        selectedSessionID = id
        transcript = []
        earlierCursor = nil
        historyTotal = 0
        turnRowStart = 0
        streamingText = ""
        reasoningText = ""
        liveTools = []
        isStreaming = false
        contextUsed = nil
        contextMax = nil
        pendingRequests = []
        // A draft has no row on the host yet: resuming it answers 4007 "session not found", which
        // used to be painted as an unreachable host. Its pane is empty by definition, so adopt it
        // locally and let the first prompt persist the row — the next select is a real resume.
        if draftSessionIDs.contains(id) { return }
        // A resume that is still in flight when the bot (or the session) changes must not land:
        // it carries the transcript of the thing the user just left.
        let epoch = botEpoch
        do {
            let resumed = try await client.resumeSession(id, profile: selectedBotID)
            guard epoch == botEpoch, selectedSessionID == id else { return }
            transcript = SentAttachmentVault.decorate(resumed.entries, sessionID: id)
            earlierCursor = resumed.earlierCursor
            historyTotal = resumed.historyTotal
            pendingRequests = resumed.openRequests
            adopt(resumed, session: id)
        } catch is CancellationError {
            // SwiftUI cancels the `.task` when the screen goes away — backgrounding, the app
            // switcher, a pushed sheet. That is not a failed session, and surfacing it painted a
            // red "could not open this session" banner every time the user came back.
            return
        } catch {
            guard epoch == botEpoch, selectedSessionID == id else { return }
            // A session that cannot be opened is not a dead host: the socket is fine, and blaming
            // the connection here painted "cannot connect to the server" over a session-level
            // error (and then suppressed the reconnect that would have fixed a real drop).
            lastSendError = "could not open this session: \(error.localizedDescription)"
            ClientLog.note("session.resume failed for \(id): \(error.localizedDescription)",
                           level: .error, category: "session")
        }
    }

    /// Adopt the host's answer about the turn that was in flight.
    ///
    /// The resume is the authority, not this client's own flag: a turn that finished while the
    /// socket was down leaves no `message.complete` to receive, so an app that kept streaming set
    /// waited forever — observed as "stuck on Thinking…" with the finished reply on the host.
    /// `inflight == nil` and `streaming: false` both mean nothing more is coming; a non-streaming
    /// inflight still carries its partial text, so the bubble keeps what the model already wrote.
    private func adopt(_ resumed: SessionResume, session: SessionID) {
        streamingText = resumed.liveText
        isStreaming = resumed.isStreaming
        reasoningText = ""
        liveTools = []
        if resumed.isStreaming {
            runningSessions.insert(session)
        } else {
            runningSessions.remove(session)
        }
    }

    // MARK: Turn

    /// Re-derive state after a reconnect without destroying a turn that is still arriving.
    ///
    /// iOS closes the socket whenever the app leaves the foreground (close code 1001), so `ready`
    /// fires often — several times per session. The host is the authority, but replacing the view
    /// unconditionally meant a reply that had already been received disappeared the moment the user
    /// came back, leaving "thinking" on screen with the answer on the host.
    ///
    /// Idle: just re-select. Mid-turn: give the socket's replay (`session.events.since`) a beat,
    /// then adopt the host's view *without* discarding locally received text.
    private func reconcile(afterReconnect sid: SessionID) async {
        guard !isStreaming else {
            let localText = streamingText
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard selectedSessionID == sid else { return }
            guard let resumed = try? await client.resumeSession(sid, profile: selectedBotID) else { return }
            guard selectedSessionID == sid else { return }

            if resumed.inflight?.streaming == true {
                // Still running on the host: keep what we have, adopt its partial text only when
                // ours is empty (we may have missed the deltas that arrived while suspended).
                if streamingText.isEmpty { streamingText = resumed.inflight?.assistantText ?? "" }
                isStreaming = true
                return
            }

            // Nothing is running, so nothing more is coming. Anything we already hold is the answer:
            // the host may not have persisted it yet, and dropping it is the bug this method exists
            // to prevent.
            var entries = resumed.entries
            if !localText.isEmpty,
               !entries.contains(where: { $0.role == .assistant && $0.text == localText }) {
                entries.append(TranscriptEntry(id: "recovered-\(sid)-\(entries.count)", role: .assistant, text: localText))
            }
            transcript = SentAttachmentVault.decorate(entries, sessionID: sid)
            earlierCursor = resumed.earlierCursor
            historyTotal = resumed.historyTotal
            pendingRequests = resumed.openRequests
            streamingText = ""
            reasoningText = ""
            liveTools = []
            isStreaming = false
            runningSessions.remove(sid)
            return
        }
        await select(sid)
    }

    public func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // An attachment on its own is a complete message: a PDF with no comment is a normal thing
        // to send, and refusing it here made "attach a file, tap send" look like a dead button.
        guard let sid = selectedSessionID, !sending,
              !text.isEmpty || !pendingAttachments.isEmpty else { return }
        let attachedNames = pendingAttachments.map(\.name)
        // The bubble draws what was sent: the host's transcript carries no attachment metadata, so
        // this list is the only thing that can put a picture in the chat.
        let sentAttachments = pendingAttachments.map { attachment in
            SentAttachment(name: attachment.name,
                           isImage: attachment.isImage,
                           imageData: attachment.isImage ? attachment.data : nil)
        }
        sending = true
        lastSendError = nil
        draft = ""
        if let bot = selectedBotID { recordActivity(for: bot) }

        // Attachments are uploaded *before* the turn so a failure cannot leave a phantom message
        // in the transcript, and so a file's `@file:` reference can travel in the same prompt.
        var refs: [String] = []
        if !pendingAttachments.isEmpty {
            do {
                for attachment in pendingAttachments {
                    let receipt = try await client.attach(session: sid, name: attachment.name,
                                                          data: attachment.data,
                                                          isImage: attachment.isImage)
                    if let ref = receipt.refText { refs.append(ref) }
                    if attachment.isImage {
                        // The transcript will quote the host's own path back, so the picture is
                        // cached under that name — the one handle both sides agree on after a
                        // relaunch, with no guessing by message text.
                        AttachmentImageStore.save(attachment.data, as: receipt.path ?? attachment.name)
                    }
                }
                pendingAttachments = []
            } catch {
                sending = false
                lastSendError = error.localizedDescription
                ClientLog.note("send with attachments failed: \(error.localizedDescription)",
                               level: .error, category: "send")
                draft = text
                return // keep both the words and the attachments: nothing was sent
            }
        }
        var outgoing = text.isEmpty
            ? refs.joined(separator: "\n")
            : (refs.isEmpty ? text : refs.joined(separator: "\n") + "\n\n" + text)

        // A reply quotes what it answers, in the form every markdown reader knows.
        if let reply = replyTarget {
            let quoted = reply.snippet
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }
                .joined(separator: "\n")
            outgoing = "\(quoted)\n\n" + outgoing
            replyTarget = nil
        }

        // A message typed while a turn is running goes to the host as a mid-turn prompt: its busy
        // policy decides whether this steers the running turn, redirects it, or runs after it. What
        // must NOT happen is the client pretending a new turn started — that used to wipe the live
        // answer and the tool cards on screen.
        let isMidTurn = isStreaming && runningSessions.contains(sid)
        let optimisticID = UUID().uuidString

        // An interrupted turn leaves its cards live; they belong to that turn, above this message.
        if !isMidTurn { flushLiveTools() }
        // The bubble shows what the user typed; an attachment-only send names its files instead of
        // rendering an empty row.
        let bubbleText = text.isEmpty ? attachedNames.joined(separator: ", ") : text
        transcript.append(TranscriptEntry(id: optimisticID, role: .user, text: bubbleText,
                                          at: Date(), attachments: sentAttachments))
        // Remembered for the next launch: a transcript reloaded from the host has no pictures.
        SentAttachmentVault.record(sessionID: sid, text: bubbleText, attachments: sentAttachments)
        if !isMidTurn {
            streamingText = ""
            reasoningText = ""
            compactionNotice = nil
            isStreaming = true
            runningSessions.insert(sid)
        }
        do {
            let delivery = try await client.submit(session: sid, text: outgoing)
            if isMidTurn { announce(delivery) }
            // The first prompt is what persists a draft into a real row, so from now on this
            // session resumes like any other.
            draftSessionIDs.remove(sid)
        } catch {
            if !isMidTurn { isStreaming = false }
            lastSendError = error.localizedDescription
            ClientLog.note("prompt.submit failed: \(error.localizedDescription)",
                           level: .error, category: "send")
            draft = text // never lose what the user typed
            // By id, not by position: switching bots or sessions while the submit was in flight
            // empties the transcript, and a blind `removeLast()` would trap on it.
            transcript.removeAll { $0.id == optimisticID }
        }
        sending = false
    }

    /// Say what the host did with a mid-turn message, in the composer's own words, then let it go.
    private func announce(_ delivery: TurnDelivery) {
        let text: String
        switch delivery {
        case .steered: text = "Steered into the turn that is running"
        case .redirected: text = "The running turn is being redirected to this"
        case .queued: text = "Queued — it runs as soon as this turn ends"
        case .streaming, .unknown: text = "Sent — joining the turn that is running"
        }
        deliveryNotice = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if self?.deliveryNotice == text { self?.deliveryNotice = nil }
        }
    }

    // MARK: Attachments

    /// A picked attachment, held on the device until the user actually sends.
    ///
    /// Nothing is uploaded at pick time: a cancelled composer or a failed send must not leave an
    /// image queued on the host for a turn that never happened.
    /// The message a reply is anchored to. Quoted into the prompt on send, so the host — and the
    /// model — see which "this" the reply is about instead of guessing from adjacency.
    public struct ReplyTarget: Identifiable, Equatable, Sendable {
        public let id: String
        public let author: String
        public let snippet: String
    }

    @Published public var replyTarget: ReplyTarget?

    public func reply(to entry: TranscriptEntry) {
        let author = entry.role == .user ? "you" : (bots.first { $0.id == selectedBotID }?.displayName ?? "Hermes")
        let body = entry.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = body.count > 240 ? String(body.prefix(240)) + "…" : body
        replyTarget = ReplyTarget(id: entry.id, author: author, snippet: snippet)
    }

    public func clearReply() { replyTarget = nil }

    /// What the host did with a message sent while a turn was running, said in words the composer
    /// can show. Cleared on its own — it is an acknowledgement, not a state.
    @Published public var deliveryNotice: String?

    public func clearDeliveryNotice() { deliveryNotice = nil }

    public struct PendingAttachment: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let isImage: Bool
        public let data: Data

        public init(id: UUID = UUID(), name: String, isImage: Bool, data: Data) {
            self.id = id
            self.name = name
            self.isImage = isImage
            self.data = data
        }
    }

    /// How many files may wait in the composer before the next pick is refused.
    public static let maxPendingAttachments = 8

    /// The client's byte limit for one attachment, in sync with
    /// `AttachmentBudget.maximumBytes` in the phone app (8 MiB decoded, which encodes to
    /// ~10.7 MiB and fits one 16 MiB websocket frame). The modules cannot share the symbol,
    /// so the number is duplicated here on purpose — change all three together.
    public static let maxAttachmentBytes = 8 * 1024 * 1024

    public func addPendingAttachment(name: String, data: Data, isImage: Bool) {
        guard !data.isEmpty else {
            lastSendError = "That attachment is empty."
            return
        }
        guard data.count <= Self.maxAttachmentBytes else {
            lastSendError = "That attachment is larger than the 8 MB limit."
            return
        }
        // Eight is the point past which the composer bar becomes a wall and the prompt a pile of
        // references; refusing with a sentence beats silently dropping the seventh pick.
        guard pendingAttachments.count < Self.maxPendingAttachments else {
            lastSendError = "Eight attachments at a time — send these first."
            return
        }
        pendingAttachments.append(PendingAttachment(name: name, isImage: isImage, data: data))
    }

    public func removePendingAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    public func interrupt() async {
        guard let sid = selectedSessionID else { return }
        try? await client.interrupt(session: sid)
    }

    // MARK: Sessions (macOS workspace additions)

    /// Start a fresh session on the host and open it.
    ///
    /// The list is reloaded *before* selecting so the new row exists in the sidebar by the
    /// time the conversation pane switches to it.
    public func newSession(model: String? = nil, provider: String? = nil) async {
        sessionsLoading = true
        defer { sessionsLoading = false }
        do {
            let created = try await client.createSession(model: model, provider: provider, profile: selectedBotID)
            // `session.create` mints a **draft**: the gateway deliberately writes no row until the
            // first prompt (so abandoned launches do not litter "Untitled" sessions). A draft is
            // therefore not resumable — `session.resume` answers 4007 "session not found" — and the
            // create reply is already everything the pane needs. Adopt it instead of selecting it,
            // which used to fire that resume and paint "could not resume session" as a dead host.
            draftSessionIDs.insert(created)
            selectedSessionID = created
            transcript = []
            streamingText = ""
            isStreaming = false
            pendingRequests = []
            lastSendError = nil
            sessions = try await client.listSessions(limit: 50, profile: selectedBotID, includeHidden: true)
        } catch {
            lastSendError = "could not start a session: \(error.localizedDescription)"
            ClientLog.note("session.create failed: \(error.localizedDescription)",
                           level: .error, category: "session")
        }
    }

    /// True while a created session has no row on the host yet (see `newSession`).

    // MARK: Endless conversation

    /// The one conversation this bot has: resume it, or start and remember one.
    ///
    /// The pointer is **shared**, not per device. `hermes.endlessSession.<botID>` is only this
    /// device's cache now; the authority is the bridge's per-bot pointer
    /// (`GET`/`PUT /v1/bots/{profile}/session`), so the phone and the Mac open the same stored
    /// session instead of each minting its own. The order is:
    ///
    /// 1. ask the bridge for this bot's stored id — it is the shared answer and beats a stale
    ///    local key;
    /// 2. no host value: resume the locally known id and publish it, so the other device adopts it;
    /// 3. neither: create, then publish the new stored id.
    ///
    /// Every bridge call fails open. An unreachable or older bridge leaves this device on its own
    /// cache: opening a conversation is never blocked on the pointer, nothing about the sync leg
    /// lands in `lastSendError`, and a failed publish is logged only (the other device keeps its
    /// id until the next successful write).
    ///
    /// A stored id stays resumable until the host forgets the session: `4001` is "session not
    /// found" and `4007` is the same for an id from another profile, and only those two justify
    /// opening a new conversation. Any other failure (a timeout, a dead socket) is reported
    /// instead — starting a blank conversation over a transient error would hide the user's
    /// history behind a new empty one.
    public func endlessSession(for botID: String) async -> SessionID? {
        if botID != selectedBotID {
            // The transcript, tools and streaming state on screen belong to the bot being left —
            // but they are worth keeping first: a return visit paints from the snapshot and lets
            // the resume below refresh it, instead of starting from an empty pane.
            captureConversation(for: selectedBotID)
            resetForBotSwitch()
            selectedBotID = botID
        }
        // Cached, so the pane has something the instant it is asked; nothing cached means the
        // resume is the first thing that will exist, and the pane should say "opening", not
        // "start the conversation".
        isOpeningConversation = !restoreConversation(for: botID)
        defer { isOpeningConversation = false }
        await loadModelLabel()
        let key = Self.endlessKey(botID)
        let plan = EndlessSessionPolicy.plan(host: await sharedSessionPointer(for: botID),
                                             local: Self.defaults.string(forKey: key))
        if let stored = plan.resumedID {
            do {
                let resumed = try await client.resumeSession(stored, profile: botID)
                selectedSessionID = stored
                transcript = SentAttachmentVault.decorate(resumed.entries, sessionID: stored)
                earlierCursor = resumed.earlierCursor
                historyTotal = resumed.historyTotal
                pendingRequests = resumed.openRequests
                adopt(resumed, session: stored)
                captureConversation(for: botID)
                // Whatever actually opened is the best cache this device can keep — including a
                // host id that replaced a different local one.
                Self.defaults.set(stored, forKey: key)
                if plan.publish {
                    await publishSharedSession(stored, for: botID)
                }
                return stored
            } catch is CancellationError {
                // Leaving the screen cancels the open-in-flight; the next visit resumes normally.
                return nil
            } catch {
                // Only a session the host has forgotten is worth replacing; a timeout or a dead
                // socket must be reported, never papered over with a new empty conversation.
                guard let gateway = error as? GatewayError, Self.isForgottenSession(gateway) else {
                    lastSendError = "could not open the conversation: \(error.localizedDescription)"
                    ClientLog.note("resume of the stored session failed: \(error.localizedDescription)",
                                   level: .error, category: "session")
                    return nil
                }
                // Forget it locally too, so an offline open does not retry a dead id.
                Self.defaults.removeObject(forKey: key)
            }
        }
        do {
            // `createSession` answers with the **stored** id, which is what a later resume needs.
            // The idempotency key is per bot, so two devices opening it at the same moment converge
            // on one session instead of forking before either has published anything.
            let created = try await client.createSession(model: nil, provider: nil, profile: botID,
                                                         idempotencyKey: "bot-chat:\(botID)")
            Self.defaults.set(created, forKey: key)
            // The row does not exist until the first prompt, so this is a draft: mark it before
            // `select`, whose resume would otherwise answer 4007 and report an unreachable host.
            draftSessionIDs.insert(created)
            await select(created)
            // Always published: a conversation this device just minted cannot already be the
            // bridge's answer (anything it held was absent or proven dead), and the other device
            // needs it to converge.
            await publishSharedSession(created, for: botID)
            return created
        } catch {
            lastSendError = "could not start a conversation: \(error.localizedDescription)"
            ClientLog.note("session.create for \(botID) failed: \(error.localizedDescription)",
                           level: .error, category: "session")
            return nil
        }
    }

    /// Forget this bot's conversation so the next open starts a new one.
    ///
    /// Only the stored id is cleared: the session itself stays on the host, because deleting
    /// history is not what "reset" on this screen means (and the host refuses to delete a session
    /// it still holds live). The clear is published to the bridge as well — otherwise the other
    /// device would keep reopening the conversation, and the next open here would adopt it back
    /// from the host.
    public func resetEndlessSession(for botID: String) {
        let key = Self.endlessKey(botID)
        let stored = Self.defaults.string(forKey: key)
        Self.defaults.removeObject(forKey: key)
        // Remember what was forgotten: the bridge route cannot clear its row, so without this the
        // next open would read the same id back and reopen the conversation the user just dropped.
        if let stored, !stored.isEmpty {
            Self.defaults.set(stored, forKey: Self.resetKey(botID))
        }
        // Fire-and-forget, after the local state is settled: this device is reset even if the
        // bridge never hears about it (a failure only means the other device has to reset too).
        Task { await publishSharedSession(nil, for: botID) }
        guard let stored, selectedSessionID == stored else { return }
        // The conversation on screen is the one just forgotten: leaving its bubbles up would let
        // the user keep typing into a session nothing will reopen.
        conversationCache.removeValue(forKey: botID)
        conversationCacheOrder.removeAll { $0 == botID }
        selectedSessionID = nil
        transcript = []
        pendingRequests = []
        streamingText = ""
        reasoningText = ""
        liveTools = []
        isStreaming = false
        contextUsed = nil
        contextMax = nil
        compactionNotice = nil
        runningSessions.remove(stored)
    }

    /// A menu's "reset conversation": forget the bot's conversation and open a fresh one at once.
    ///
    /// `resetEndlessSession` on its own leaves an empty pane — no transcript, and a composer that
    /// cannot send until something opens a session — so a menu that only cleared would look like
    /// the app had lost the conversation instead of starting a new one. The old session stays on
    /// the host, because deleting history is not what "reset" means here.
    /// Whether compact / reset can run. Both act on the open *bot*'s conversation, and neither
    /// makes sense mid-turn — which is the whole condition, said once.
    public var canActOnConversation: Bool { !isStreaming && selectedBotID != nil }

    /// The model's reasoning, expanded on arrival instead of waiting for a click.
    @Published public var reasoningExpandedByDefault: Bool {
        didSet { Self.defaults.set(reasoningExpandedByDefault, forKey: Keys.reasoningExpanded) }
    }

    public func resetConversation() async {
        guard let bot = selectedBotID else { return }
        resetEndlessSession(for: bot)
        _ = await endlessSession(for: bot)
        await loadBotPreviews(force: true)
    }

    /// What the bridge says this bot's conversation is, normalised for `EndlessSessionPolicy`.
    ///
    /// Never throws: a read the client cannot make is `.unavailable`, which sends the open down the
    /// local-cache path. An unusable value (empty, whitespace, a path separator) is treated as
    /// `.absent` so it is repaired by a publish rather than passed to `session.resume`.
    private func sharedSessionPointer(for botID: String) async -> EndlessSessionPointerState {
        do {
            guard let raw = try await client.sharedSessionID(forBot: botID) else { return .absent }
            guard let stored = EndlessSessionPolicy.storedID(raw) else {
                Self.noteSessionSync("bridge returned an unusable stored session id for “\(botID)”; using the local cache")
                return .absent
            }
            // A conversation this device reset must not come straight back from the bridge. The id
            // is only ignored while it is exactly the one forgotten: a newer session created on the
            // other device is adopted normally.
            if Self.defaults.string(forKey: Self.resetKey(botID)) == stored {
                Self.noteSessionSync("ignoring the bridge's conversation for “\(botID)”: this device reset it")
                return .absent
            }
            return .value(stored)
        } catch {
            Self.noteSessionSync("could not read the shared conversation for “\(botID)”: \(error.localizedDescription); using the local cache")
            return .unavailable
        }
    }

    /// Best-effort write of the shared pointer. Failures are logged and swallowed: the local key is
    /// already correct, so this device stays consistent, and blocking here would trade a working
    /// conversation for a sync error.
    private func publishSharedSession(_ id: SessionID?, for botID: String) async {
        do {
            try await client.publishSharedSessionID(id, forBot: botID)
            // A published id is the new shared answer, so the reset tombstone has done its job.
            if let id, !id.isEmpty {
                Self.defaults.removeObject(forKey: Self.resetKey(botID))
            }
        } catch {
            Self.noteSessionSync("could not publish the shared conversation for “\(botID)”: \(error.localizedDescription)")
        }
    }

    /// Diagnostics for the shared-pointer leg only — deliberately not `lastSendError`, because a
    /// bridge that cannot be reached must not put an error in front of a conversation that opened
    /// fine.
    private static func noteSessionSync(_ message: String) {
        #if canImport(os)
        sessionSyncLog.notice("\(message, privacy: .public)")
        #else
        print("endless-session: \(message)")
        #endif
    }

    #if canImport(os)
    private static let sessionSyncLog = Logger(subsystem: "hermes.apps", category: "endless-session")
    #endif

    // MARK: Compaction

    /// Compact the open conversation now (the header's affordance and the automatic trigger).
    ///
    /// `session.compress` rewrites the stored transcript and answers with no messages, so the only
    /// way to show the result is a fresh resume — hence the re-select, which also reconnects the
    /// transcript to whatever the host decided to keep.
    public func compressNow() async {
        guard !isCompressing else { return }
        // A bot whose conversation has not been opened in this process has no session id yet.
        // Compacting is a verb on that conversation, so it opens it rather than staying greyed out.
        if selectedSessionID == nil, let bot = selectedBotID {
            _ = await endlessSession(for: bot)
        }
        guard let sid = selectedSessionID else { return }
        isCompressing = true
        defer { isCompressing = false }
        do {
            try await client.compress(session: sid)
            // Refresh first, then report: the notice is set last so nothing inside the refresh can
            // overwrite it, and the context gauge is cleared because it showed the *pre*-compaction
            // size. The next turn's `usage` is the first honest number after a compaction.
            await select(sid)
            contextUsed = nil
            compactionNotice = "conversation compacted"
        } catch {
            lastSendError = "could not compact: \(error.localizedDescription)"
            ClientLog.note("session.compress failed: \(error.localizedDescription)",
                           level: .error, category: "compaction")
        }
    }

    /// Compact once the host reports the context at (or past) the threshold.
    ///
    /// The threshold is in absolute tokens, from `usage.context_used` on `message.complete`; `0`
    /// disables it. It is checked *after* a turn, never in a loop: a compaction cannot itself
    /// complete a turn, and `isCompressing` refuses a second one while the first is running.
    private func autoCompactIfNeeded() async {
        guard autoCompactTokens > 0, !isCompressing,
              let used = contextUsed, used >= autoCompactTokens
        else { return }
        await compressNow()
    }

    private static func endlessKey(_ botID: String) -> String {
        Keys.endlessSessionPrefix + botID
    }

    private static func resetKey(_ botID: String) -> String {
        Keys.endlessResetPrefix + botID
    }

    private static func isForgottenSession(_ error: GatewayError) -> Bool {
        guard let rpc = error.rpcError else { return false }
        return rpc.code == 4001 || rpc.code == 4007
    }

    /// Read the host's current model for the header chip.
    ///
    /// Silent on failure: no chip is honest, a wrong model name is the bug this replaced.
    private func loadModelLabel() async {
        do {
            // Scoped to the open bot: an unscoped catalogue answers for whichever profile the
            // gateway defaults to, which is why the chip kept saying deepseek after a bot's own
            // default had been changed to something else.
            modelLabel = try await client.modelCatalog(profile: selectedBotID).current?.label
        } catch {
            modelLabel = nil
        }
    }

    // MARK: Unread

    /// When each bot's conversation was last looked at, by this device.
    ///
    /// What the live bubble prints: only the words no row has printed yet.
    ///
    /// The host streams a commentary and also seals it as `message.interim`, which becomes a row of
    /// its own with a time stamp. Both then showed the same paragraph — one of them with a caret
    /// under it — and it collapsed into a single one the moment the turn settled.
    public var visibleStreamingText: String {
        TranscriptVisibility.streamingRemainder(streamingText, afterRows: turnAssistantRows)
    }

    /// The assistant words this turn has already written as rows.
    ///
    /// A turn can own several: the host seals a commentary at every tool call and again as
    /// `message.interim`, so one message reaches the transcript as a handful of paragraphs. The
    /// bubble and the completion gate both compare against all of them — comparing against only the
    /// last one is what printed two already-visible rows a second time (screenshot, 2026-11-10).
    private var turnAssistantRows: [String] {
        let start = min(max(0, turnRowStart), transcript.count)
        return transcript[start...].filter { $0.role == .assistant }.map(\.text)
    }

    /// The dot used to be raised only by `message.complete` for the session on screen — which the
    /// app does not receive for a bot it is not looking at, so a message that arrived on another bot
    /// (from the phone, from another agent, from cron) could never light it. Unread is now a
    /// comparison between the host's message time and this mark.
    @Published private(set) var lastRead: [String: Date] = [:]

    /// Call when a conversation appears or disappears: whatever arrived while it was open counts as
    /// read, and a reply that lands while the list is showing marks its bot unread.
    public func setVisibleBot(_ botID: String?) {
        visibleBotID = botID
        if let botID {
            unreadBots.remove(botID)
            unreadCounts[botID] = nil
            markRead(botID)
        }
    }

    /// Every conversation read, in one deliberate act.
    ///
    /// Opening a chat reads it; this is the same act for the whole list, so nine badged bots and two
    /// badged rooms do not have to be opened one by one to clear a badge the person has no intention
    /// of reading. The marks are written the same way `setVisibleBot` writes them, so a dot cannot
    /// come back on the next refresh.
    public func markAllRead(at date: Date = Date()) {
        var ids = Set(bots.map(\.id))
        ids.formUnion(unreadBots)
        ids.formUnion(unreadCounts.keys)
        for id in ids { markRead(id, at: date) }

        unreadBots.removeAll()
        unreadCounts.removeAll()

        // A room is read up to its own latest seq, not to a number this side invents: a mark past
        // the host's counter would hide the room's next message for good.
        for room in rooms where roomUnreadCounts[room.id] != nil {
            markRoomRead(room.id, seq: room.latestSeq ?? 0)
        }
        roomUnreadCounts.removeAll()
    }

    /// Whether there is anything to mark: the menu item greys out rather than promising a no-op.
    public var hasAnyUnread: Bool { !unreadCounts.isEmpty || !roomUnreadCounts.isEmpty }

    public func markRead(_ botID: String, at date: Date = Date()) {
        guard !botID.isEmpty else { return }
        if let existing = lastRead[botID], existing >= date { return }
        lastRead[botID] = date
        Self.defaults.set(lastRead.mapValues(\.timeIntervalSince1970), forKey: lastReadKey)
    }

    private var lastReadKey: String { "hermey.lastRead.\(hostName)" }

    private func loadLastRead() {
        guard let raw = Self.defaults.dictionary(forKey: lastReadKey) as? [String: Double] else { return }
        lastRead = raw.mapValues(Date.init(timeIntervalSince1970:))
    }

    /// Raise the dot from the host's own clock: a message newer than the last time this bot was
    /// looked at, on a bot that is not the one on screen.
    fileprivate func noteRemoteActivity(for botID: String, at date: Date) {
        guard botID != visibleBotID else { markRead(botID, at: date); return }
        let seen = lastRead[botID]
        if let seen {
            if date > seen { unreadBots.insert(botID) }
        } else {
            // First sight of a bot on this device: its history is not "unread", so seed the mark
            // with the newest message instead of lighting every row on first launch.
            lastRead[botID] = date
            Self.defaults.set(lastRead.mapValues(\.timeIntervalSince1970), forKey: lastReadKey)
        }
    }

    public func hasUnread(_ botID: String) -> Bool { unreadBots.contains(botID) }

    /// What the badge on a bot's face shows: how many of its turns landed after this device last
    /// looked. Zero means no badge at all.
    public func unreadCount(_ botID: String) -> Int { unreadCounts[botID] ?? 0 }

    // MARK: Bot activity

    /// A message — either direction — is the only thing that reorders the bot list.
    public func toggleHidden(botID: String) {
        guard !botID.isEmpty else { return }
        if hiddenBots.contains(botID) { hiddenBots.remove(botID) } else { hiddenBots.insert(botID) }
        Self.defaults.set(Array(hiddenBots), forKey: hiddenKey)
    }

    public func isHidden(botID: String) -> Bool { hiddenBots.contains(botID) }

    /// The bots this device chooses to show: pinned first, then by last message.
    public var orderedBots: [Bot] {
        BotOrdering.order(bots, activity: botActivity, pinned: pinnedBots, hidden: hiddenBots)
    }

    private var hiddenKey: String { "hermes.hiddenBots.\(hostName)" }

    private func loadHiddenBots() {
        hiddenBots = Set(Self.defaults.stringArray(forKey: hiddenKey) ?? [])
    }

    public func recordActivity(for botID: String, at date: Date = Date()) {
        guard !botID.isEmpty else { return }
        if let existing = botActivity[botID], existing >= date { return }
        botActivity[botID] = date
        persistBotActivity()
    }

    private var botActivityKey: String { "hermes.botActivity.\(hostName)" }

    private func loadBotActivity() {
        guard let raw = Self.defaults.dictionary(forKey: botActivityKey) as? [String: Double] else { return }
        botActivity = raw.mapValues(Date.init(timeIntervalSince1970:))
    }

    private func persistBotActivity() {
        Self.defaults.set(botActivity.mapValues(\.timeIntervalSince1970), forKey: botActivityKey)
    }

    // MARK: Bot pins

    /// Pin or unpin one bot. Pins are ordered by the host's own list, so there is no pin
    /// timestamp to keep: the set is enough, and toggling is idempotent per bot.
    public func togglePin(botID: String) {
        guard !botID.isEmpty else { return }
        if pinnedBots.contains(botID) {
            pinnedBots.remove(botID)
        } else {
            pinnedBots.insert(botID)
        }
        persistPinnedBots()
    }

    public func isPinned(botID: String) -> Bool { pinnedBots.contains(botID) }

    private var pinnedBotsKey: String { "hermes.pinnedBots.\(hostName)" }

    private func loadPinnedBots() {
        pinnedBots = Set(Self.defaults.stringArray(forKey: pinnedBotsKey) ?? [])
    }

    /// A pin for a bot the host no longer serves is harmless and is kept: if the profile comes
    /// back, so does its place at the top.
    private func persistPinnedBots() {
        Self.defaults.set(pinnedBots.sorted(), forKey: pinnedBotsKey)
    }

    // MARK: Per-bot model

    /// The model menu for one bot. Scoped, because each profile has its own catalogue and its own
    /// current model — asking globally answers for whichever profile the host defaults to.
    public func modelCatalog(for botID: String) async throws -> ModelCatalog {
        try await client.modelCatalog(profile: botID)
    }

    /// Set a bot's profile default model.
    ///
    /// The running conversation is left alone: the host applies the default to unpinned turns, and
    /// a session-level override (if the user ever set one) still wins. When the bot being changed is
    /// the one on screen, its chip is refreshed so the header stops showing the old model.
    @discardableResult
    public func configureModel(botID: String, model: String, provider: String,
                               confirm: Bool) async throws -> ProfileModelChange {
        let change = try await client.configureModel(profile: botID, model: model,
                                                      provider: provider, confirm: confirm)
        if case .applied = change, botID == selectedBotID {
            await loadModelLabel()
        }
        return change
    }

    // MARK: Per-bot description

    /// Write a bot's human-readable description to the host, then mirror it locally so the list's
    /// subtitle changes immediately. The host stays the source of truth for the next `loadBots()`,
    /// which is also what makes the text sync to other devices.
    public func configureDescription(botID: String, description: String) async throws {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        try await client.configureDescription(profile: botID, description: text)
        if let index = bots.firstIndex(where: { $0.id == botID }) {
            bots[index] = bots[index].withDescription(text)
        }
    }

    // MARK: Managing bots

    /// Bots the owner turned off. Published so a row can say "off" without asking the host per
    /// bot, and refreshed with the list.
    @Published public private(set) var disabledBots: Set<String> = []

    /// Refresh which bots are off. A bridge that predates the route answers empty, which reads as
    /// "nothing is off" — the same thing a host with no disabled bots says.
    public func refreshDisabledBots() async {
        if let names = try? await client.disabledBots() { disabledBots = names }
    }

    /// Create a bot on the host (`profiles.create`) and return the name it created.
    ///
    /// The face is the app's business, not the model's: the icon is a bridge-side preference keyed
    /// by bot id, so the caller stores it once it has the id — and a failure there only costs the
    /// default portrait.
    @discardableResult
    public func addBot(name: String, description: String, soul: String) async throws -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let created = try await client.createProfile(
            name: trimmedName.lowercased().replacingOccurrences(of: " ", with: "-"),
            description: trimmedDescription.isEmpty ? nil : trimmedDescription,
            soul: soul.isEmpty ? nil : soul
        )
        await loadBots()
        await refreshDisabledBots()
        return created
    }

    /// One bot's SOUL.md and description, straight from the host.
    public func describeBot(_ profile: String) async throws -> ProfileDescription {
        try await client.describeProfile(profile)
    }

    /// Every skill this host offers this bot, flattened — what the Skills panel lists.
    public func availableSkills(_ profile: String) async throws -> [String] {
        try await client.availableSkills(profile: profile)
    }

    /// Turn one skill on or off for a bot.
    ///
    /// `profiles.configure` **replaces** `skills.disabled`, so the list sent is every skill that is off
    /// after this tap — computed from the host's own snapshot, never a one-item delta, which would
    /// silently re-enable everything else.
    public func setSkill(_ name: String, enabled: Bool, for profile: String,
                         using description: ProfileDescription) async throws {
        var disabled = Set(description.skills.filter { !$0.enabled }.map(\.name))
        if enabled { disabled.remove(name) } else { disabled.insert(name) }
        try await client.configureFeatures(profile: profile,
                                           disabledSkills: Array(disabled).sorted(),
                                           enabledMCPServers: nil)
    }

    /// Turn one MCP server on or off for a bot. Same replace rule, on `enabled_mcp_servers`.
    public func setMCPServer(_ name: String, enabled: Bool, for profile: String,
                             using description: ProfileDescription) async throws {
        var servers = Set(description.mcpServers.filter(\.enabled).map(\.name))
        if enabled { servers.insert(name) } else { servers.remove(name) }
        try await client.configureFeatures(profile: profile,
                                           disabledSkills: nil,
                                           enabledMCPServers: Array(servers).sorted())
    }

    /// Replace a bot's SOUL.md. The host caches the prompt per session, so a running conversation
    /// keeps the old soul until it is reset — the editor says so rather than pretending.
    public func saveSoul(_ text: String, for profile: String) async throws {
        try await client.configureSoul(profile: profile, soul: text)
    }

    /// Delete a bot's profile on the host (the bridge archives it first).
    public func deleteBot(_ profile: String) async throws {
        try await client.deleteBot(profile)
        hiddenBots.remove(profile)
        disabledBots.remove(profile)
        await loadBots()
    }

    /// Turn a bot off (its schedules paused) or back on.
    public func setBotEnabled(_ profile: String, _ enabled: Bool) async throws {
        try await client.setBotEnabled(profile, enabled: enabled)
        await refreshDisabledBots()
    }

    // MARK: Group chats

    /// Group chats, kept here rather than in a sheet's `@State`: a room is host state that outlives
    /// any window, so the list survives a closed sheet, a relaunch and the other device.
    @Published public private(set) var rooms: [RoomSummary] = []

    /// How many bot messages each room has that this device has not read yet.
    ///
    /// Rooms get the same promise a bot's row makes: a count of what is waiting, computed from the
    /// host's own log rather than from a socket the app is not holding.
    @Published public private(set) var roomUnreadCounts: [String: Int] = [:]

    /// The high-water `seq` each room was read to, by this device, persisted per host.
    private var roomReadSeq: [String: Int] = [:]

    private var roomReadKey: String { "hermey.roomRead.\(hostName)" }

    private func loadRoomReadSeq() {
        guard let raw = Self.defaults.dictionary(forKey: roomReadKey) as? [String: Int] else { return }
        roomReadSeq = raw
    }

    private func saveRoomReadSeq() {
        Self.defaults.set(roomReadSeq, forKey: roomReadKey)
    }

    /// What the room's badge shows. Zero draws nothing, the same rule the bot badge follows.
    public func roomUnreadCount(_ roomID: String) -> Int { roomUnreadCounts[roomID] ?? 0 }

    public func hasUnreadRoom(_ roomID: String) -> Bool { roomUnreadCount(roomID) > 0 }

    /// Everything waiting in chats that are **not** the one on screen.
    ///
    /// This is what the back button's bubble counts: a bot's chat can be quiet while four other
    /// chats are not, and leaving that fact behind on the list is why answering one bot felt like
    /// starting over. A room's unread counts too — it is a chat with bots in it.
    public func unreadElsewhere(excludingBot botID: String?) -> Int {
        var total = 0
        for (id, count) in unreadCounts where id != botID { total += count }
        for count in roomUnreadCounts.values { total += count }
        return total
    }

    /// Mark a room read up to `seq`. Called when it opens and by its own view as new lines arrive,
    /// so reading a room can never leave a badge behind on the list.
    public func markRoomRead(_ roomID: String, seq: Int) {
        guard !roomID.isEmpty else { return }
        let mark = max(seq, 0)
        if mark > (roomReadSeq[roomID] ?? 0) {
            roomReadSeq[roomID] = mark
            saveRoomReadSeq()
        }
        if roomUnreadCounts[roomID] != nil { roomUnreadCounts[roomID] = nil }
    }

    public func markRoomRead(_ room: RoomSummary) {
        markRoomRead(room.id, seq: room.latestSeq ?? 0)
    }

    /// Count what the bots said in each room after this device's mark.
    ///
    /// `groups.list` reports each room's `latest_seq` but not how much of it is news, so the count
    /// comes from the room's own log — and only for rooms that moved since the mark, which makes an
    /// idle list cost zero extra requests. A room this device has never opened is seeded rather
    /// than badged, exactly like a bot on first launch: its history is not unread.
    public func refreshRoomUnread(in list: [RoomSummary]) async {
        let known = Set(list.map(\.id))
        roomUnreadCounts = roomUnreadCounts.filter { known.contains($0.key) }

        for room in list {
            let latest = room.latestSeq ?? 0
            guard let mark = roomReadSeq[room.id] else {
                markRoomRead(room.id, seq: latest)
                continue
            }
            guard latest > mark else {
                if roomUnreadCounts[room.id] != nil { roomUnreadCounts[room.id] = nil }
                continue
            }
            do {
                let page = try await client.roomPage(room.id, since: mark)
                let fresh = page.messages.filter { !$0.isOwner && $0.seq > mark }
                if fresh.isEmpty {
                    // Only the owner spoke (or only bookkeeping moved the seq): nothing to badge.
                    markRoomRead(room.id, seq: max(latest, page.latestSeq))
                } else {
                    roomUnreadCounts[room.id] = fresh.count
                }
            } catch {
                ClientLog.note("room \(room.id): unread read failed: \(error.localizedDescription)",
                               level: .warning, category: "rooms")
            }
        }
    }

    /// The room on screen, if any. A room and a bot share the one conversation pane — opening a
    /// room is not a window, it is the same place a bot's chat appears, so Escape/back and the pane
    /// behave identically for both.
    @Published public var activeRoom: RoomSummary?

    /// Bumped by ⌘R. The pane that is on screen watches this instead of owning a timer.
    @Published public private(set) var refreshTick = 0

    /// Ask whatever chat is on screen to re-read itself from the host.
    public func requestRefresh() { refreshTick += 1 }

    /// Show a room in the conversation pane, and remember it so the pane can be re-created.
    ///
    /// Opening is reading: the room's mark moves to its newest line the moment it is on screen, so
    /// the list cannot keep badging a chat the user is looking at.
    public func openRoom(_ room: RoomSummary) {
        activeRoom = room
        markRoomRead(room)
    }

    /// Leave the room; the pane falls back to the selected bot.
    public func closeRoom() {
        activeRoom = nil
    }

    /// Re-read the host's room list. Cheap (one call, a handful of rooms) and safe to spam.
    ///
    /// The unread sweep rides along: a room list is only worth showing if it says what is waiting
    /// in each room, and both halves come from the same host read.
    public func refreshRooms() async {
        do {
            let list = try await client.rooms()
            rooms = list
            await refreshRoomUnread(in: list)
        } catch {
            // A stale list beats an empty one — but the log remembers why it is stale.
            ClientLog.note("rooms.list failed: \(error.localizedDescription)",
                           level: .warning, category: "rooms")
        }
    }

    /// Open a room and put it at the top of the list immediately, without waiting for a re-read.
    @discardableResult
    public func createRoom(name: String, members: [String]) async throws -> RoomSummary {
        let room = try await client.createRoom(name: name, members: members)
        rooms.removeAll { $0.id == room.id }
        rooms.insert(room, at: 0)
        await refreshRooms()
        return room
    }

    /// The room a list's long-press menu asked to rename, by id.
    ///
    /// Rename has exactly one entry point — the row's context menu on both platforms — so neither
    /// the room's toolbar nor its header carries a Rename button. The list names a room here and
    /// opens it; the room's own view opens its field and clears this value.
    @Published public var renameRequest: String?

    /// Ask a room to show its rename field (the row's context menu, not a button in the room).
    public func requestRename(_ roomID: String) { renameRequest = roomID }

    /// Rename a room on the host, then here.
    public func renameRoom(_ roomID: String, to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await client.renameRoom(roomID, name: trimmed)
        if let index = rooms.firstIndex(where: { $0.id == roomID }) {
            let old = rooms[index]
            rooms[index] = RoomSummary(id: old.id, name: trimmed, members: old.members,
                                       updatedAt: old.updatedAt, latestSeq: old.latestSeq,
                                       lastSpeaker: old.lastSpeaker, lastFromOwner: old.lastFromOwner,
                                       lastText: old.lastText, lastAt: old.lastAt)
        }
        if activeRoom?.id == roomID { activeRoom = rooms.first { $0.id == roomID } }
        await refreshRooms()
    }

    /// Remove a room from the host, then from the list.
    public func disbandRoom(_ roomID: String) async throws {
        try await client.disbandRoom(roomID)
        rooms.removeAll { $0.id == roomID }
    }

    /// Rooms this host hosts, newest first.
    public func groupChats() async throws -> [RoomSummary] { try await client.rooms() }

    /// Open a room with the bots the owner picked.
    @discardableResult
    public func startGroupChat(name: String, members: [String]) async throws -> RoomSummary {
        try await createRoom(name: name, members: members)
    }

    /// One page of a room's conversation.
    public func roomPage(_ roomID: String, since: Int?) async throws -> RoomPage {
        try await client.roomPage(roomID, since: since)
    }

    /// Say something in a room; `@bot` names who should answer.
    public func sendRoomMessage(_ roomID: String, text: String) async throws {
        try await client.sendRoomMessage(roomID, text: text)
    }

    /// The same, with files: the host stores them and the message carries their paths.
    public func sendRoomMessage(_ roomID: String, text: String,
                                attachments: [RoomAttachment]) async throws {
        try await client.sendRoomMessage(roomID, text: text, attachments: attachments)
    }

    // MARK: Latency

    /// Round-trip time of one real request, for the connection chip.
    ///
    /// This is a `ping`: the gateway answers `{"pong": true}` without touching the session
    /// database, so the number measures the wire and not how warm the profile happens to be.
    /// (`session.list` was the earlier probe and it is exactly the call observed taking 60 s
    /// on a cold profile — `fixtures/NOTES.md` §4.) A host that never answers publishes
    /// **nothing**: the chip keeps its label without a number instead of inventing one.
    public func refreshLatency(budget: TimeInterval = 6) async {
        guard connection.isLive else {
            latencyMS = nil
            return
        }
        let client = self.client
        let started = Date()
        let answered = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                do { try await client.ping(); return true } catch { return false }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0.5, budget) * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        guard answered else { return }
        latencyMS = max(0, Int(Date().timeIntervalSince(started) * 1000))
    }

    // MARK: Derived state

    /// The bot whose pane is on screen, for the switcher's title and avatar.
    public var selectedBot: Bot? {
        guard let selectedBotID else { return nil }
        return bots.first { $0.id == selectedBotID }
    }

    public var selectedSession: SessionSummary? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    public var hasPendingRequests: Bool { !pendingRequests.isEmpty }

    /// The turn is live or the submit is still in flight.
    public var isBusy: Bool { isStreaming || sending }

    /// How full the context is, `0…1`, or `nil` until the host has reported both numbers.
    /// The conversation header draws its gauge from this, so an unreported context is an absent
    /// gauge rather than an empty one.
    public var contextFraction: Double? {
        guard let contextUsed, let contextMax, contextMax > 0 else { return nil }
        return Double(contextUsed) / Double(contextMax)
    }

    public func clearSendError() { lastSendError = nil }

    // MARK: Approvals

    public func answer(_ request: ServerRequest, choice: String) async {
        try? await client.answer(request.id, with: .object(["choice": .string(choice)]))
        pendingRequests.removeAll { $0.id == request.id }
    }

    public func answers(_ request: ServerRequest, _ answers: [String: String]) async {
        let value = JSONValue.object(answers.mapValues { JSONValue.string($0) })
        try? await client.answer(request.id, with: .object(["answers": value]))
        pendingRequests.removeAll { $0.id == request.id }
    }

    /// Refuse a request the client cannot render *at all*.
    ///
    /// This sends JSON-RPC `-32601`, and Hermes deliberately reads that as "no client here can
    /// answer this" — it *withdraws* the queued approval and tells the agent to update the app.
    /// It is NOT a denial: nothing was refused. Use `deny(_:)` when the user pressed Deny.
    public func decline(_ request: ServerRequest) async {
        try? await client.decline(request.id, with: .methodNotFound)
        pendingRequests.removeAll { $0.id == request.id }
    }

    // MARK: Answering an approval

    /// The tokens the host offers for this request, in the host's own order.
    ///
    /// `tui_gateway/server.py::_approval_request_payload` computes `choices` as `["once"]`,
    /// plus `"session"` unless `smart_denied`/`allow_session is False`, plus `"always"` unless
    /// `allow_permanent is False`, then always `"deny"`. The client renders exactly these: a
    /// smart-denied command legitimately arrives with only `["once","deny"]`.
    public static func choices(for request: ServerRequest) -> [String] {
        guard case .array(let values)? = request.params["choices"] else { return [] }
        return values.compactMap { $0.stringValue }
    }

    /// The session a server request is about. `approval`/`clarify` carry `session`; a resumed
    /// `open_requests` entry carries `session_id`. `nil` means the host did not say.
    public static func sessionID(of request: ServerRequest) -> SessionID? {
        request.params["session_id"]?.stringValue ?? request.params["session"]?.stringValue
    }

    /// Answer with one of `choices(for:)`.
    ///
    /// The wire shape is `{"choice": <token>, "all": <bool>}` — verified in
    /// `tui_gateway/server.py::_emit_approval_request`, which does
    /// `choice = str(result.get("choice") or "deny")`. Any other key is ignored, so a client
    /// that sends `{"approved": true}` is read as a **deny**. That is why this method takes a
    /// token rather than a boolean.
    public func respond(_ request: ServerRequest, choice: String, all: Bool = false) async {
        let params: JSONValue = .object([
            "choice": .string(choice),
            "all": .bool(all),
        ])
        try? await client.answer(request.id, with: params)
        pendingRequests.removeAll { $0.id == request.id }
    }

    /// Allow, in the strongest form the host offered (`once` by default).
    public func approve(_ request: ServerRequest) async {
        let offered = Self.choices(for: request)
        let choice = offered.first { $0 == "once" } ?? offered.first ?? "once"
        await respond(request, choice: choice)
    }

    /// Refuse. An explicit `deny` token, never `-32601`: the user said no, and the agent must
    /// be told no rather than "this client cannot answer".
    public func deny(_ request: ServerRequest) async {
        await respond(request, choice: "deny")
    }


    // MARK: Events

    private func observeEvents() async {
        eventTask?.cancel()
        let events = client.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.apply(event)
            }
        }
    }

    private func apply(_ event: ClientEvent) async {
        switch event {
        case .ready:
            connection = .connected
            // A reconnect can mean events were lost, and the host is the authority — but re-deriving
            // blindly wiped the visible turn. iOS suspends the socket constantly, so every
            // foreground sent `ready` and `select()` cleared the transcript and streaming text
            // mid-turn: the reply demonstrably arrived (audit log: submit accepted, 12 deltas within
            // 4 s) and then vanished from the screen. Reconcile without destroying a live turn.
            if let sid = selectedSessionID {
                await reconcile(afterReconnect: sid)
            }
        case .state(let state):
            switch state {
            case .open: connection = .connected
            case .connecting: connection = .connecting
            case .reconnecting(let n):
                connection = .reconnecting(attempt: n)
                // The one line that explains every "it stopped answering": the socket dropped and
                // is being retried, and how many times.
                ClientLog.note("socket reconnecting (attempt \(n))", level: .warning, category: "connection")
            case .closed, .idle: break
            case .failed(let why):
                connection = .failed(why)
                ClientLog.note("socket failed: \(why)", level: .error, category: "connection")
            }
        case .interimMessage(let session, let text, let alreadyStreamed, let key):
            guard session == selectedSessionID else { return }
            // The same seal can be re-sent; the row is identified by its turn and segment.
            guard sealedInterimKeys.insert(key).inserted else { return }
            beginLiveTurn()
            isStreaming = true
            runningSessions.insert(session)
            // The same words may already have a row: the deltas said them before the first tool
            // call and `sealCommentary` kept them. This is that sentence arriving by another door.
            if sealedCommentary.contains(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                streamingText = ""
                return
            }
            // Its own row, appended *now*: the cards that follow this commentary belong under it,
            // and waiting for `message.complete` would put the line after the answer it preceded.
            // The row that a tool call already sealed is this same commentary; the gate inside keeps
            // it from being written a second time a minute later (which is what was on screen).
            appendAssistantRow(id: "interim-\(key)", text: text, at: Date())
            // When the host says the words already went out as deltas, they are sitting in the
            // live bubble; the row above replaces it, so the bubble must let go of them.
            if alreadyStreamed { streamingText = "" }

        case .messageDelta(let session, let text):
            guard session == selectedSessionID else { return }
            beginLiveTurn()
            isStreaming = true
            runningSessions.insert(session)
            streamingText += text
        case .thinkingDelta(let session, let text):
            // Same stream discipline as the reply, a different destination: reasoning belongs
            // beside the answer, never inside it. An empty `text` never reaches here (the decoder
            // drops the heartbeat), so accumulated reasoning is only ever *added* to.
            guard session == selectedSessionID else { return }
            beginLiveTurn()
            isStreaming = true
            runningSessions.insert(session)
            reasoningText += text
        case .messageComplete(let session, let text):
            guard session == selectedSessionID else { return }
            if let bot = selectedBotID {
                recordActivity(for: bot)
                // A reply for a bot you are not looking at is the only thing that earns a dot.
                if visibleBotID != bot { unreadBots.insert(bot) }
            }
            // A completion with no text would otherwise leave a blank bubble beside the streamed
            // one; the deltas already hold the reply.
            let finalText = text.isEmpty ? streamingText : text
            // Reasoning is a separate stream and used to be wiped here, so a turn's thinking was
            // visible while it ran and gone the moment the answer landed.
            if !reasoningText.isEmpty {
                transcript.append(TranscriptEntry(id: "reasoning-\(UUID().uuidString)",
                                                  role: .reasoning,
                                                  text: reasoningText))
            }
            // The turn's tool cards become transcript rows *before* the answer: appending the
            // assistant message first would push every card underneath the reply it produced,
            // and leaving them in `liveTools` meant the next resume — which answers with the
            // host's messages only — wiped them from the thread.
            flushLiveTools()
            appendAssistantRow(id: UUID().uuidString, text: finalText, at: Date())
            // The list's third line follows the conversation without waiting for a re-list.
            if let bot = selectedBotID, let line = Self.previewLine(finalText) {
                botPreviews[bot] = line
                botPreviewTimes[bot] = Date()
            }
            streamingText = ""
            isStreaming = false
            reasoningText = ""
            sealedInterimKeys.removeAll()
            sealedCommentary.removeAll()
            runningSessions.remove(session)
            // Not awaited: compaction is a model turn that can take minutes, and parking this loop
            // would hold back every later delta, approval and tool event behind it.
            Task { await self.autoCompactIfNeeded() }
            // Move this row now, cheaply. A preview sweep here cost one `session.list` per bot
            // after *every* reply just to reorder one row; the host's own timestamps arrive on the
            // next list appearance or foreground, which is when the other device's turns matter.
            if let bot = selectedBotID { recordActivity(for: bot) }
        case .contextUsage(let session, let used, let max, _):
            guard session == selectedSessionID else { return }
            contextUsed = used
            // A host that omits `context_max` must not turn the gauge into "100%".
            if max > 0 { contextMax = max }
        case .toolStart(let session, let name, let callID, let input):
            guard session == selectedSessionID else { return }
            beginLiveTurn()
            isStreaming = true
            runningSessions.insert(session)
            // The card's label is the wire's `name`; the old projection rendered the literal word
            // "tool" for every call. An unnamed call is said to be unknown rather than mislabelled.
            let resolved = name.isEmpty ? "unknown tool" : name
            // Server-side commentary is a courtesy, not a guarantee: `message.interim` only fires
            // when the agent runtime offers the callback, and this host's provider does not. The
            // words the model streamed *before* reaching for a tool are the same commentary, and
            // they are about to be overwritten by the answer — so they are sealed here.
            sealCommentary()
            if let index = liveTools.firstIndex(where: { $0.id == callID }) {
                liveTools[index].name = resolved
                liveTools[index].input = input
                liveTools[index].isRunning = true
            } else {
                liveTools.append(LiveTool(id: callID, name: resolved, input: input))
            }
        case .toolProgress(let session, let callID, let text):
            guard session == selectedSessionID else { return }
            if let index = liveTools.firstIndex(where: { $0.id == callID }) {
                liveTools[index].output = text
            }
        case .toolComplete(let session, let name, let callID, let output, _, let durationMS):
            guard session == selectedSessionID else { return }
            if let index = liveTools.firstIndex(where: { $0.id == callID }) {
                if let name, !name.isEmpty { liveTools[index].name = name }
                liveTools[index].output = output
                liveTools[index].isRunning = false
                liveTools[index].durationMS = durationMS
            } else {
                // A completion whose start this client never saw — a replayed event, or a tool
                // that began before the socket reattached — still deserves a row with its name.
                let resolved = (name?.isEmpty == false ? name : nil) ?? "unknown tool"
                liveTools.append(LiveTool(id: callID,
                                          name: resolved,
                                          output: output,
                                          isRunning: false,
                                          durationMS: durationMS))
            }
        case .request(let request):
            // A question about a session the user is not looking at would sit under the wrong
            // conversation. Only filtered when we can tell: a request that names no session (or
            // arrives with nothing open) is still surfaced, because the agent is blocked on it.
            if let selected = selectedSessionID,
               let named = Self.sessionID(of: request),
               named != selected {
                return
            }
            guard !pendingRequests.contains(where: { $0.id == request.id }) else { return }
            pendingRequests.append(request)
        case .requestCancelled(let id, _):
            pendingRequests.removeAll { $0.id == id }
        case .sessionUpdated:
            // The event carries no detail the pane can use: the transcript it would refresh is
            // reloaded by `resumeSession`, and re-listing every session here turned one host
            // notification into a `session.list` storm.
            break
        case .error(_, let message):
            lastSendError = message
            ClientLog.note("host reported an error: \(message)", level: .error, category: "gateway")
        case .unknown:
            break
        }
    }

    /// A new turn is starting: the previous turn's tool cards described a turn whose answer has
    /// already landed, so they must not run into this one — they become transcript rows first,
    /// where they stay attached to the turn they belong to.
    /// Commentaries already given a row in this turn, so a later `message.interim` for the same
    /// words does not say them twice.
    private var sealedCommentary: [String] = []

    /// Turn whatever the live bubble is holding into its own assistant row.
    ///
    /// Called when the model reaches for a tool: the text so far is commentary *about* the work,
    /// and the bubble it sits in is the answer's, which the next delta starts filling in. Without
    /// this the commentary is silently replaced instead of staying where it was read.
    private func sealCommentary() {
        let text = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sealedCommentary.append(text)
        appendAssistantRow(id: "commentary-\(UUID().uuidString)", text: text, at: Date())
        streamingText = ""
    }

    private func beginLiveTurn() {
        guard !isStreaming else { return }
        flushLiveTools()
        turnRowStart = transcript.count
    }

    /// Where this turn's rows begin in `transcript`, so "the same words again" can be judged against
    /// what *this* turn has already written rather than the previous answer.
    private var turnRowStart = 0

    /// Append an assistant row, unless this turn already ends with exactly those words.
    ///
    /// The same paragraph arrives by several doors: the commentary is sealed when a tool is called,
    /// the host seals it again as `message.interim`, and `message.complete` sends the answer. Each
    /// one used to write its own row, which is the duplicate the user watched appear and then merge.
    /// Identical words at the end of the same turn are the same message.
    @discardableResult
    private func appendAssistantRow(id: String, text: String, at date: Date?) -> Bool {
        // What this turn has not already written. The completion repeats the whole message of the
        // turn, whose sealed commentaries are rows already — appending it verbatim printed them a
        // second time under themselves. Only the unsaid paragraphs are worth a row.
        let fresh = TranscriptVisibility.unsaid(text, by: turnAssistantRows)
        guard !fresh.isEmpty else { return false }
        transcript.append(TranscriptEntry(id: id, role: .assistant, text: fresh, at: date))
        return true
    }

    /// Move the turn's live tool cards into `transcript` as `.tool` rows.
    ///
    /// While a turn runs the cards are separate state, because `tool.start`/`tool.complete` are
    /// events and the host sends no message for them. That state is fragile in exactly two ways
    /// and this call closes both: rows drawn from it render after every transcript entry (so the
    /// answer appears *above* the calls that produced it) and a resume — the host answers with
    /// messages, not tool events — would erase them. The row text is the projection format both
    /// apps already parse back into a card: `name · first line of args · 1.2s`.
    private func flushLiveTools() {
        guard !liveTools.isEmpty else { return }
        transcript.append(contentsOf: liveTools.map(Self.toolEntry(for:)))
        liveTools = []
    }

    /// The cards of the running turn, as transcript rows.
    ///
    /// The phone draws them from `liveTools`; the Mac's transcript only ever read `transcript`, so
    /// on the desktop the calls of a running turn were invisible until the turn ended and the cards
    /// were flushed. Same rows, same ids, drawn live.
    public var liveToolEntries: [TranscriptEntry] {
        liveTools.map(Self.toolEntry(for:))
    }

    /// Whether the host holds rows older than the ones on screen.
    public var hasEarlierHistory: Bool { (earlierCursor ?? 0) > 0 }

    /// Pull the next page of older rows and put them above what is already drawn.
    ///
    /// The page ends exactly where the oldest row on screen begins — the bridge slices its copy of
    /// this connection's own resume by `cursor` — so this can only extend the transcript, never
    /// repeat or skip a row. Prepending shifts every row down, so the fold is remembered as
    /// `earlierAnchor` and the views re-anchor to it instead of jumping to the newest message.
    public func loadEarlierHistory(limit: Int = 150) async {
        guard !loadingEarlier, let cursor = earlierCursor, cursor > 0,
              let sid = selectedSessionID else { return }
        loadingEarlier = true
        defer { loadingEarlier = false }
        let fold = transcript.first?.id
        do {
            let page = try await client.historyPage(sid, profile: selectedBotID, cursor: cursor, limit: limit)
            guard selectedSessionID == sid else { return }
            earlierCursor = page.cursor
            if page.total > 0 { historyTotal = page.total }
            guard !page.entries.isEmpty else { return }
            // A row already on screen is never inserted twice: a page that overlaps the current
            // transcript (a host that answered with a wider slice) must not double a message.
            let known = Set(transcript.map(\.id))
            let fresh = page.entries.filter { !known.contains($0.id) }
            guard !fresh.isEmpty else { return }
            transcript.insert(contentsOf: SentAttachmentVault.decorate(fresh, sessionID: sid), at: 0)
            turnRowStart += fresh.count
            earlierAnchor = fold
            earlierLoads += 1
        } catch {
            guard selectedSessionID == sid else { return }
            lastSendError = "could not load earlier messages: \(error.localizedDescription)"
            ClientLog.note("session.history failed: \(error.localizedDescription)",
                           level: .warning, category: "paging")
        }
    }

    /// The rows the transcript draws. Every other reader (counts, search over history, the last
    /// reply) keeps `transcript`: hiding a card is a display choice, not a loss of history.
    public var visibleTranscript: [TranscriptEntry] {
        TranscriptVisibility.rows(transcript, showToolCalls: showToolCalls)
    }

    /// The running turn's cards, or nothing when the user turned tool calls off.
    public var visibleLiveToolEntries: [TranscriptEntry] {
        TranscriptVisibility.showsLiveCards(showToolCalls: showToolCalls, hasLiveTools: !liveTools.isEmpty)
            ? liveToolEntries : []
    }

    /// One live card as the row the transcript keeps.
    ///
    /// The row keeps the call's arguments *and* its result, so opening it after the turn still
    /// shows what ran and what came back — the projection's rows ship the arguments for the same
    /// reason, and nothing else about the call survives the turn.
    private static func toolEntry(for tool: LiveTool) -> TranscriptEntry {
        let firstLine = tool.input
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let detail = TranscriptEntry.ToolDetail(
            name: tool.name,
            context: firstLine.isEmpty ? nil : String(firstLine.prefix(120)),
            args: tool.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : tool.input,
            content: tool.output,
            labels: []
        )
        return TranscriptEntry(id: "tool-\(tool.id)",
                               role: .tool,
                               text: toolRowText(tool),
                               tool: detail)
    }

    /// `bash · rsync -a ~/vault/ · 0.8s` — the shape `MobileToolRow.parse` / `TranscriptRowView`
    /// read back. A call with no arguments still names itself; a call that never completed says
    /// so rather than claiming a duration it never had.
    static func toolRowText(_ tool: LiveTool) -> String {
        var parts = [tool.name.isEmpty ? "unknown tool" : tool.name]
        let firstLine = (tool.input.split(separator: "\n", omittingEmptySubsequences: true).first
            .map(String.init) ?? tool.input)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !firstLine.isEmpty { parts.append(String(firstLine.prefix(120))) }
        if let duration = tool.durationMS {
            parts.append(duration < 1_000
                ? "\(max(0, duration)) ms"
                : String(format: "%.1fs", Double(duration) / 1_000))
        } else if tool.isRunning {
            parts.append("interrupted")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Previews

/// A client that answers nothing, so SwiftUI previews and CI snapshots never touch a network.
///
/// The `scenario` only changes *what the canned stream says*: every case is offline, the
/// same sessions are returned, and no case opens a socket. A preview that needs a pending
/// approval or a half-streamed answer therefore gets it from the event stream — the same
/// path the real client uses — rather than by poking `AppModel`'s state from outside.
public final class PreviewGatewayClient: GatewayClientProtocol, @unchecked Sendable {
    public enum Scenario: String, Sendable {
        /// Sessions and a resume, nothing live.
        case sessions
        /// No sessions at all — the first-launch / unpaired sidebar.
        case empty
        /// A turn that is still streaming when the preview settles.
        case streaming
        /// A turn blocked on an approval.
        case approval
        /// A wire that keeps dropping.
        case offline
    }

    public var state: TransportState { get async { .open } }

    public let events: AsyncStream<ClientEvent>
    private let continuation: AsyncStream<ClientEvent>.Continuation
    private let scenario: Scenario

    public init(scenario: Scenario = .sessions) {
        self.scenario = scenario
        var captured: AsyncStream<ClientEvent>.Continuation!
        events = AsyncStream { captured = $0 }
        continuation = captured
    }

    public func connect() async throws {
        continuation.yield(.ready(replayEpoch: nil))

        // Anything that must land *after* the shell has opened a session is deferred: a
        // delta for a session that is not selected yet is dropped by `AppModel`, which is
        // the correct behaviour and would make these previews look inert.
        let continuation = self.continuation
        switch scenario {
        case .offline:
            continuation.yield(.state(.reconnecting(attempt: 2)))
        case .streaming:
            Task {
                // Everything is deferred past the shell's first selection: a delta for a session
                // that is not selected yet is dropped by `AppModel`, which is the correct
                // behaviour and would make this preview look inert.
                let act: (ClientEvent) -> Void = { continuation.yield($0) }
                try? await Task.sleep(nanoseconds: 300_000_000)
                act(.thinkingDelta(session: "preview-1",
                                   text: "The vault is 1.2 GB, so the first snapshot is the expensive one."))
                try? await Task.sleep(nanoseconds: 300_000_000)
                act(.toolStart(session: "preview-1", name: "bash", callID: "preview-tool-1",
                               input: "rsync -a --delete ~/vault/ ~/backup/vault/"))
                try? await Task.sleep(nanoseconds: 400_000_000)
                act(.toolComplete(session: "preview-1", name: "bash", callID: "preview-tool-1",
                                  output: "sent 1,204 files · 1.2G · exit 0", ok: true, durationMS: 800))
                for chunk in ["Snapshotting the vault first, ",
                              "then I'll diff the docs tree.\n\n",
                              "```sh\nrsync -a --delete ~/vault/ ~/backup/vault/\n```"] {
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    act(.messageDelta(session: "preview-1", text: chunk))
                }
            }
        case .approval:
            Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                continuation.yield(.request(ServerRequest(
                    id: .string("srq-7"),
                    method: "approval",
                    params: .object([
                        "kind": .string("shell"),
                        "prompt": .string("rm -rf ~/jobs/hermey/.build"),
                        "reason": .string("Clears the stale build cache before a clean build. The source tree is untouched."),
                        "session": .string("preview-1"),
                    ])
                )))
            }
        case .sessions, .empty:
            break
        }
    }

    public func disconnect() async {}

    public func ping() async throws {}

    /// Four plausible bots, deliberately different lengths and initials, so a preview of the
    /// switcher shows the real thing: several assistants, one host, one row selected.
    public func listBots() async throws -> [Bot] {
        PreviewGatewayClient.bots
    }

    static let bots: [Bot] = [
        Bot(id: "assistant", displayName: "Assistant"),
        Bot(id: "ops", displayName: "Ops"),
        Bot(id: "charlie", displayName: "Scribe"),
        Bot(id: "night-ops", displayName: "Night shift"),
    ]

    public func listSessions(limit: Int) async throws -> [SessionSummary] {
        try await listSessions(limit: limit, profile: nil, includeHidden: true)
    }

    /// Deterministic per-bot slices: the first bot keeps the full list (previews elsewhere hard
    /// code `preview-1`, which must exist), while the others get shorter, disjoint sets so a row
    /// leaking between bots would be visible on screen rather than plausible.
    public func listSessions(limit: Int, profile: String?, includeHidden: Bool) async throws -> [SessionSummary] {
        guard scenario != .empty else { return [] }
        let rows = PreviewGatewayClient.sessions
        switch profile {
        case "ops": return Array(rows.prefix(2))
        case "charlie": return Array(rows.suffix(1))
        case "night-ops": return []
        default: return rows
        }
    }

    /// Deterministic, so two preview renderings of the same scenario are the same picture.
    static let sessions: [SessionSummary] = {
        let now = Date()
        return [
            SessionSummary(id: "preview-1",
                           title: "Vault backup + docs sync",
                           updatedAt: now.addingTimeInterval(-42),
                           preview: "Snapshotting the vault first",
                           running: true),
            SessionSummary(id: "preview-2",
                           title: "Tailscale ACL audit",
                           updatedAt: now.addingTimeInterval(-3 * 3_600),
                           preview: "Reviewed 3 tags · no drift"),
            SessionSummary(id: "preview-3",
                           title: "Gateway handshake retry",
                           updatedAt: now.addingTimeInterval(-30 * 3_600),
                           preview: "The ticket is only valid once"),
            SessionSummary(id: "preview-4",
                           title: "Sparse routing notes",
                           updatedAt: now.addingTimeInterval(-5 * 86_400),
                           preview: "Draft is in Obsidian under research/"),
        ]
    }()

    public func resumeSession(_ id: SessionID) async throws -> SessionResume {
        SessionResume(id: id,
                      entries: [
                        TranscriptEntry(id: "1", role: .user,
                                        text: "Back up the vault and re-sync docs."),
                        TranscriptEntry(id: "2", role: .assistant,
                                        text: "Snapshotting the vault first, then I'll diff the docs tree.\n\n**Plan**\n\n1. `rsync` the vault to `~/backup/vault`\n2. Diff `docs/` against the backup\n3. Report only files that changed\n\n> Nothing is deleted until the diff is reviewed."),
                        TranscriptEntry(id: "3", role: .tool,
                                        text: "bash · rsync -a ~/vault/ ~/backup/vault/ · 0.8s · exit 0"),
                        TranscriptEntry(id: "4", role: .assistant,
                                        text: "Backup is in place — 1,204 files, no errors. Diffing next."),
                      ],
                      inflight: nil,
                      openRequests: [])
    }

    public func createSession(model: String?, provider: String?) async throws -> SessionID { "preview-new" }
    public func history(_ id: SessionID, limit: Int) async throws -> [TranscriptEntry] { [] }
    public func submit(session: SessionID, text: String) async throws -> TurnDelivery { .streaming }
    public func steer(session: SessionID, text: String) async throws {}
    public func interrupt(session: SessionID) async throws {}
    public func rewind(session: SessionID, toRowID: Int64, then text: String) async throws {}
    public func modelOptions() async throws -> [ModelOption] {
        [ModelOption(id: "deepseek-v4.1-flash", provider: "opencode-go", label: "deepseek-v4.1-flash")]
    }

    /// The chip reads `current`, so a preview shows the same model the real host does.
    public func modelCatalog() async throws -> ModelCatalog {
        let option = ModelOption(id: "deepseek-v4.1-flash", provider: "opencode-go",
                                 label: "deepseek-v4.1-flash")
        return ModelCatalog(current: option, options: [
            ModelOption(id: "claude-fable", provider: "anthropic", label: "claude-fable"),
            option,
        ])
    }

    /// Previews have no host to compact; answering is enough for the header's notice to render.
    public func compress(session: SessionID) async throws {}

    public func answer(_ request: ServerRequestID, with result: JSONValue) async throws {}
    public func decline(_ request: ServerRequestID, with error: RPCError) async throws {}
}
#endif
