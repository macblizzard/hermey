#if canImport(Combine)
import Foundation
import Combine
import CryptoKit
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

        /// The socket, or the first read over it, gave up. Distinct from "still dialling": a failure
        /// carries a reason, and the launch gate hands the app's own UI the moment one exists rather
        /// than waiting out its deadline for a host that has already answered "no".
        public var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
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
    /// Whether `profiles.list` has *answered* this launch attempt — including answering with an empty
    /// list, and including failing.
    ///
    /// `bots.isEmpty` cannot tell "this host serves no bots" from "nobody has asked yet", and the
    /// launch screen has to know the difference: the first is a usable app, the second is a splash
    /// that should still be up. Reset by `start()`, so a reconnect starts a fresh question.
    @Published public private(set) var rosterAnswered = false
    /// The bot whose sessions and transcript are on screen. `nil` means "not chosen yet", which
    /// is also what an unscoped `session.list` means.
    @Published public private(set) var selectedBotID: String?
    /// The bot whose rows `transcript` currently holds — the model's answer to "whose messages are
    /// these?", which nothing used to ask.
    ///
    /// One transcript serves whichever bot is on screen. Every write that *replaces* it states its
    /// bot and is refused when the answer disagrees, so a late resume for the bot the user left can
    /// no longer be drawn inside the bot they moved to — the report that a bot's window showed
    /// another bot's messages until the app was relaunched. The guard is in the model, not the view:
    /// a window is drawn from `transcript`, and no view can tell whose rows it was handed.
    @Published public private(set) var transcriptOwner: String?
    /// Why the bot directory could not be read. The bot pane says so rather than "no bots".
    @Published public private(set) var botsError: String?

    // MARK: Sessions

    @Published public private(set) var sessions: [SessionSummary] = []
    @Published public private(set) var sessionsLoading = false
    /// Whether `session.list` has answered for the bot that was selected when it was asked.
    ///
    /// The second half of "the app is usable": a roster of names with no session list behind it is
    /// the bot list as it looks while it is still assembling, which is what the launch screen covers.
    @Published public private(set) var sessionsAnswered = false
    @Published public var selectedSessionID: SessionID?
    /// Sessions this app created that the host has not persisted yet (see `newSession`).
    ///
    /// `session.create` deliberately writes no row until the first prompt, so a draft cannot be
    /// resumed: the host answers `4007 session not found` and the pane used to paint that as a
    /// dead host. Drafts are adopted locally and leave this set once `prompt.submit` has persisted
    /// the row.
    @Published public private(set) var draftSessionIDs: Set<SessionID> = []
    @Published public private(set) var transcript: [TranscriptEntry] = [] {
        didSet { visibleTranscriptCache = nil }
    }
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

    /// What the turn has actually streamed, token for token.
    ///
    /// `streamingText` is what the screen draws, and it is written on a 40 ms beat rather than once
    /// per token: the host streams faster than any display can draw, and every write to a
    /// `@Published` re-evaluates every view that observes this model — the sidebar, the header, the
    /// panel and the transcript — so a 300-token answer used to mean 300 full body passes to move a
    /// caret (the jitter reported 2026-11-14). This is the copy the turn is *built* from, so nothing
    /// is lost between beats.
    var streamedText: String = ""
    private var streamFlush: Task<Void, Never>?
    /// Turn/segment keys of the interim commentaries already written into the transcript, so a
    /// re-sent seal does not become a second bubble.
    private var sealedInterimKeys = Set<String>()
    @Published public private(set) var isStreaming = false

    /// What each bot is doing, reduced from the events this client already receives.
    ///
    /// One tracker for the whole app: the roster, the chat header, the bot panel and every
    /// transcript row read the same answer through `activity(forBot:)`, so no two of them can
    /// disagree — and none of them re-derives the precedence from `isStreaming` and a tool name.
    /// Live per-bot activity for the avatar. Kept apart from `botActivity` below, which is the
    /// ordering clock (last message per bot) and has nothing to do with what a bot is doing now.
    @Published public private(set) var botActivityTracker = BotActivityTracker()

    /// Which bot a session belongs to, as far as this launch has seen.
    ///
    /// `apply(_:)` maps an event's session back to its bot with this, so a turn on a bot the user is
    /// *not* looking at still moves that bot's face in the list instead of being dropped by the
    /// "is this the open conversation" guard every branch below applies.
    private var sessionBots: [SessionID: BotID] = [:]

    /// What this bot is doing, for `BotAvatarView`. The one accessor both shells call.
    public func activity(forBot botID: BotID) -> BotAvatarActivity {
        botActivityTracker.activity(for: botID)
    }

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

    /// A compaction whose answer never reached this process because the socket went away first.
    ///
    /// Compacting is **host work**, not a phone-side request: measured 74 s, 123 s and 163 s on this
    /// profile. iOS suspends the socket the moment the app leaves the foreground (the bridge logs
    /// `client_closed` / 1001 about 200 ms after the request), so a compaction asked for and then put
    /// in a pocket threw `Software caused connection abort` at the user while the host was happily
    /// working. This record is what makes the difference between "the host refused" and "the answer
    /// had nowhere to land": it keeps the state alive across the reconnect and is settled by the next
    /// transcript that differs, or by patience running out.
    private struct CompactionWait {
        let session: SessionID
        let entriesBefore: Int
        let totalBefore: Int
        let startedAt: Date
    }
    private var compactionWait: CompactionWait?
    /// True while the running compaction's answer is known to have been lost with its socket, so a
    /// reconnect settles it. A refresh during a *live* request must never settle anything: the
    /// transcript may change for other reasons and the compaction has not started yet.
    private var compactionAnswerLost = false
    private var compactionWatchdog: Task<Void, Never>?

    /// How long a compaction may stay unaccounted for before the app stops pretending it knows.
    ///
    /// The slowest measured compaction on this host is 163 s; five minutes is comfortably past it and
    /// still short enough that nobody stares at a spinner for an afternoon.
    public static let compactionPatience: TimeInterval = 300

    /// Bumped every time a reconnect re-reads the open transcript in place.
    ///
    /// The rows are *replaced*, not cleared and refilled, so the scroll view keeps its offset — which
    /// is why a foreground left the reader somewhere in the middle of a chat instead of at its end.
    /// The shell watches this and lands at the newest message, the same rule as opening the thread.
    /// Cached rows for `visibleTranscript`, invalidated whenever `transcript` changes.
    ///
    /// The transcript is read on every body pass — the list, the search field, the context gauge —
    /// and re-filtering it each time showed up as avoidable work on long conversations. The cache is
    /// keyed by the two visibility flags as well, so a switch that hides tool calls does not keep
    /// serving the old rows.
    private var visibleTranscriptCache: (showToolCalls: Bool, showReasoning: Bool,
                                         rows: [TranscriptEntry])?

    @Published public private(set) var transcriptReloads = 0

    /// The last transcript this process saw for each session, painted the instant a chat is opened.
    ///
    /// Opening a conversation resumes it on the host, and on this box a long one is ~4 s of agent
    /// spin-up before a single row arrives — during which the screen used to be empty. These rows are
    /// what the user was just looking at, so drawing them first (and replacing them with the host's
    /// answer when it lands) turns that wait into a refresh rather than a blank pane. Memory only:
    /// the host is the authority, and a stale cache must never survive a launch.
    private var recentTranscripts: [SessionID: RecentTranscript] = [:]
    /// LRU order for `recentTranscripts`. The cache must stay small: entries carry whole
    /// transcripts, and the attachment vault already owns the image bytes a row needs to draw.
    private var recentTranscriptOrder: [SessionID] = []

    /// Rows kept per session: enough to fill a screen and its scroll-back, nothing more.
    private struct RecentTranscript {
        let entries: [TranscriptEntry]
        /// The host's own paging cursor (`session.history` takes a row id), kept so a cached page can
        /// still load its older half before the resume lands.
        let earlierCursor: Int?
        let total: Int
    }

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
    enum Keys {
        static let showReasoning = "hermes.showReasoning"
        static let reasoningExpanded = "hermey.showReasoningExpanded"
        static let showToolCalls = "hermes.showToolOutput"
        /// One stored session id per bot — the endless-chat contract (`docs/ENDLESS-CHAT.md` §2).
        static let endlessSessionPrefix = "hermes.endlessSession."
        /// The id this device reset, until something newer is published. The bridge's PUT has no
        /// "clear" (`bot_sessions.py`: a null is a 422, "never a delete"), so without this a reset
        /// device would adopt the very conversation it just forgot on its next open.
        static let endlessResetPrefix = "hermes.endlessSessionReset."
        /// Banners for a reply in a chat that is not on screen. Stored as an object, not a bool:
        /// an unset key must mean "on" for a fresh install, and `defaults.bool` answers `false`.
        static let replyNotifications = "hermey.notifications.enabled"
        /// One bot list per host: a bot quieted on the Mac is not necessarily quiet on the phone,
        /// but the same bot has to stay quiet on the device that muted it.
        static let mutedNotificationPrefix = "hermey.notifications.muted."
    }

    /// The one defaults store both apps and the phone's background refresh read.
    ///
    /// Public because `ReplyBackgroundRefresh` runs with no window and no `AppModel`: the marks it
    /// compares against are the very ones the model wrote, so it must not keep a second copy.
    public static let defaults = UserDefaults.standard

    // MARK: Cache

    /// What this device keeps on this host, and how much of it there really is.
    ///
    /// Both apps read these three values from here, so the Mac's Caching tab and the phone's Caching
    /// screen cannot disagree about a switch or a number. The store itself is `HermesKit`'s — the
    /// model only publishes what it says, because the state that matters lives on disk.
    @Published public private(set) var cachePreferences = CachePreferences.standard
    @Published public private(set) var cacheUsage = CacheUsage.empty
    /// True while a reset is being applied; the screen disables the destructive button rather than
    /// letting a second reset race the first. The switches and the limit are not gated: they are
    /// absolute writes that the store serialises, and dropping one would lose the user's choice.
    @Published public private(set) var cacheBusy = false

    /// The device's copy of what the host already said. Read-through only: the host stays the
    /// authority, so this is consulted when a read fails and refreshed whenever one succeeds.
    private let diskCache: HermesCacheStore
    /// The tail of the cache's write chain. Writes are chained rather than merely spawned: two
    /// snapshots fired a moment apart (a resume, then a turn completing) must land in the order the
    /// host produced them, or the older copy would win the race to the file.
    private var cacheWriteTask: Task<Void, Never>?

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
    /// Which session the host calls each bot's Bot Chat, so a switch is a resume and not a lookup plus a
    /// resume.
    private var canonicalChatIDCache: [String: SessionID] = [:]
    private var canonicalChatIDStamp: [String: Date] = [:]
    /// Long enough for the taps in one sitting, short enough that a Bot Chat retired on another device
    /// is picked up within the minute.
    static let canonicalChatIdentityFreshness: TimeInterval = 60
    /// One sweep at a time: a second launch trigger while the first is still walking the roster would
    /// read every bot twice.
    private var isPrefetching = false
    /// When each snapshot was taken, so a return visit inside `conversationCacheFreshness` can be
    /// answered from the cache without asking the host at all.
    private var conversationCacheStamp: [String: Date] = [:]
    /// How long a cached conversation is trusted without a round trip.
    ///
    /// Returning to a chat you left seconds ago should be instant, and the live socket already
    /// appends anything the bot says while you are away — so a resume inside this window buys
    /// nothing and costs a visible reload. Longer than this, the host is asked and the snapshot is
    /// refreshed in place.
    public static let defaultCacheFreshness: TimeInterval = 120
    /// The instance's window; a test sets it to zero to exercise the resume path, and a future
    /// setting could let a person choose it.
    public var conversationCacheFreshness: TimeInterval = AppModel.defaultCacheFreshness
    /// Bots in the order they were last *left*, so the cache can shed the oldest instead of growing
    /// with every bot the user ever clicked. Eight transcripts of a few hundred rows is small;
    /// unbounded is not.
    private var conversationCacheOrder: [String] = []
    /// A warmed snapshot costs one page of rows, so the cache covers a whole roster rather than the
    /// first eight bots: with eight, half of a sixteen-bot roster cold-started on every launch and
    /// switching to one of them still cost a full load.
    private static let conversationCacheLimit = 24

    /// The cache's bound, for the test that proves it is enforced — read from here so a change to the
    /// limit cannot silently stop the test from exercising eviction.
    static var conversationCacheLimitForTesting: Int { conversationCacheLimit }

    /// The host's newest-message stamp each snapshot already contained, per bot.
    ///
    /// Two clocks are compared all over this model — the device's and the host's — and comparing
    /// them is how a fast phone ends up either pinned to its cache for good or reloading every bot
    /// on every look. This map holds a *host* stamp and is only ever compared with another host
    /// stamp, which makes "has the host written since I took this snapshot?" a question with an
    /// honest answer.
    private var conversationCacheHostStamp: [String: Date] = [:]

    /// The host's newest-message stamp the transcript on screen already contains, per bot.
    ///
    /// The same fact for the open conversation: the re-read in `reconcileOpenChatWithHost` happens
    /// exactly when a sweep reports a stamp newer than this one.
    private var transcriptHostStamp: [String: Date] = [:]

    /// Sessions the host has said something about while this client was looking elsewhere.
    ///
    /// Every live branch in `apply(_:)` returns early for a session that is not on screen, and that
    /// is right — the transcript belongs to one bot. What was missing is the *record* that the other
    /// session moved. Without it a cached conversation could not tell "nothing has happened since I
    /// left" from "a reply landed and the event was dropped", and it answered the second case with a
    /// two-minute-old snapshot while the list row and the banner had already announced the reply
    /// (reported 2026-11-16: "the bot list and the notification know, the chat loads much later").
    private var unseenSessions: Set<SessionID> = []
    private var unseenSessionOrder: [SessionID] = []
    /// Bounded: an app left running must not accumulate every session the host ever mentioned.
    private static let unseenSessionLimit = 32

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

    /// Whether a reply on a bot that is not on screen earns a banner and a Dock/app-icon badge.
    ///
    /// Default on: the whole point of the badge is to be told. A user who turns it off keeps the
    /// in-app counts and loses only the platform layer — the two are deliberately separate, so
    /// silencing banners does not also blind the bot list.
    @Published public private(set) var replyNotificationsEnabled: Bool = true

    /// Bots the user quieted. Per host, because a bot's name means nothing on another host.
    @Published public private(set) var mutedNotificationBots: Set<String> = []

    /// Where a platform posts the banner: set by each shell (a `UNUserNotificationCenter`
    /// wrapper on macOS and iOS), nil in tests and previews.
    ///
    /// Delivery, not decision: whether a reply is worth a banner is `ReplyNotificationPolicy`'s
    /// call, made here, so the Mac and the phone cannot disagree about it.
    public var replyNotificationSink: ((ReplyNotification) -> Void)?

    /// Identities already handed to the sink, newest last and bounded. A reply reported twice —
    /// by the previews sweep and again by a later refresh — must not buzz twice.
    private var notifiedIdentities: [String] = []

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
    /// The slow clock that asks the host what the bots nobody is looking at have said.
    private var unreadSweepTask: Task<Void, Never>?
    /// Bumped whenever the selected bot changes. An in-flight `session.list` compares it before
    /// publishing, so a slow answer for the bot we left cannot overwrite the bot we are on.
    private var botEpoch = 0

    /// - Parameter cache: the device cache, injectable so a preview or a test can point it at a
    ///   throwaway directory instead of this machine's Application Support.
    public init(client: GatewayClientProtocol,
                hostName: String = "hermes",
                cache: HermesCacheStore? = nil) {
        self.client = client
        self.hostName = hostName
        self.diskCache = cache ?? HermesCacheStore(host: hostName)
        // A default only applies to a key nobody wrote: `defaults.bool(forKey:)` answers `false`
        // for an unset key, which would ship reasoning and tool output hidden on first launch.
        let defaults = Self.defaults
        showReasoning = defaults.object(forKey: Keys.showReasoning) as? Bool ?? true
        reasoningExpandedByDefault = defaults.object(forKey: Keys.reasoningExpanded) as? Bool ?? false
        showToolCalls = defaults.object(forKey: Keys.showToolCalls) as? Bool ?? true
        // Read here, not on connect: Settings can be opened before a host answers, and a toggle
        // that shows "on" until the socket comes up would be a lie about a stored choice.
        loadNotificationSettings()
        // The groups are the host's, but the last document read is cached per host: a launch with
        // no wire still draws the list the owner is used to instead of one Uncategorized bucket.
        loadCachedBotCategories()
    }

    // MARK: Cache controls

    /// Read the stored switches and measure what is actually on disk.
    ///
    /// Cheap enough to call when the Caching screen appears, and the only place `cacheUsage` is
    /// refreshed: counting files on every turn would be I/O for a number nobody is looking at.
    public func loadCacheState() async {
        cachePreferences = await diskCache.preferences()
        cacheUsage = await diskCache.usage()
    }

    /// Turn one section of the cache on or off. Turning it off deletes what it kept, in the store,
    /// before this returns — and never touches anything on the host.
    public func setCacheSection(_ section: CacheSection, enabled: Bool) async {
        cachePreferences = await diskCache.setSection(section, enabled: enabled)
        cacheUsage = await diskCache.usage()
    }

    /// Set how many chats are kept — one of `CacheChatLimit.options`; anything else lands on the
    /// nearest, because the picker and the store must never disagree about the number.
    ///
    /// Lowering it evicts immediately (chat list and transcripts both), so the Usage numbers move
    /// with the choice instead of at the next open.
    public func setCacheChatLimit(_ chats: Int) async {
        cachePreferences = await diskCache.setChatLimit(chats)
        cacheUsage = await diskCache.usage()
    }

    /// Delete everything this device cached. Switches and the limit stay as the user left them,
    /// because Reset is about storage, not preferences.
    public func resetCache() async {
        guard !cacheBusy else { return }
        cacheBusy = true
        defer { cacheBusy = false }
        await diskCache.reset()
        cacheUsage = await diskCache.usage()
        ClientLog.note("cache reset on \(hostName)", level: .info, category: "cache")
    }

    // MARK: Lifecycle

    /// Connect, then learn the bots, then read the selected bot's sessions.
    ///
    /// The order is the contract: every session row is scoped to one profile, so a list fetched
    /// before the bot is known would have to be thrown away (or worse, shown).
    public func start() async {
        connection = .connecting
        // A fresh dial is a fresh set of questions: the launch gate reads these as the app's own
        // "usable yet", and a reconnect that inherited the last session's answer would open the
        // gate on a roster that has not been read yet.
        rosterAnswered = false
        sessionsAnswered = false
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
            // After the roster, because a category heading with no bots to put in it is a heading
            // nobody can act on — and because connect/reconnect is the moment the other device's
            // new groups have to appear on this one.
            await loadBotCategories()
            await loadModelLabel()
            await loadSessions()
            startUnreadSweep()
        } catch {
            connection = .failed(error.localizedDescription)
            ClientLog.note("connect to \(hostName) failed: \(error.localizedDescription)",
                           level: .error, category: "connection")
        }
    }

    public func stop() async {
        eventTask?.cancel()
        eventTask = nil
        unreadSweepTask?.cancel()
        unreadSweepTask = nil
        await client.disconnect()
        connection = .offline
    }

    // MARK: The slow clock

    /// How often the bot list asks the host what the other bots have said.
    ///
    /// Twenty-five seconds is a compromise, not a guess at elegance: everything that raises a
    /// banner or a badge goes through `loadBotPreviews`, and without a clock of its own the model
    /// only sweeps when the list appears or the app returns to the foreground — so a window sitting
    /// in one conversation never noticed the nine others replying, which is exactly the case
    /// notifications exist for. One bridge request covers every bot (the host caches each profile's
    /// conversation for 15 s), and a host that answers slowly is not asked again until it has.
    public static let unreadSweepInterval: TimeInterval = 25

    /// Which previews read is newest, and which one has spoken. Two counters rather than a flag:
    /// requests are allowed to overlap (a pull to refresh must not wait for a sweep), and the one
    /// that started last is the one whose counts are authoritative.
    private var previewsRequestID = 0
    private var previewsAppliedID = 0

    /// A sweep already open. Not a lock — overlapping reads are allowed under `previewsRequestID`
    /// — but a non-forced call that arrives while one is open joins it instead of asking again,
    /// which is where the four-in-three-seconds bursts came from.
    private var previewsInFlight = false

    /// Start the sweep. Idempotent: two windows on one `AppModel` must not double the poll rate.
    public func startUnreadSweep() {
        guard unreadSweepTask == nil else { return }
        unreadSweepTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.connection.isLive { await self.loadBotPreviews() }
                self.noteWireSilence()
                try? await Task.sleep(for: .seconds(Self.unreadSweepInterval))
            }
        }
    }

    public func stopUnreadSweep() {
        unreadSweepTask?.cancel()
        unreadSweepTask = nil
    }

    // MARK: The wire's own heartbeat

    /// How long a turn may run with no socket event at all before the log says so.
    ///
    /// "Chats get stuck sometimes" is the one report with no shape: a turn that stops mid-stream, a
    /// spinner that never resolves. Two very different causes produce it — the host stopped talking,
    /// or this app stopped drawing what it received — and only the wire's own silence tells them
    /// apart. Nothing recorded it, so the next report was as shapeless as the first.
    private static let silenceThreshold: TimeInterval = 45

    private var lastWireEventAt = Date()
    private var lastWireEventLabel = "none yet"
    private var silenceReported = false

    private func noteWireEvent(_ event: ClientEvent) {
        lastWireEventAt = Date()
        // A short name, not the payload: the rows carry the words, this is a diagnostic line.
        lastWireEventLabel = String(describing: event).prefix(80).description
        silenceReported = false
    }

    /// Say how long the wire has been quiet, once per stall, while a turn is supposed to be running.
    ///
    /// Runs on the sweep's clock (`unreadSweepInterval`) rather than a timer of its own: one slow
    /// loop already exists, and a second one is how a client ends up polling twice as often as it
    /// meant to.
    func noteWireSilence() {
        guard isStreaming || !runningSessions.isEmpty else { return }
        let quiet = Date().timeIntervalSince(lastWireEventAt)
        guard quiet >= Self.silenceThreshold, !silenceReported else { return }
        silenceReported = true
        ClientLog.note("no socket event for \(Int(quiet))s while a turn runs "
                       + "(last: \(lastWireEventLabel); wire: \(connection.label))",
                       level: .warning, category: "connection")
    }

    // MARK: Sessions

    /// Read the bot directory (Hermes profiles) and settle on a default selection.
    ///
    /// Not fatal on failure: an older host answers `session.list` but not `profiles.list`, and one
    /// unscoped list is still better than a dead window. The reason is kept in `botsError` so the
    /// bot pane can say what happened instead of implying this host has no bots.
    public func loadBots() async {
        botsLoading = true
        // Both exits are an answer: a roster, or a reason there is none. The launch gate wants the
        // arrival, not the verdict — a failed read is handled by its own phase.
        defer {
            botsLoading = false
            rosterAnswered = true
        }
        do {
            let loaded = try await client.listBots()
            bots = loaded
            botsError = nil
            await diskCache.storeBots(loaded)
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
            // Read-through: a host that cannot answer does not mean the user has no bots. Draw the
            // last roster this device saw, with `botsError` still set so the list can say it is the
            // cached copy rather than pretending the host just answered.
            if bots.isEmpty, let cached = await diskCache.chatList(), !cached.bots.isEmpty {
                bots = cached.bots.map(\.bot)
                applyCachedPreviews(cached)
                if selectedBotID == nil {
                    selectedBotID = Self.defaultBot(in: bots, hostName: hostName)?.id
                }
                ClientLog.note("drawing \(bots.count) cached bots for \(hostName)",
                               level: .info, category: "cache")
            }
        }
    }

    /// Paint the cached third lines and times for any bot the host has not covered.
    ///
    /// Unread counts are deliberately *not* applied: a badge is a claim about right now, and a
    /// cached one would announce messages that may already have been read on another device.
    private func applyCachedPreviews(_ document: CachedChatList) {
        for (bot, preview) in document.previews where botPreviews[bot] == nil {
            if let line = Self.previewLine(preview.text) { botPreviews[bot] = line }
            if let at = Self.seconds(preview.timestamp) { botPreviewTimes[bot] = at }
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
        // A new question, so the old answer no longer stands until this one lands: the gate reads
        // `sessionsAnswered` and must not see last bot's arrival as this bot's.
        sessionsAnswered = false
        defer {
            if epoch == botEpoch {
                sessionsLoading = false
                sessionsAnswered = true
            }
        }
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
    ///
    /// The sweep then ends by reconciling the open conversation: it is the only clock in the model
    /// that can notice a message the socket never carried at all.
    public func loadBotPreviews(force: Bool = false) async {
        await readPreviews(force: force)
        await reconcileOpenChatWithHost()
    }

    /// Read every bot's newest message. `loadBotPreviews` is what callers use.
    private func readPreviews(force: Bool) async {
        let ids = bots.map(\.id)
        guard !ids.isEmpty else { return }
        if previewsInFlight && !force { return }
        previewsInFlight = true
        defer { previewsInFlight = false }

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
        // Now, which of the requests already open is this one. The list has several doors in here —
        // it appears, it is pulled to refresh, the app returns to the foreground, a turn finishes,
        // and the 25 s sweep — so the device log shows bursts of four or five reads inside three
        // seconds. Each answers with a *snapshot*, and a snapshot taken before a reply and landing
        // after one used to overwrite the count with the smaller one: the banner stood (it is
        // guarded by `lastRead`, which only moves forward) while the count went missing until the
        // next sweep. Reported 2026-11-14 as "the unread badge showed up a little late".
        previewsRequestID += 1
        let requestID = previewsRequestID

        // A read that failed is not a count of zero. The whole map used to be replaced with the
        // feed's, so one dropped request emptied every badge on the list and the next sweep filled
        // them back in — "late" again, and a lie about what is waiting either way. `nil` here means
        // "could not ask", and the last answer stands.
        // Cache-first, like the conversation pane. The list is the first thing drawn at launch and
        // one row's preview costs a request per bot on a host without the bridge route, so last
        // launch's copy goes up now and the host's answer overwrites it a moment later.
        // `applyCachedPreviews` fills only rows still empty, so it cannot win a race.
        if let cached = await diskCache.chatList() { applyCachedPreviews(cached) }

        var feed: BotPreviewFeed?
        do {
            feed = try await client.botPreviews(since: marks)
        } catch {
            ClientLog.note("bots.previews failed: \(error.localizedDescription)",
                           level: .warning, category: "sessions")
        }

        // Older than an answer this list already has: it was computed before that one and knows
        // less, so it is dropped whole rather than merged field by field.
        var fromBridge: [String: BotConversationPreview] = [:]
        if let feed, requestID >= previewsAppliedID {
            previewsAppliedID = requestID
            unreadCounts = feed.unread.filter { ids.contains($0.key) }
            fromBridge = feed.previews
        } else if feed != nil {
            fromBridge = feed?.previews ?? [:]
        }

        // Write-through after the host answered, and read-through when it did not: the third line
        // is the one piece of the list that is expensive to fetch (one request per bot on a host
        // without the bridge route), so it is worth keeping between launches.
        if let feed {
            let rows = feed.previews.filter { ids.contains($0.key) }
            let unread = feed.unread.filter { ids.contains($0.key) }
            await diskCache.storePreviews(rows.mapValues { CachedPreview($0) }, unread: unread)
        } else if let cached = await diskCache.chatList() {
            applyCachedPreviews(cached)
        }
        // The third line and the order still apply from a stale answer — they are text and time,
        // not a claim about how much is waiting.
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

    /// Re-read the open conversation when a sweep says the host has written since.
    ///
    /// The live socket is the fast path and covers a turn in progress. It is not the only writer on
    /// the host: another device's turn, an agent posting outside a run, a bot-to-bot transfer — all
    /// of those produce no `message.complete` on this socket, and until now nothing re-read an idle
    /// conversation, so the open chat was the one place that stayed behind while the row and the
    /// banner moved on (reported 2026-11-16). The refresh is in place: it neither clears the pane nor
    /// drops the pages already loaded, and `adoptResume` merges.
    private func reconcileOpenChatWithHost() async {
        guard let bot = selectedBotID, let sid = selectedSessionID, connection.isLive,
              !isStreaming, !sending, !isCompressing,
              !draftSessionIDs.contains(sid),
              latestHostStamp(for: bot) > (transcriptHostStamp[bot] ?? .distantPast) else { return }
        ClientLog.note("sweep saw a newer host message for \(bot): re-reading the open chat",
                       level: .info, category: "cache")
        await refreshTranscript(sid)
    }

    /// Retry a dropped connection without losing the open session.
    public func retryConnection() async {
        let previous = selectedSessionID
        await start()
        // `start()` swallows its own connect error into `connection`, so without this the resume
        // ran against a socket that had never come up — and painted the socket's failure as a
        // session that could not be opened.
        guard connection.isLive else { return }
        if let previous, sessions.contains(where: { $0.id == previous }) {
            await select(previous)
        }
    }

    /// Bring the wire up now instead of waiting out the reconnect backoff.
    ///
    /// Two callers know something is late before the transport does: a resume that died with the
    /// socket, and a notification about a reply this app has not drawn yet. Both used to sit through
    /// the ladder's pause (up to 30 s between attempts) because nothing outside the transport could
    /// shorten it — which is the delay behind "the message arrives after its notification".
    ///
    /// Returns whether the wire is up; `state` is read back from the client rather than from the
    /// event stream, which may not have delivered `.ready` yet.
    @discardableResult
    public func connectNow(reason: String) async -> Bool {
        if connection.isLive { return true }
        ClientLog.note("dialling now (\(reason); \(connection.label))", level: .info, category: "connection")
        await client.retryNow()
        let wire = await client.state
        if case .open = wire {
            connection = .connected
            return true
        }
        return false
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

    /// Warm every bot's conversation in the background, so opening one paints instead of waiting.
    ///
    /// Asked for on 2026-11-16: "when the app is booted, load all bot chats in the background, so that
    /// when i go to each bot it doesnt have to load it fresh every single time after bootup".
    ///
    /// This is a *read*, not an open: it resolves the same conversation id `endlessSession` would
    /// (`CanonicalBotChat.plan`, the one authority for that question) and fetches its newest page with
    /// `session.history`, which attaches no transport and cannot move the client's bound profile. A bot
    /// whose plan says `create` is skipped on purpose — a background sweep must never mint a session
    /// the person has not asked for.
    ///
    /// What it stores is deliberately marked `.distantPast` on the host stamp, so opening the bot still
    /// resumes: the snapshot is there to be *painted* while that round trip runs, not to stand in for
    /// it. Freshness would otherwise let a warm cache skip the read and leave paging on a cursor this
    /// prefetch never had.
    public func prefetchConversations() async {
        // `connection.isLive` is the pairing answer that matters here: an unpaired model has no
        // transport, and the socket is the thing this sweep reads through.
        guard connection.isLive, bots.count > 1, !isPrefetching else { return }
        isPrefetching = true
        defer { isPrefetching = false }

        let pageSize = 40
        var warmed = 0
        for bot in bots.prefix(Self.conversationCacheLimit) {
            guard connection.isLive else { break }
            // The conversation on screen has its own lifecycle; the sweep must not touch it.
            if bot.id == selectedBotID { continue }
            // Already warm and recent: another read buys nothing.
            if let stamp = conversationCacheStamp[bot.id],
               Date().timeIntervalSince(stamp) < conversationCacheFreshness,
               conversationCache[bot.id]?.entries.isEmpty == false {
                continue
            }

            // The host's own Bot Chat first — the identity that opening a bot uses — so the sweep
            // fills both the transcript cache and the identity cache in one pass. Then the sweep's
            // first switch already has the answer and costs a resume and nothing more.
            let stored: SessionID
            if let canonical = await canonicalChatIdentity(for: bot.id) {
                stored = canonical
            } else {
                let plan = CanonicalBotChat.plan(host: await canonicalChatState(for: bot.id),
                                                legacy: await bridgePointerID(for: bot.id),
                                                local: Self.defaults.string(forKey: Self.endlessKey(bot.id)))
                switch plan.step {
                case .resume(let id), .adopt(let id):
                    stored = id
                case .create:
                    // Nothing to read yet, and minting one here would be the sweep inventing a
                    // conversation. It stays empty until the person opens it.
                    continue
                }
            }

            do {
                let entries = try await client.history(stored, limit: pageSize)
                guard !entries.isEmpty else { continue }
                conversationCache[bot.id] = ConversationSnapshot(
                    sessionID: stored,
                    entries: SentAttachmentVault.decorate(entries, sessionID: stored),
                    earlierCursor: nil,
                    historyTotal: entries.count,
                    openRequests: [],
                    contextUsed: nil,
                    contextMax: nil)
                conversationCacheStamp[bot.id] = Date()
                // The sweep read this page from the host seconds ago, so it IS the host's current state
                // as of now. Recording a fake distant-past stamp made `latestHostStamp` look newer for
                // every bot and forced a full resume the moment the person opened one — the visible
                // "it preloads, then loads again" (reported 2026-11-17).
                conversationCacheHostStamp[bot.id] = Date()
                conversationCacheOrder.removeAll { $0 == bot.id }
                conversationCacheOrder.append(bot.id)
                while conversationCacheOrder.count > Self.conversationCacheLimit {
                    let evicted = conversationCacheOrder.removeFirst()
                    conversationCache.removeValue(forKey: evicted)
                    conversationCacheStamp.removeValue(forKey: evicted)
                    conversationCacheHostStamp.removeValue(forKey: evicted)
                }
                warmed += 1
            } catch {
                ClientLog.note("prefetch of \(bot.id) failed: \(error.localizedDescription)",
                               level: .info, category: "cache")
            }
            // Sequential and gentle: this runs behind a screen the person is already using, and a
            // burst of eight reads is what makes a host feel slow.
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        if warmed > 0 {
            ClientLog.note("prefetched \(warmed) conversation(s) at launch", level: .info, category: "cache")
        }
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
        conversationCacheStamp[botID] = Date()
        // What this snapshot *contains*, not what the list happens to know: `transcriptHostStamp` is
        // the host stamp the rows on screen were read at, so a sweep that landed while the
        // conversation was open cannot make a stale snapshot look current. Unknown is `.distantPast`
        // — the eager direction, one resume at worst, never a reply shown as missing.
        conversationCacheHostStamp[botID] = transcriptHostStamp[botID] ?? .distantPast
        ClientLog.note("cached \(transcript.count) rows for \(botID) before switching away",
                       level: .info, category: "cache")
        conversationCacheOrder.removeAll { $0 == botID }
        conversationCacheOrder.append(botID)
        while conversationCacheOrder.count > Self.conversationCacheLimit {
            let evicted = conversationCacheOrder.removeFirst()
            conversationCache.removeValue(forKey: evicted)
            conversationCacheHostStamp.removeValue(forKey: evicted)
        }
    }


    /// Adopt a resume's page without throwing away the pages the reader already loaded.
    ///
    /// See `TranscriptPaging.merge`: a resume carries only the newest page, so a plain assignment
    /// wiped every earlier page — and "load earlier" looked broken because the page it fetched was
    /// discarded by the next reconnect a few seconds later.
    private func adoptResume(_ entries: [TranscriptEntry], cursor: Int?, total: Int,
                             sessionID: String, botID: String? = nil) {
        // Whose rows these are, before they are merged into rows somebody else may be reading.
        let owner = botID ?? selectedBotID
        if let owner, !mayOwn(owner, writing: "a resume") { return }
        let merged = TranscriptPaging.merge(keeping: transcript, incoming: entries,
                                            incomingCursor: cursor, oldCursor: earlierCursor)
        if merged.entries.count > entries.count {
            ClientLog.note("resume kept \(merged.entries.count - entries.count) earlier rows",
                           level: .info, category: "paging")
        }
        transcript = SentAttachmentVault.decorate(merged.entries, sessionID: sessionID)
        // The scroll-jump report in one line: a transcript whose *first* row changes is a
        // transcript the reader's position cannot survive, so say when it happened and what it was
        // replaced with. Without this the app can only say that the pane moved.
        if !transcript.isEmpty, merged.entries.first?.id != transcript.first?.id {
            ClientLog.note("transcript replaced (\(transcript.count) → \(merged.entries.count) rows, "
                           + "first row \(transcript.first?.id ?? "-") → "
                           + "\(merged.entries.first?.id ?? "-"))",
                           level: .info, category: "session")
        }
        transcriptOwner = owner
        earlierCursor = merged.cursor
        historyTotal = total
    }

    /// Whether a write of `botID`'s rows may land on the transcript that is on screen.
    ///
    /// Two facts, both cheap: the bot that asked is the bot on screen, and the rows already there
    /// (if any) belong to that same bot. A refusal is logged rather than silent — a dropped adopt
    /// nobody can see is next week's mystery, and this one is *supposed* to be the quiet path.
    private func mayOwn(_ botID: String, writing what: String) -> Bool {
        guard selectedBotID == botID else {
            ClientLog.note("refused \(what) for \(botID): \(selectedBotID ?? "no bot") is on screen",
                           level: .warning, category: "session")
            return false
        }
        guard transcriptOwner == nil || transcriptOwner == botID else {
            ClientLog.note("refused \(what) for \(botID): the transcript holds "
                           + "\(transcriptOwner ?? "nobody")'s rows", level: .warning, category: "session")
            return false
        }
        return true
    }

    /// Put a remembered conversation back on screen, before any network call is made.
    ///
    /// Paint a warmed conversation for `botID`, if the background sweep filled one.
    ///
    /// Public because the conversation pane restores *before* it awaits: a spinner over a cache the app
    /// already holds is the difference between a warm launch and one that looks cold.
    @discardableResult
    public func restoreConversation(for botID: String) -> Bool {
        guard let snapshot = conversationCache[botID] else {
            ClientLog.note("no cached conversation for \(botID): the pane has to wait for a resume",
                           level: .info, category: "cache")
            return false
        }
        ClientLog.note("restored \(snapshot.entries.count) cached rows for \(botID)",
                       level: .info, category: "cache")
        selectedSessionID = snapshot.sessionID
        transcript = snapshot.entries
        transcriptOwner = botID
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
        transcriptOwner = nil
        earlierCursor = nil
        historyTotal = 0
        loadingEarlier = false
        earlierAnchor = nil
        setStreamed("")
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

    /// The host's own timestamp for the newest message it holds for a bot.
    ///
    /// `botPreviewTimes` is written from the host's answer (`previews`, or a `session.list` row), so
    /// it is a *host* stamp; comparing it with `Date()` would be comparing two clocks. It is
    /// compared only with the stamps recorded in `conversationCacheHostStamp` /
    /// `transcriptHostStamp`, never with the device's clock.
    private func latestHostStamp(for botID: String) -> Date {
        botPreviewTimes[botID] ?? .distantPast
    }

    /// The transcript on screen now contains the host's newest message for this bot.
    private func markTranscriptCurrent() {
        guard let bot = selectedBotID else { return }
        transcriptHostStamp[bot] = latestHostStamp(for: bot)
    }

    /// Remember that a session moved while it was not the one on screen.
    private func noteUnseen(_ session: SessionID) {
        guard unseenSessions.insert(session).inserted else { return }
        unseenSessionOrder.append(session)
        while unseenSessionOrder.count > Self.unseenSessionLimit {
            unseenSessions.remove(unseenSessionOrder.removeFirst())
        }
    }

    /// The session an event names, for the events that name one.
    private static func session(of event: ClientEvent) -> SessionID? {
        switch event {
        case .messageDelta(let session, _),
             .messageComplete(let session, _),
             .thinkingDelta(let session, _),
             .interimMessage(let session, _, _, _),
             .toolStart(let session, _, _, _),
             .toolProgress(let session, _, _),
             .toolComplete(let session, _, _, _, _, _),
             .contextUsage(let session, _, _, _),
             .sessionUpdated(let session):
            return session
        case .ready, .state, .request, .requestCancelled, .error, .unknown:
            return nil
        }
    }

    /// Record the transcript for a session so leaving and coming back is instant.
    private func remember(_ id: SessionID, entries: [TranscriptEntry], cursor: Int?, total: Int) {
        guard !entries.isEmpty else { return }
        // The transcript is display data, not a second image store. The vault and the disk cache
        // own bytes; keeping them here multiplies every picture by the number of remembered chats.
        let stripped = entries.map { entry -> TranscriptEntry in
            guard !entry.attachments.isEmpty else { return entry }
            let attachments = entry.attachments.map {
                SentAttachment(id: $0.id, name: $0.name, isImage: $0.isImage, imageData: nil)
            }
            return TranscriptEntry(id: entry.id, rowID: entry.rowID, role: entry.role,
                                   text: entry.text, at: entry.at, tool: entry.tool,
                                   attachments: attachments)
        }
        recentTranscripts[id] = RecentTranscript(entries: stripped, earlierCursor: cursor, total: total)
        recentTranscriptOrder.removeAll { $0 == id }
        recentTranscriptOrder.append(id)
        while recentTranscriptOrder.count > 8, let oldest = recentTranscriptOrder.first {
            recentTranscriptOrder.removeFirst()
            recentTranscripts.removeValue(forKey: oldest)
        }
    }

    /// Write the rows on screen to the device cache, without making anyone wait for the disk.
    ///
    /// Fire-and-forget on purpose: a transcript is written after a resume, a finished turn and a
    /// page load — holding those up on I/O would trade a visible speed-up for a cache. The store is
    /// an actor, so the writes serialize there, and a failure only means the next launch misses.
    private func cacheTranscriptSoon(_ id: SessionID?) {
        guard let id, !draftSessionIDs.contains(id), !transcript.isEmpty else { return }
        let entries = transcript
        let cursor = earlierCursor
        let total = historyTotal
        let previous = cacheWriteTask
        let cache = diskCache
        cacheWriteTask = Task {
            _ = await previous?.value
            await cache.storeMessages(entries, for: id, cursor: cursor, total: total)
        }
    }

    /// Put the last cached copy of a chat on screen before the host answers.
    ///
    /// Shared by both open paths — a plain `select` and the endless-chat opener — so a cold launch
    /// shows the conversation immediately instead of an empty pane for however long the resume
    /// takes. It is also what an offline launch falls back to. When the host answers, `adoptResume`
    /// merges its rows over these, keeping the cached earlier pages.
    @discardableResult
    private func paintCachedConversation(_ id: SessionID, botID: String? = nil) async -> Bool {
        guard transcript.isEmpty, let cached = await diskCache.messages(for: id) else { return false }
        let index = await diskCache.links(for: id)
        // After the reads, not before them: the point of the check is what moved while they ran.
        let owner = botID ?? selectedBotID
        if let owner, !mayOwn(owner, writing: "a cached transcript") { return false }
        selectedSessionID = id
        transcript = SentAttachmentVault.decorate(cached.messages, sessionID: id)
        if let index { transcript = index.attachMissing(to: transcript) }
        transcriptOwner = owner
        earlierCursor = cached.cursor
        historyTotal = cached.total
        turnRowStart = transcript.count
        ClientLog.note("painted \(cached.entries.count) cached rows before the resume",
                       level: .info, category: "cache")
        return true
    }

    /// The two codes the host uses for "I have never seen that session id in this process".
    private static func isUnknownSession(_ error: GatewayError) -> Bool {
        guard case .rpc(let rpc) = error else { return false }
        return rpc.code == 4001 || rpc.code == 4007
    }

    /// The host already writes a good sentence ("session busy — Hermes is still replying…"); an
    /// opaque NSError text does not help anyone decide what to do next.
    private static func compactionReason(_ error: Error) -> String {
        if case let GatewayError.rpc(rpc) = error, !rpc.message.isEmpty { return rpc.message }
        if let gateway = error as? GatewayError { return gateway.message }
        let ns = error as NSError
        // "The operation couldn't be completed. Software caused connection abort" is errno 53, which
        // is a sentence about a socket, not about the conversation the user asked to compact.
        if ns.domain == NSURLErrorDomain || ns.domain == NSPOSIXErrorDomain {
            return "the connection dropped before the host answered"
        }
        return error.localizedDescription
    }

    public func select(_ id: SessionID) async {
        selectedSessionID = id
        noteSessionOwner(id)
        // Paint what this process already knows before touching the network: a long chat costs the
        // host ~4 s to resume, and an empty pane for those seconds reads as "the app is broken".
        if let cached = recentTranscripts[id] {
            transcript = SentAttachmentVault.decorate(cached.entries, sessionID: id)
            earlierCursor = cached.earlierCursor
            historyTotal = cached.total
        } else {
            transcript = []
            earlierCursor = nil
            historyTotal = 0
        }
        // Everything above is this bot's: the session was chosen for it and the epoch that guards
        // the resume was read after the switch.
        transcriptOwner = selectedBotID
        turnRowStart = 0
        setStreamed("")
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
        // Cache-first, online or not: the device's own copy goes up immediately, and the host's
        // answer replaces it when it lands. Waiting for the resume painted an empty pane for the
        // ~4 s a long chat takes to come back, so an enabled Messages cache bought nothing while
        // the socket was live — which is the only state a launch is normally in.
        if transcript.isEmpty {
            await paintCachedConversation(id)
        }
        // A resume that is still in flight when the bot (or the session) changes must not land:
        // it carries the transcript of the thing the user just left.
        let epoch = botEpoch
        do {
            let resumed = try await client.resumeSession(id, profile: selectedBotID)
            guard epoch == botEpoch, selectedSessionID == id else { return }
            adoptResume(resumed.entries, cursor: resumed.earlierCursor,
                        total: resumed.historyTotal, sessionID: id)
            pendingRequests = resumed.openRequests
            adopt(resumed, session: id)
            remember(id, entries: transcript, cursor: resumed.earlierCursor, total: resumed.historyTotal)
            cacheTranscriptSoon(id)
        } catch is CancellationError {
            // SwiftUI cancels the `.task` when the screen goes away — backgrounding, the app
            // switcher, a pushed sheet. That is not a failed session, and surfacing it painted a
            // red "could not open this session" banner every time the user came back.
            return
        } catch {
            guard epoch == botEpoch, selectedSessionID == id else { return }
            let failure = error
            // A resume that died with the socket is not a session that cannot be opened. iOS aborts
            // an idle WebSocket and the bridge closes one that stops answering its 20 s pings, so
            // the first call after a chat has been asleep lands on a transport that is already
            // gone — and the old code painted that as a red banner that stayed until the next send.
            // Reconnect and ask once more; only a second failure is worth a sentence.
            if Self.isLostAnswer(failure) {
                await start()
                do {
                    let retried = try await client.resumeSession(id, profile: selectedBotID)
                    guard epoch == botEpoch, selectedSessionID == id else { return }
                    adoptResume(retried.entries, cursor: retried.earlierCursor,
                                total: retried.historyTotal, sessionID: id)
                    pendingRequests = retried.openRequests
                    adopt(retried, session: id)
                    remember(id, entries: transcript, cursor: retried.earlierCursor,
                             total: retried.historyTotal)
                    cacheTranscriptSoon(id)
                    ClientLog.note("session.resume recovered on a fresh socket",
                                   level: .info, category: "session")
                    return
                } catch {
                    // Fall through: the second failure is the one the reader hears about.
                }
            }
            // A session that cannot be opened is not a dead host: the socket is fine, and blaming
            // the connection here painted "cannot connect to the server" over a session-level
            // error (and then suppressed the reconnect that would have fixed a real drop).
            lastSendError = "could not open this session: \(Self.openReason(failure))"
            ClientLog.note("session.resume failed for \(id): \(failure.localizedDescription)",
                           level: .error, category: "session")
            // Read-through: the host could not answer, so draw the last copy this device kept
            // rather than an empty pane.
            await paintCachedConversation(id)
        }
    }

    /// One sentence for a failed open. The host's own refusal is worth repeating; a POSIX errno
    /// rendered as "Software caused connection abort" is not — it names the operating system's
    /// plumbing, not anything the reader can act on.
    private static func openReason(_ error: Error) -> String {
        if let gateway = error as? GatewayError {
            switch gateway {
            case .rpc(let rpc) where !rpc.message.isEmpty:
                return rpc.message
            case .timeout:
                return "the host did not answer in time"
            case .notConnected, .transportClosed:
                return "the connection dropped before the host answered"
            default:
                return gateway.message
            }
        }
        return "the connection dropped before the host answered"
    }

    /// Adopt the host's answer about the turn that was in flight.
    ///
    /// The resume is the authority, not this client's own flag: a turn that finished while the
    /// socket was down leaves no `message.complete` to receive, so an app that kept streaming set
    /// waited forever — observed as "stuck on Thinking…" with the finished reply on the host.
    /// `inflight == nil` and `streaming: false` both mean nothing more is coming; a non-streaming
    /// inflight still carries its partial text, so the bubble keeps what the model already wrote.
    private func adopt(_ resumed: SessionResume, session: SessionID) {
        noteSessionOwner(session)
        setStreamed(resumed.liveText)
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
            let localText = streamedText
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard selectedSessionID == sid else { return }
            guard let resumed = try? await client.resumeSession(sid, profile: selectedBotID) else { return }
            guard selectedSessionID == sid else { return }

            if resumed.inflight?.streaming == true {
                // Still running on the host: keep what we have, adopt its partial text only when
                // ours is empty (we may have missed the deltas that arrived while suspended).
                if streamedText.isEmpty { setStreamed(resumed.inflight?.assistantText ?? "") }
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
            adoptResume(entries, cursor: resumed.earlierCursor,
                        total: resumed.historyTotal, sessionID: sid)
            pendingRequests = resumed.openRequests
            setStreamed("")
            reasoningText = ""
            liveTools = []
            isStreaming = false
            runningSessions.remove(sid)
            return
        }
        await refreshTranscript(sid)
    }

    /// Re-read the open transcript **in place**: no empty pane, no cleared turn state, no flicker.
    ///
    /// A foreground sends `gateway.ready`, and the old path answered it with `select(sid)` — which
    /// sets `transcript = []` before the resume starts (a miss in the in-memory cache meant a blank
    /// chat for the whole 4 s host read) and resets `turnRowStart`, the live bubble and the context
    /// gauge for a conversation that was only asleep. iOS suspends the socket constantly, so this ran
    /// on every return to the app. A refresh keeps what is on screen until the host's copy replaces
    /// it, and says so with `transcriptReloads` so the shell can land at the end.
    private func refreshTranscript(_ sid: SessionID) async {
        guard !draftSessionIDs.contains(sid) else { return }
        do {
            let resumed = try await client.resumeSession(sid, profile: selectedBotID)
            guard selectedSessionID == sid else { return }
            adoptResume(resumed.entries, cursor: resumed.earlierCursor,
                        total: resumed.historyTotal, sessionID: sid)
            pendingRequests = resumed.openRequests
            adopt(resumed, session: sid)
            remember(sid, entries: transcript, cursor: resumed.earlierCursor, total: resumed.historyTotal)
            markTranscriptCurrent()
            unseenSessions.remove(sid)
            unseenSessionOrder.removeAll { $0 == sid }
            cacheTranscriptSoon(sid)
            transcriptReloads += 1
            settleCompactionWait()
        } catch is CancellationError {
            return
        } catch {
            // A failed refresh leaves the transcript that is on screen alone: it is still the last
            // thing the host said, and blanking it would invent a loss.
            ClientLog.note("transcript refresh failed: \(error.localizedDescription)",
                           level: .warning, category: "connection")
        }
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
            setStreamed("")
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
            // **A refused id is not a lost message.** The host's runtime turns over (a restart, a
            // rotation), and the id this pane is holding can be one the host no longer knows: the
            // bridge answers `4007 unknown_session` and the person sees "session not found" over a
            // chat that exists 80 messages deep. Ask the host where that bot's Bot Chat is now, adopt
            // it, and send once more — the transcript is the same conversation either way.
            if let gateway = error as? GatewayError, Self.isForgottenSession(gateway),
               let botID = selectedBotID,
               let canonical = await canonicalChatIdentity(for: botID) {
                ClientLog.note("\(sid) was refused (code \(gateway.rpcError?.code ?? 0)); "
                               + "re-sending to \(botID)'s Bot Chat \(canonical)",
                               level: .info, category: "session")
                if case .opened(let reopened) = await openStoredConversation(canonical, botID: botID,
                                                                             publish: true) {
                    Self.defaults.set(reopened, forKey: Self.endlessKey(botID))
                    do {
                        let delivery = try await client.submit(session: reopened, text: outgoing)
                        if isMidTurn { announce(delivery) }
                        draftSessionIDs.remove(reopened)
                        sending = false
                        return
                    } catch {
                        ClientLog.note("re-send after re-resolving the Bot Chat failed too: "
                                       + error.localizedDescription, level: .error, category: "send")
                    }
                }
            }
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
            setStreamed("")
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

    /// The one conversation this bot has: open the host's canonical Bot Chat, or make this bot's
    /// existing conversation into it.
    ///
    /// Hermes already has an answer to "where is the forever-chat": the session titled exactly
    /// `Bot Chat`, born hidden, resolved by name on every open, and shared by Desktop, the TUI,
    /// `hermes -p <bot> chat -c "Bot Chat"`, cron `bot-chat` delivery and bot-to-bot messages. This
    /// method opens **that** session, so the conversation here is the same conversation the official
    /// app and the desktop show — and so a routine's report or another bot's DM lands in the chat the
    /// user is actually reading. `CanonicalBotChat` holds the decision; this carries it out:
    ///
    /// 1. the host names a Bot Chat → resume its **live tip** (the id rotation compaction moves the
    ///    registry name away from);
    /// 2. the host has none, but this bot already had a Hermey conversation → open it and give it the
    ///    canonical name, so the user's history becomes the shared chat instead of being stranded
    ///    behind a fresh empty one;
    /// 3. neither → mint the canonical chat exactly as Desktop does (`title`, `hidden`,
    ///    `follow_profile_config`).
    ///
    /// The bridge pointer (`GET`/`PUT /v1/bots/{profile}/session`) demotes to a cache: it still
    /// answers for the bot list's previews and for an older build or an unreadable host, but it no
    /// longer decides which conversation the app considers this bot's. Every identity read fails
    /// open — a host that cannot be asked leaves this device on its cached conversation, and nothing
    /// about that leg lands in `lastSendError`.
    ///
    /// A stored id stays resumable until the host forgets the session: `4001` is "session not
    /// found" and `4007` is the same for an id from another profile, and only those two justify
    /// opening a new conversation. Any other failure (a timeout, a dead socket) is reported
    /// instead — starting a blank conversation over a transient error would hide the user's
    /// history behind a new empty one.
    /// Hand-picked sessions waiting to be honoured once, by bot.
    ///
    /// `endlessSession(for:)` resolves the host's canonical `Bot Chat` on every appear, so a
    /// conversation picked by hand has to be recorded here or it is overruled a moment later.
    private var pinnedSessionPicks: [String: SessionID] = [:]

    /// Open a session the user picked by hand (the All Sessions sheet) and make the pick stick.
    ///
    /// The bot is switched first because the sheet's rows are scoped to the selected bot and the
    /// model only lists sessions for the conversation it holds; the pick is recorded before the
    /// resume so an appear that lands mid-request still honours it.
    public func openSession(_ id: SessionID, for botID: String) async {
        if botID != selectedBotID {
            captureConversation(for: selectedBotID)
            resetForBotSwitch()
            selectedBotID = botID
            await loadModelLabel()
        }
        pinnedSessionPicks[botID] = id
        if selectedSessionID != id { await select(id) }
    }

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
        let restored = restoreConversation(for: botID)
        isOpeningConversation = !restored
        defer { isOpeningConversation = false }
        // A chat you left seconds ago is already on screen, so asking the host again only reloads
        // what the person is reading — **unless something arrived since**, which the cache cannot
        // know and the socket may not have said: a reply to a bot that was not on screen is dropped
        // by every branch of `apply(_:)`, not buffered. The row and the banner learn about it from
        // the sweep, so a pane opened on the strength of that banner used to paint the reply's
        // absence and make no host read at all for up to two minutes.
        //
        // Two facts, both already in hand, decide it: `unseenSessions` (the socket named a session
        // that is not the one on screen) and the host's own newest stamp for this bot against the
        // stamp this snapshot contained. Neither compares the host's clock with ours.
        let hostIsAhead = latestHostStamp(for: botID) > (conversationCacheHostStamp[botID] ?? .distantPast)
        let socketSaidSo = selectedSessionID.map { unseenSessions.contains($0) } ?? false
        if restored, pinnedSessionPicks[botID] == nil, connection.isLive,
           let stamp = conversationCacheStamp[botID],
           Date().timeIntervalSince(stamp) < conversationCacheFreshness,
           !hostIsAhead, !socketSaidSo {
            ClientLog.note("returned to \(botID) from cache "
                           + "(\(Int(Date().timeIntervalSince(stamp)))s old), no resume",
                           level: .info, category: "cache")
            return selectedSessionID
        }
        // A pick made in All Sessions outranks the canonical chat exactly once, and it is checked
        // after the cached paint (a pick may have nothing cached, and the pane must not flash
        // empty while the resume runs) and before the canonical plan (which would otherwise resume
        // `Bot Chat` and replace the conversation the user just chose). Consumed here, so the
        // *following* visit goes back to the bot's endless conversation, which must not drift.
        if let picked = pinnedSessionPicks.removeValue(forKey: botID) {
            await loadModelLabel()
            await select(picked)
            return selectedSessionID
        }
        await loadModelLabel()
        // **One authority: the host's own canonical chat, found by identity.** The host keeps exactly
        // one endless conversation per bot as a row titled "Bot Chat" in that bot's own store, and its
        // id is durable (aria's, for instance, survived a `ws_orphan_reap` with its 80 messages). The
        // hero client never stores an id at all — it looks the identity up — which is why it has no
        // session problems to have. Anything this device remembered is a hint at best: a runtime id
        // stops resolving the moment the host's runtime turns over, and the ladder below then used to
        // mint a blank conversation over one that still existed.
        if let canonical = await canonicalChatIdentity(for: botID) {
            if case .opened(let opened) = await openStoredConversation(canonical, botID: botID, publish: true) {
                Self.defaults.set(opened, forKey: Self.endlessKey(botID))
                return opened
            }
            ClientLog.note("the host's own Bot Chat for \(botID) (\(canonical)) would not open; "
                           + "falling back to the remembered ids", level: .info, category: "session")
        }
        let key = Self.endlessKey(botID)
        let plan = CanonicalBotChat.plan(host: await canonicalChatState(for: botID),
                                        legacy: await bridgePointerID(for: botID),
                                        local: Self.defaults.string(forKey: key))
        switch plan.step {
        case .resume(let stored):
            switch await openStoredConversation(stored, botID: botID, publish: plan.publishCache) {
            case .opened(let opened): return opened
            case .failed: return nil
            // The host forgot that id. Before minting a blank conversation, adopt the newest one this
            // bot actually has — a stale id is not the same thing as an empty bot, and treating it as
            // one is what made an existing conversation look deleted.
            case .forgotten:
                if let recovered = await newestExistingConversation(for: botID),
                   recovered != stored,
                   case .opened(let opened) = await openStoredConversation(recovered, botID: botID,
                                                                          publish: plan.publishCache) {
                    ClientLog.note("recovered \(botID)'s conversation as \(recovered) after \(stored) "
                                   + "was refused", level: .info, category: "session")
                    return opened
                }
                return await mintCanonicalChat(for: botID)
            }
        case .adopt(let stored):
            switch await openStoredConversation(stored, botID: botID, publish: plan.publishCache) {
            case .opened(let opened):
                // The conversation this bot already had becomes the shared chat. Doing this after
                // the resume, not before, keeps a failed open from renaming a session the user
                // never got to see.
                await adoptAsCanonicalChat(opened, botID: botID)
                return opened
            case .failed: return nil
            case .forgotten: return await mintCanonicalChat(for: botID)
            }
        case .create:
            return await mintCanonicalChat(for: botID)
        }
    }

    /// What an attempt to open a stored conversation came to.
    enum OpenOutcome {
        case opened(SessionID)
        /// The host answered `4001`/`4007`: this id no longer exists for this bot.
        case forgotten
        /// Reported to the user; the conversation is not open.
        case failed
    }

    /// Resume one stored id and put it on screen.
    ///
    /// A cold start is the case this got wrong. The socket may still be coming up, and the first
    /// resume then failed as a *transport* failure — which reached the user as "could not open the
    /// conversation: … Software caused connection abort" with the cached transcript behind a banner,
    /// and no retry anywhere, so the only cure was to back out of the bot and come in again.
    ///
    /// A transport failure now dials once (silently, ahead of the backoff) and asks again. A resume
    /// the host *refused* — `4001`/`4007`, a forgotten id — is still never papered over: that path is
    /// unchanged, because replacing it is how a live conversation gets mistaken for an empty bot.
    func openStoredConversation(_ stored: SessionID, botID: String,
                                publish: Bool) async -> OpenOutcome {
        // Read *before* the first await: a bot switch (or a second open) moves `botEpoch` while the
        // resume is in flight, and the answer that lands afterwards belongs to a conversation the
        // user has already left. That late write is the "a bot's window shows another bot's
        // messages" report — it lands in whichever window is now on screen.
        let epoch = botEpoch
        // Cache-first here too: the stored id is resumed the slow way, so the copy this device
        // already has belongs on screen now rather than after the call returns.
        if transcript.isEmpty {
            await paintCachedConversation(stored, botID: botID)
        }
        do {
            try await adoptStoredConversation(stored, botID: botID, publish: publish,
                                              epoch: epoch)
            return .opened(stored)
        } catch is CancellationError {
            // Leaving the screen cancels the open-in-flight; the next visit resumes normally.
            return .failed
        } catch {
            if let gateway = error as? GatewayError, Self.isForgottenSession(gateway) {
                return await forgetStoredConversation(stored, botID: botID)
            }
            guard TransportFailure.isTransport(error) else {
                return await reportOpenFailure(error, stored: stored, botID: botID)
            }
            // One silent retry, never two: a socket that is still down after a forced dial is a
            // failure the user has to see.
            ClientLog.note("resume of \(stored) hit the transport (\(error.localizedDescription)); "
                           + "reconnecting once", level: .warning, category: "session")
            guard await connectNow(reason: "a resume hit a dead socket") else {
                return await reportOpenFailure(error, stored: stored, botID: botID)
            }
            do {
                try await adoptStoredConversation(stored, botID: botID, publish: publish,
                                              epoch: epoch)
                return .opened(stored)
            } catch is CancellationError {
                return .failed
            } catch {
                if let gateway = error as? GatewayError, Self.isForgottenSession(gateway) {
                    return await forgetStoredConversation(stored, botID: botID)
                }
                return await reportOpenFailure(error, stored: stored, botID: botID)
            }
        }
    }

    /// One resume, applied to the screen. Throws so the caller decides what a failure means: a
    /// forgotten id is recoverable, a dead socket is retryable, anything else is the user's to read.
    ///
    /// `epoch` is `botEpoch` as it stood when the open began. A resume that answers after a bot
    /// switch is thrown away rather than drawn: the rows belong to the conversation the user left.
    private func adoptStoredConversation(_ stored: SessionID, botID: String,
                                         publish: Bool, epoch: Int) async throws {
        let resumed = try await client.resumeSession(stored, profile: botID)
        // After the await, never before it: the counter exists to notice what moved while we waited.
        guard epoch == botEpoch, selectedBotID == botID else {
            ClientLog.note("dropped a resume for \(botID) (\(stored)): "
                           + "\(selectedBotID ?? "no bot") is on screen now",
                           level: .info, category: "session")
            throw CancellationError()
        }
        selectedSessionID = stored
        adoptResume(resumed.entries, cursor: resumed.earlierCursor,
                    total: resumed.historyTotal, sessionID: stored, botID: botID)
        pendingRequests = resumed.openRequests
        adopt(resumed, session: stored)
        markTranscriptCurrent()
        unseenSessions.remove(stored)
        unseenSessionOrder.removeAll { $0 == stored }
        captureConversation(for: botID)
        cacheTranscriptSoon(stored)
        // Whatever actually opened is the best cache this device can keep — including a host id
        // that replaced a different local one. The DURABLE key is what gets stored: the runtime id
        // is minted per attach and stops resolving when the host's runtime goes away, which is how
        // a device ends up being told "session not found" about its own conversation and opening a
        // blank one instead (seen live 2026-11-16 22:48 for `aria`).
        Self.defaults.set(resumed.storedSessionID ?? stored, forKey: Self.endlessKey(botID))
        if publish {
            await publishSharedSession(stored, for: botID)
        }
    }

    /// The host does not know this id any more: drop the hint, keep the cache honest, and let the
    /// caller mint or adopt a real conversation.
    private func forgetStoredConversation(_ stored: SessionID, botID: String) async -> OpenOutcome {
        // Forget it locally too, so an offline open does not retry a dead id.
        Self.defaults.removeObject(forKey: Self.endlessKey(botID))
        await diskCache.discard(stored)
        return .forgotten
    }

    /// Say why the open failed, and put whatever this device already had back on screen.
    private func reportOpenFailure(_ error: Error, stored: SessionID,
                                   botID: String) async -> OpenOutcome {
        lastSendError = "could not open the conversation: \(error.localizedDescription)"
        ClientLog.note("resume of the stored session failed: \(error.localizedDescription)",
                       level: .error, category: "session")
        await paintCachedConversation(stored, botID: botID)
        return .failed
    }

    /// The id of the host's canonical chat for this bot, or nil when it has none yet.
    ///
    /// The host's own rule: one endless conversation per bot, titled `Bot Chat`, living in that bot's
    /// store. `aria`'s carries `ws_orphan_reap` as its end reason and still holds its 80 messages,
    /// because the host exempts that row from reaping and un-archives it after an accident (#92687) —
    /// lifetime rules a client cannot invent, only use. Hidden rows are preferred; a row filed by hand
    /// under the same name is only taken when no hidden one exists.
    func canonicalChatIdentity(for botID: String) async -> SessionID? {
        // One lookup per bot per `canonicalChatIdentityFreshness`: the answer is the Bot Chat's name,
        // which does not change between two taps, and asking again is a whole round trip in front of a
        // conversation the person is waiting for.
        if let cached = canonicalChatIDCache[botID],
           let stamp = canonicalChatIDStamp[botID],
           Date().timeIntervalSince(stamp) < Self.canonicalChatIdentityFreshness {
            return cached
        }
        guard connection.isLive else { return canonicalChatIDCache[botID] }
        do {
            let sessions = try await client.listSessions(limit: 20, profile: botID, includeHidden: true)
            guard let id = sessions.first(where: { $0.title == CanonicalBotChat.title })?.id else {
                return nil
            }
            canonicalChatIDCache[botID] = id
            canonicalChatIDStamp[botID] = Date()
            return id
        } catch {
            ClientLog.note("could not look up \(botID)'s Bot Chat: \(error.localizedDescription)",
                           level: .info, category: "session")
            return nil
        }
    }

    /// The newest conversation this bot already has, or nil when it genuinely has none.
    ///
    /// A stored id that no longer resolves used to send the app straight to `.create`, which is how a
    /// conversation that still existed on the host appeared to be gone: the person opened the bot, got a
    /// blank chat, and their history was only reachable through All Sessions. The roster can answer this
    /// — one read, newest first — so the recovery adopts it instead of inventing a new one.
    func newestExistingConversation(for botID: String) async -> SessionID? {
        do {
            let sessions = try await client.listSessions(limit: 20, profile: botID, includeHidden: true)
            // The Bot Chat by name first — that is the host's own identity for the endless chat. Then
            // the newest conversation that actually holds messages: a bot's store is full of untitled
            // zero-message sessions, and adopting one of those opened a 545-message bot blank (crony,
            // atlas and anika, reported 2026-11-17).
            if let named = sessions.first(where: { $0.title == CanonicalBotChat.title })?.id {
                return named
            }
            return (sessions.first { $0.messageCount > 0 } ?? sessions.first)?.id
        } catch {
            Self.noteSessionSync("could not list “\(botID)”'s conversations: \(error.localizedDescription)")
            return nil
        }
    }

    /// What the host says this bot's canonical chat is, or `.unavailable` when it cannot be asked.
    ///
    /// Never throws and never surfaces an error: an identity read that failed must not put a message
    /// in front of a conversation that can still open from the cache.
    private func canonicalChatState(for botID: String) async -> CanonicalBotChat.HostState {
        do {
            return try await client.canonicalBotChat(forProfile: botID)
        } catch {
            Self.noteSessionSync("could not read the host's Bot Chat for “\(botID)”: "
                                 + "\(error.localizedDescription); using this device's conversation")
            return .unavailable
        }
    }

    /// The bridge's pointer, when it answered with something resumable.
    private func bridgePointerID(for botID: String) async -> String? {
        if case .value(let id) = await sharedSessionPointer(for: botID) { return id }
        return nil
    }

    /// Name an existing conversation `Bot Chat`, making it the host's canonical chat.
    ///
    /// Best-effort by design: a failure here leaves the conversation open and working, just not
    /// shared with Desktop and the official app, which is strictly better than refusing to open it.
    private func adoptAsCanonicalChat(_ stored: SessionID, botID: String) async {
        do {
            try await client.titleSession(stored, title: CanonicalBotChat.title, profile: botID)
            ClientLog.note("named \(stored) “\(CanonicalBotChat.title)” for \(botID): this bot's "
                           + "conversation is now the shared one",
                           level: .info, category: "session")
        } catch {
            if CanonicalBotChat.isTitleConflict(error) {
                // Another row holds the name — the other device, or Desktop, minted the Bot Chat
                // while this one was opening its legacy conversation. Do not fight it: the next open
                // resolves the host's row and lands there.
                Self.noteSessionSync("“\(botID)” already had a Bot Chat on the host; the conversation "
                                     + "opened here stays separate until the next open")
                return
            }
            Self.noteSessionSync("could not name \(stored) “\(CanonicalBotChat.title)” for “\(botID)”: "
                                 + "\(error.localizedDescription)")
        }
    }

    /// Mint this bot's canonical Bot Chat (`title` + `hidden`, exactly as Desktop does).
    ///
    /// The two recoverable failures both mean "a canonical chat exists already", and neither should
    /// ever be shown as "could not start a conversation":
    ///
    /// * the host refuses the name because a row holds it — if that row is the conversation this
    ///   device just reset, retire it and mint (bounded once, so two devices resetting at each other
    ///   cannot ping-pong); otherwise open the row that holds it, because minting a second
    ///   conversation next to a real Bot Chat is the failure Desktop documents as "retry, never
    ///   mint";
    /// * the gateway is too old to accept `title`/`hidden` at create — fall back to the
    ///   pre-canonical plain create rather than leaving the user with no conversation at all.
    private func mintCanonicalChat(for botID: String, retrying: Bool = false) async -> SessionID? {
        do {
            let created = try await client.createCanonicalSession(profile: botID,
                                                                 idempotencyKey: "bot-chat:\(botID)")
            return await adoptCreated(created, botID: botID)
        } catch {
            if CanonicalBotChat.isTitleConflict(error), !retrying {
                var holder: SessionID?
                if case .canonical(let existing) = await canonicalChatState(for: botID) {
                    holder = existing
                }
                if let holder {
                    if Self.defaults.string(forKey: Self.resetKey(botID)) == holder {
                        await retireCanonicalChat(holder, botID: botID)
                        return await mintCanonicalChat(for: botID, retrying: true)
                    }
                    Self.noteSessionSync("“\(botID)” already has a Bot Chat on the host; opening it "
                                         + "instead of creating a second")
                    if case .opened(let opened) = await openStoredConversation(holder, botID: botID,
                                                                              publish: true) {
                        return opened
                    }
                    return nil
                }
            }
            if CanonicalBotChat.isUnsupported(error), !retrying {
                Self.noteSessionSync("this host does not accept a titled create for “\(botID)”; "
                                     + "opening a plain conversation")
                return await mintPlainConversation(for: botID)
            }
            lastSendError = "could not start a conversation: \(error.localizedDescription)"
            ClientLog.note("session.create for \(botID) failed: \(error.localizedDescription)",
                           level: .error, category: "session")
            return nil
        }
    }

    /// The pre-canonical create: no title, no hidden flag. Only reached on a host that refuses both.
    private func mintPlainConversation(for botID: String) async -> SessionID? {
        do {
            let created = try await client.createSession(model: nil, provider: nil, profile: botID,
                                                         idempotencyKey: "bot-chat:\(botID)")
            return await adoptCreated(created, botID: botID)
        } catch {
            lastSendError = "could not start a conversation: \(error.localizedDescription)"
            ClientLog.note("session.create for \(botID) failed: \(error.localizedDescription)",
                           level: .error, category: "session")
            return nil
        }
    }

    /// Put a just-created conversation on screen and record it everywhere it is worth recording.
    ///
    /// The row does not exist until the first prompt, so this is a draft: marking it before `select`
    /// keeps that resume from answering `4007` and reporting an unreachable host. The publish always
    /// happens — a conversation this device just minted cannot already be the bridge's answer.
    private func adoptCreated(_ created: SessionID, botID: String) async -> SessionID {
        Self.defaults.set(created, forKey: Self.endlessKey(botID))
        draftSessionIDs.insert(created)
        await select(created)
        await publishSharedSession(created, for: botID)
        return created
    }

    /// Retire a Bot Chat the way Desktop does: archive it, so its history is kept and the next open
    /// mints a fresh canonical chat.
    ///
    /// The rename is the second half, and it exists only for a row this app *adopted*: the host
    /// frees the exact title of an **archived and hidden** row on the next create on its own (the
    /// canonical shape), but a visible row keeps its name, and an adopted row is visible. Refusal is
    /// expected — and logged quietly — for the hidden case, where the identity guard declines by
    /// design.
    private func retireCanonicalChat(_ stored: SessionID, botID: String) async {
        do {
            try await client.archiveSession(stored, profile: botID)
        } catch {
            Self.noteSessionSync("could not archive the Bot Chat for “\(botID)”: "
                                 + "\(error.localizedDescription)")
        }
        let retired = "\(CanonicalBotChat.title) · retired \(Self.retiredStamp())"
        do {
            try await client.titleSession(stored, title: retired, profile: botID)
        } catch {
            let reason = error.localizedDescription
            if !reason.lowercased().contains("canonical") {
                Self.noteSessionSync("could not rename the retired Bot Chat for “\(botID)”: \(reason)")
            }
        }
    }

    private static func retiredStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }

    /// Forget this bot's conversation so the next open starts a new one.
    ///
    /// Only the stored id is cleared here: the session itself stays on the host, because deleting
    /// history is not what "reset" on this screen means (and the host refuses to delete a session
    /// it still holds live). `resetConversation` retires it properly — archives it, so the host stops
    /// calling it the bot's Bot Chat and the next open can mint a successor with that name. The clear
    /// is published to the bridge as well — otherwise the other device would keep reopening the
    /// conversation, and the next open here would adopt it back from the host.
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
        // A reset conversation must not come back from the disk cache either — that is exactly the
        // resurrection the in-memory cache already guards against.
        if let stored, !stored.isEmpty {
            Task { await diskCache.discard(stored) }
        }
        guard let stored, selectedSessionID == stored else { return }
        // The conversation on screen is the one just forgotten: leaving its bubbles up would let
        // the user keep typing into a session nothing will reopen.
        conversationCache.removeValue(forKey: botID)
        conversationCacheOrder.removeAll { $0 == botID }
        selectedSessionID = nil
        transcript = []
        pendingRequests = []
        setStreamed("")
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
        let retired = Self.defaults.string(forKey: Self.endlessKey(bot))
        resetEndlessSession(for: bot)
        // Retire on the host *before* opening again: an archived Bot Chat stops being the canonical
        // row, so the open below mints the fresh conversation the user asked for instead of being
        // resolved straight back into the one they just reset. Best-effort — a failure only means the
        // open takes the "this bot already has a Bot Chat" path.
        if let retired, !retired.isEmpty {
            await retireCanonicalChat(retired, botID: bot)
        }
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
        // Set the guard before the first await. The old order left a window where a second tap —
        // a double-click, or a retry while the first was still opening the session — saw
        // `isCompressing == false` again and started a second compaction on the same conversation.
        isCompressing = true
        // A bot whose conversation has not been opened in this process has no session id yet.
        // Compacting is a verb on that conversation, so it opens it rather than staying greyed out.
        if selectedSessionID == nil, let bot = selectedBotID {
            _ = await endlessSession(for: bot)
        }
        guard let sid = selectedSessionID else { return finishCompaction() }
        compactionWait = CompactionWait(session: sid, entriesBefore: transcript.count,
                                        totalBefore: historyTotal, startedAt: Date())
        do {
            do {
                try await client.compress(session: sid)
            } catch let error as GatewayError where Self.isUnknownSession(error) {
                // The button was dead for a reason worth writing down: `session.compress` addresses a
                // session by the **runtime** id, and this process only learns that id from a resume.
                // A session restored from the last launch has no mapping, so the host answered 4001
                // "session not found" for a conversation sitting right there on screen. Opening it
                // first records the mapping; the retry is the same call the user asked for.
                ClientLog.note("session.compress: opening the session first (\(error.localizedDescription))",
                               level: .info, category: "compaction")
                await refreshTranscript(sid)
                guard selectedSessionID == sid else { return finishCompaction() }
                try await client.compress(session: sid)
            }
            // Refresh first, then report: the notice is set last so nothing inside the refresh can
            // overwrite it, and the context gauge is cleared because it showed the *pre*-compaction
            // size. The next turn's `usage` is the first honest number after a compaction.
            await refreshTranscript(sid)
            contextUsed = nil
            compactionNotice = "conversation compacted"
            finishCompaction()
        } catch {
            if Self.isLostAnswer(error) {
                // The socket went away; the host did not. Keep saying so, and let the next reconnect
                // settle it: a transcript that differs means it landed, and patience bounds the wait.
                compactionAnswerLost = true
                compactionNotice = "compacting… the host keeps working while the app is away"
                ClientLog.note("session.compress: no answer in this socket (\(error.localizedDescription))"
                               + " — the host may still be working",
                               level: .warning, category: "compaction")
                // Nothing may promise "still working" forever: if no reconnect ever settles it, the
                // app says it no longer knows rather than spinning for an afternoon.
                compactionWatchdog?.cancel()
                compactionWatchdog = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Self.compactionPatience))
                    guard !Task.isCancelled, let self, self.compactionWait != nil else { return }
                    self.compactionNotice =
                        "compacting did not report back — open the chat again to see where it stands"
                    self.finishCompaction()
                }
                return
            }
            // Say it in the place the header already draws. A silent failure is why this looked like
            // a dead button: the error only ever reached `lastSendError`, which nothing renders.
            let reason = Self.compactionReason(error)
            lastSendError = "could not compact: \(reason)"
            compactionNotice = "could not compact — \(reason)"
            ClientLog.note("session.compress failed: \(reason)", level: .error, category: "compaction")
            finishCompaction()
        }
    }

    /// Clear the compaction state — both the spinner and the wait for a lost answer.
    private func finishCompaction() {
        compactionWatchdog?.cancel()
        compactionWatchdog = nil
        compactionWait = nil
        compactionAnswerLost = false
        isCompressing = false
    }

    /// Was this a request that simply never got its answer, rather than a refusal?
    ///
    /// A compaction is minutes of host work; iOS tears the socket down when the app is backgrounded,
    /// so `transportClosed("… Software caused connection abort")`, `notConnected`, a URLError and a
    /// POSIX 53/54/60 are all "the answer had nowhere to land". None of them mean the host said no.
    private static func isLostAnswer(_ error: Error) -> Bool {
        if let gateway = error as? GatewayError {
            switch gateway {
            case .notConnected, .transportClosed:
                return true
            case .timeout(let method, _):
                return method == "session.compress"
            default:
                return false
            }
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return [-1001, -1003, -1004, -1005, -1009].contains(ns.code)
        }
        if ns.domain == NSPOSIXErrorDomain {
            return [53, 54, 57, 60].contains(ns.code)  // ECONNABORTED, ECONNRESET, ENOTCONN, ETIMEDOUT
        }
        return false
    }

    /// Settle a compaction that outlived its socket, from the transcript the host just handed back.
    ///
    /// Compacting rewrites the conversation, so *any* change in what the host holds is the outcome —
    /// and no change after `compactionPatience` is an honest "I no longer know", not silence.
    private func settleCompactionWait() {
        guard compactionAnswerLost,
              let wait = compactionWait, wait.session == selectedSessionID else { return }
        if transcript.count != wait.entriesBefore || historyTotal != wait.totalBefore {
            compactionNotice = "conversation compacted"
            finishCompaction()
        } else if Date().timeIntervalSince(wait.startedAt) > Self.compactionPatience {
            compactionNotice = "compacting did not report back — open the chat again to see where it stands"
            finishCompaction()
        }
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

    /// Consecutive tokens become one frame: at most one publish per 40 ms, which is a little over two
    /// frames at 60 Hz and well under the rate a model writes.
    private func appendStreamed(_ text: String) {
        streamedText += text
        guard streamFlush == nil else { return }
        streamFlush = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard let self else { return }
            self.streamFlush = nil
            if self.streamingText != self.streamedText { self.streamingText = self.streamedText }
        }
    }

    /// Set both copies at once — every place that starts, resumes or ends a live turn — so the drawn
    /// value can never trail the true one through a state change.
    private func setStreamed(_ value: String) {
        streamFlush?.cancel()
        streamFlush = nil
        streamedText = value
        if streamingText != value { streamingText = value }
    }

    /// When each bot's conversation was last looked at, by this device.
    ///
    /// What the live bubble prints: only the words no row has printed yet.
    ///
    /// The host streams a commentary and also seals it as `message.interim`, which becomes a row of
    /// its own with a time stamp. Both then showed the same paragraph — one of them with a caret
    /// under it — and it collapsed into a single one the moment the turn settled.
    public var visibleStreamingText: String {
        TranscriptVisibility.streamingRemainder(streamedText.isEmpty ? streamingText : streamedText,
                                                afterRows: turnAssistantRows)
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
            // Marked at the newest message the *host* has reported, not at this device's clock. The
            // comparison that lights a row is against host timestamps, so a phone whose clock runs
            // even a minute fast would write a mark in the host's future and then never light that
            // bot again — the silence this is here to prevent.
            markRead(botID, at: hostActivityStamp(botID) ?? Date())
        }
    }

    /// The host's own timestamp for a bot's newest message, when the sweep has reported one.
    private func hostActivityStamp(_ botID: String) -> Date? {
        botPreviewTimes[botID]
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
        // The same clock rule as `setVisibleBot`: the host's newest message is the mark, so a fast
        // device clock cannot place every future reply behind it.
        for id in ids { markRead(id, at: hostActivityStamp(id) ?? date) }

        unreadBots.removeAll()
        unreadCounts.removeAll()

        // A room is read up to its own latest seq, not to a number this side invents: a mark past
        // the host's counter would hide the room's next message for good.
        for room in rooms where roomUnreadCounts[room.id] != nil {
            markRoomRead(room.id, seq: room.latestSeq ?? 0)
        }
        roomUnreadCounts.removeAll()
    }

    /// Marks one bot unread by hand — the dot is a reminder, not a measurement.
    ///
    /// Reading a chat moves the mark forward and never back (that is what stops a badge
    /// reappearing), so "I want to come back to this" needs its own door: the mark is moved to
    /// just behind the newest message this device knows about. That makes the host count exactly
    /// that message — one unread, not the whole history — and the dot goes up now rather than at
    /// the next sweep (asked for 2026-11-15).
    public func markUnread(_ botID: String) {
        guard !botID.isEmpty else { return }
        let newest = botPreviewTimes[botID] ?? Date()
        lastRead[botID] = newest.addingTimeInterval(-1)
        Self.defaults.set(lastRead.mapValues(\.timeIntervalSince1970), forKey: lastReadKey)
        unreadBots.insert(botID)
        if (unreadCounts[botID] ?? 0) == 0 { unreadCounts[botID] = 1 }
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
            if date > seen {
                unreadBots.insert(botID)
                // A floor under the number, at the same instant the banner goes up. The count
                // normally travels in the same answer as the timestamp, but it is a *snapshot*
                // that a slower answer can regress and a failed one can empty, so the badge used
                // to lag the banner by a sweep ("showed up a little late", 2026-11-14). One is not
                // a guess: the host has just been seen to write after our mark. The next read
                // replaces it with the exact number.
                if (unreadCounts[botID] ?? 0) == 0 { unreadCounts[botID] = 1 }
                raiseReplyNotification(for: botID, at: date)
            }
        } else {
            // First sight of a bot on this device: its history is not "unread", so seed the mark
            // with the newest message instead of lighting every row on first launch.
            lastRead[botID] = date
            Self.defaults.set(lastRead.mapValues(\.timeIntervalSince1970), forKey: lastReadKey)
        }
    }

    public func hasUnread(_ botID: String) -> Bool { unreadBots.contains(botID) }

    /// Everything waiting on this device, for the Dock tile and the app icon.
    ///
    /// One number covering bots and rooms: the user is looking at one badge, and a badge that
    /// counted only bots would read `3` while four things were waiting.
    public var badgeCount: Int {
        ReplyNotificationPolicy.badge(unread: unreadCounts, rooms: roomUnreadCounts)
    }

    /// Turn banners and platform badges on or off. The in-app counts are untouched: this is one
    /// layer, and the settings copy says so.
    public func setReplyNotifications(enabled: Bool) {
        guard replyNotificationsEnabled != enabled else { return }
        replyNotificationsEnabled = enabled
        Self.defaults.set(enabled, forKey: Keys.replyNotifications)
    }

    public func isNotificationMuted(_ botID: String) -> Bool { mutedNotificationBots.contains(botID) }

    /// Quiet one bot. Kept in the model rather than `@AppStorage` per row: the decision is made
    /// once, in `raiseReplyNotification`, and a per-view store would let a row and the policy
    /// disagree about the same bot.
    public func toggleNotificationMute(_ botID: String) {
        guard !botID.isEmpty else { return }
        if mutedNotificationBots.contains(botID) {
            mutedNotificationBots.remove(botID)
        } else {
            mutedNotificationBots.insert(botID)
        }
        Self.defaults.set(mutedNotificationBots.sorted(), forKey: mutedNotificationsKey)
    }

    private var mutedNotificationsKey: String { Keys.mutedNotificationPrefix + hostName }

    private func loadNotificationSettings() {
        // An absent key means "never chosen", and the answer for a fresh install is on.
        replyNotificationsEnabled = Self.defaults.object(forKey: Keys.replyNotifications) as? Bool ?? true
        mutedNotificationBots = Set(Self.defaults.stringArray(forKey: mutedNotificationsKey) ?? [])
    }

    /// Hand a newly arrived reply to whatever posts banners on this platform.
    ///
    /// Called from `noteRemoteActivity`, which is the one place the model learns "the host wrote
    /// something newer than this device has seen" for a bot that is not on screen — so the
    /// banner question is answered from the same evidence the unread badge uses.
    private func raiseReplyNotification(for botID: String, at date: Date) {
        guard ReplyNotificationPolicy.shouldDeliver(botID: botID,
                                                    visibleBotID: visibleBotID,
                                                    enabled: replyNotificationsEnabled,
                                                    muted: mutedNotificationBots) else { return }
        let displayName = bots.first { $0.id == botID }?.displayName
        let note = ReplyNotification(
            botID: botID,
            botName: ReplyNotificationPolicy.title(botName: displayName, botID: botID),
            body: ReplyNotificationPolicy.body(botPreviews[botID]),
            badge: badgeCount,
            at: date)
        guard !notifiedIdentities.contains(note.identity) else { return }
        notifiedIdentities.append(note.identity)
        if notifiedIdentities.count > 200 { notifiedIdentities.removeFirst(notifiedIdentities.count - 200) }
        replyNotificationSink?(note)
    }

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

    // MARK: Categories

    /// The owner's groups of bots, as the host has them. One file on the host, so the other app
    /// shows the same groups; this copy is a cache of the last answer, never a second source.
    @Published public private(set) var botCategoryState: BotCategoryState = .empty

    public var botCategories: [BotCategory] { botCategoryState.categories }

    public func categoryID(for botID: String) -> String? { botCategoryState.categoryID(for: botID) }

    private var botCategoriesKey: String { "hermes.botCategories.\(hostName)" }

    /// Which category read is the newest. A slow answer for a document that has since been written
    /// over must not be published, exactly like `botEpoch` for the session list.
    private var categoryToken = 0

    /// Draw the last document this host answered with, before any wire exists. Read-only: an
    /// assignment made offline is refused (and said so) rather than queued into a second truth
    /// that the host would overwrite at the next connect anyway.
    private func loadCachedBotCategories() {
        guard let data = Self.defaults.data(forKey: botCategoriesKey),
              let cached = try? JSONDecoder().decode(BotCategoryState.self, from: data) else { return }
        botCategoryState = cached
    }

    /// One place that publishes and caches, so the cache can never lag the screen.
    private func applyBotCategories(_ state: BotCategoryState) {
        botCategoryState = state
        if let data = state.encoded() { Self.defaults.set(data, forKey: botCategoriesKey) }
    }

    /// Read the host's groups.
    ///
    /// A failure is logged and leaves the last answer standing: an empty document would read as
    /// "every category was deleted". Called on connect and reconnect (`start()`), on a pull to
    /// refresh, and after every write — that last one is what makes a change made on the phone
    /// appear here without the person going looking for a refresh.
    public func loadBotCategories() async {
        // A read that started before a newer write must not publish over it: two category taps in
        // a row would otherwise land in the order their answers happened to arrive.
        categoryToken += 1
        let token = categoryToken
        do {
            let state = try await client.botCategories()
            guard token == categoryToken else { return }
            applyBotCategories(state)
        } catch {
            ClientLog.note("bots.categories failed: \(error.localizedDescription)",
                           level: .warning, category: "bots")
        }
    }

    /// Every write returns the whole document, so one call redraws the list — no local merge to
    /// get wrong while the other device writes too. The document is then re-read from the host:
    /// the write's answer is what *this* write did, and the re-read is what the two devices agree
    /// on (the host is the only writer, last write wins).
    private func writeBotCategories(_ body: () async throws -> BotCategoryState) async throws {
        let written = try await body()
        categoryToken += 1
        applyBotCategories(written)
        await loadBotCategories()
    }

    public func addBotCategory(name: String) async throws {
        try await writeBotCategories { try await client.createBotCategory(name: name) }
    }

    public func renameBotCategory(id: String, to name: String) async throws {
        try await writeBotCategories { try await client.renameBotCategory(id: id, name: name) }
    }

    public func deleteBotCategory(id: String) async throws {
        try await writeBotCategories { try await client.deleteBotCategory(id: id) }
    }

    /// Move one category up (-1) or down (+1) in the owner's arrangement.
    ///
    /// The arrangement is computed from what is *drawn* — `botGroups` — so "up" means the group
    /// above the one on screen, not the one above it in the file. Pinned and Uncategorized are the
    /// app's own headings and are not part of it, so they are filtered out before moving.
    public func moveBotCategory(id: String, by offset: Int) async throws {
        guard offset != 0 else { return }
        var ids = botGroups
            .filter { !$0.isPinned && !$0.isUncategorized }
            .map(\.id)
        guard let from = ids.firstIndex(of: id) else { return }
        let to = from + offset
        guard ids.indices.contains(to) else { return }
        ids.swapAt(from, to)
        try await writeBotCategories { try await client.reorderBotCategories(ids: ids) }
    }

    /// The login cards waiting for the owner (docs/CREDENTIALS.md). Polled by the Mac's card centre.
    public func credentialCards() async throws -> [CredentialCard] {
        try await client.credentialCards()
    }

    /// Hand the owner's answer to the bridge. What they typed is not kept anywhere on this side.
    public func answerCredentialCard(id: String, values: [String: String]) async throws {
        try await client.answerCredentialCard(id: id, values: values)
    }

    /// Refuse a card. Always obeyed, and nothing is filled.
    public func cancelCredentialCard(id: String) async throws {
        try await client.cancelCredentialCard(id: id)
    }

    /// The Integrations screen's data (docs/INTEGRATIONS.md).
    public func integrations() async throws -> IntegrationsState {
        try await client.integrations()
    }

    /// What a key-based service asks for, as Composio declares it.
    public func integrationKeyFields(slug: String) async throws -> [IntegrationKeyField] {
        try await client.integrationKeyFields(slug: slug)
    }

    /// Hand the owner's key to the host, which passes it to Composio. Nothing comes back but an acknowledgement.
    public func connectIntegrationWithKey(slug: String, values: [String: String]) async throws {
        try await client.connectIntegrationWithKey(slug: slug, values: values)
    }

    /// The hosted Composio page for one service, ready to open in a browser.
    public func connectIntegration(slug: String, alias: String? = nil) async throws -> String {
        try await client.connectIntegration(slug: slug, alias: alias)
    }

    /// Name a connected account: "personal", "work" — what the owner will call it later.
    public func renameIntegration(slug: String, accountID: String, alias: String) async throws {
        try await client.renameIntegration(slug: slug, accountID: accountID, alias: alias)
    }

    public func disconnectIntegration(slug: String, accountID: String? = nil) async throws {
        try await client.disconnectIntegration(slug: slug, accountID: accountID)
    }

    /// Whether a move in `offset` has anywhere to go — what greys out the menu item at the ends.
    public func canMoveBotCategory(id: String, by offset: Int) -> Bool {
        let ids = botGroups.filter { !$0.isPinned && !$0.isUncategorized }.map(\.id)
        guard let from = ids.firstIndex(of: id) else { return false }
        return ids.indices.contains(from + offset)
    }

    /// `nil` puts the bot back in Uncategorized.
    public func setBotCategory(_ botID: String, to categoryID: String?) async throws {
        try await writeBotCategories {
            try await client.setBotCategory(profile: botID, categoryID: categoryID)
        }
    }

    // MARK: Roster configuration

    /// The soul a new bot starts from, and the one Hermes itself would use.
    @Published public private(set) var botDefaults: BotDefaults = .empty
    /// One switch for both panes: a save in flight must not be doubled by a second tap.
    @Published public private(set) var rosterBusy = false

    public func loadBotDefaults() async {
        if let defaults = try? await client.botDefaults() { botDefaults = defaults }
    }

    /// `nil` on success, or the sentence to show. An empty text is the reset, not an error.
    public func saveDefaultSoul(_ text: String) async -> String? {
        rosterBusy = true
        defer { rosterBusy = false }
        do {
            botDefaults = try await client.setDefaultSoul(text)
            return nil
        } catch {
            ClientLog.note("default soul refused: \(error.localizedDescription)",
                           level: .warning, category: "roster")
            return "The host refused the change: \(error.localizedDescription)"
        }
    }

    /// Every bot's config as one document, or nil when the host would not answer.
    public func backupDocument() async -> Data? {
        rosterBusy = true
        defer { rosterBusy = false }
        do { return try await client.exportBackup() }
        catch {
            ClientLog.note("backup failed: \(error.localizedDescription)",
                           level: .warning, category: "roster")
            return nil
        }
    }

    /// The export as a zip: the same document plus each bot's icon.
    public func backupArchive() async -> Data? {
        rosterBusy = true
        defer { rosterBusy = false }
        do { return try await client.exportBackupZip() } catch {
            ClientLog.note("archive failed: \(error.localizedDescription)", level: .warning, category: "roster")
            return nil
        }
    }

    /// The prompt to hand another platform's bot, so its export arrives in a shape this host reads.
    public func importPromptText() async -> String? {
        do { return try await client.importPrompt() } catch {
            ClientLog.note("import prompt failed: \(error.localizedDescription)", level: .warning,
                           category: "roster")
            return nil
        }
    }

    /// What an import would do, without doing it. The owner approves this before anything is written.
    public func previewImport(_ file: Data, mode: BotImportMode) async -> (BackupImportResult?, String?) {
        rosterBusy = true
        defer { rosterBusy = false }
        do { return (try await client.importBackup(file, mode: mode, dryRun: true), nil) } catch {
            return (nil, importFailure(error))
        }
    }

    /// Apply the import, then re-read the roster so the change is visible without a relaunch.
    public func applyImport(_ file: Data, mode: BotImportMode) async -> (BackupImportResult?, String?) {
        rosterBusy = true
        defer { rosterBusy = false }
        do {
            let result = try await client.importBackup(file, mode: mode, dryRun: false)
            await loadBots()
            return (result, nil)
        } catch {
            return (nil, importFailure(error))
        }
    }

    /// The host already refuses a foreign file with a sentence; pass that through rather than a code.
    private func importFailure(_ error: Error) -> String {
        let text = String(describing: error)
        if let range = text.range(of: "detail") {
            return String(text[range.lowerBound...]).prefix(240).description
        }
        return "Import failed: \(error.localizedDescription)"
    }

    /// Rebuild what the document has and this host does not, then re-read the roster so the change is
    /// visible without a relaunch.
    public func restoreBackup(_ document: Data) async -> (BackupRestoreResult?, String?) {
        rosterBusy = true
        do {
            let outcome = try await client.restoreBackup(document)
            rosterBusy = false
            await loadBots()
            await loadBotCategories()
            return (outcome, nil)
        } catch {
            rosterBusy = false
            ClientLog.note("restore refused: \(error.localizedDescription)",
                           level: .warning, category: "roster")
            return (nil, "The host refused the file: \(error.localizedDescription)")
        }
    }

    // MARK: Searching the transcripts

    /// The findings for the query on screen, and the query they belong to.
    @Published public private(set) var searchPage: BotSearchPage = .empty
    @Published public private(set) var searchQuery: String = ""
    @Published public private(set) var searchRunning = false
    /// Which run is current: an answer that arrives after a newer query was typed must not replace
    /// that newer answer.
    private var searchToken = 0

    /// Search every bot's conversation. The caller debounces; this keeps the last answer only.
    public func searchTranscripts(_ query: String) async {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2 else {
            searchToken += 1
            searchQuery = needle
            searchPage = .empty
            searchRunning = false
            return
        }
        searchToken += 1
        let token = searchToken
        searchQuery = needle
        searchRunning = true
        do {
            let page = try await client.searchTranscripts(needle, limit: 50, offset: 0)
            guard token == searchToken else { return }
            searchPage = page
        } catch {
            guard token == searchToken else { return }
            // A failed search is not an empty one: the message says so instead of pretending the
            // host has nothing to say about the phrase.
            ClientLog.note("search failed: \(error.localizedDescription)", level: .warning, category: "search")
            searchPage = .empty
        }
        if token == searchToken { searchRunning = false }
    }

    /// The exchanges between two bots — what the pair modal reads.
    public func transfers(between first: String, and second: String) async -> [BotTransfer] {
        do { return try await client.botTransfers(between: first, and: second, limit: 100) }
        catch {
            ClientLog.note("bot transfers failed: \(error.localizedDescription)",
                           level: .warning, category: "search")
            return []
        }
    }

    /// The list, folded into its headings. Pinned above everything, categories by name,
    /// Uncategorized last.
    public var botGroups: [BotGroup] {
        BotGrouping.groups(bots: orderedBots, state: botCategoryState, pinned: pinnedBots)
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

    /// This bot's routines, read from the host's scheduler rather than from a copy kept here: a
    /// list the app cached could say "every day at 3am" about a job that was paused last Tuesday.
    /// The approval mode in force on every bot profile. A fleet setting, not a per-bot one: the host
    /// stores it in each profile's config, and the bridge keeps the two ends in step.
    public func approvalSettings() async throws -> ApprovalSettings {
        try await client.approvalSettings()
    }

    public func setApprovalMode(_ mode: ApprovalMode) async throws -> ApprovalSettings {
        try await client.setApprovalMode(mode)
    }

    /// A pairing invite this device mints for another one. Single-use and short-lived; the sheet shows
    /// it as a QR and a URL.
    public func makePairingInvite() async throws -> PairingInvite {
        try await client.makePairingInvite()
    }

    /// The bot's effort level and aux/vision model, read from its own config on the host.
    public func modelSettings(for profile: String) async throws -> BotModelSettings {
        try await client.modelSettings(profile)
    }

    /// Change one or both of them. Only the fields given travel, so a save of the effort level cannot
    /// rewrite the vision model beside it.
    @discardableResult
    public func setModelSettings(for profile: String,
                                 effort: String? = nil,
                                 visionProvider: String? = nil,
                                 visionModel: String? = nil) async throws -> BotModelSettings {
        try await client.setModelSettings(profile, effort: effort,
                                          visionProvider: visionProvider, visionModel: visionModel)
    }

    public func routines(for profile: String) async throws -> [BotRoutine] {
        try await client.routines(profile)
    }

    /// Create a routine from the New Routine form. Returns the row the host made, so the list can
    /// show it without a re-read.
    public func createRoutine(_ draft: RoutineDraft, for profile: String) async throws -> BotRoutine {
        try await client.createRoutine(profile, draft: draft)
    }

    /// Pause one routine, or put it back on its schedule.
    public func setRoutinePaused(_ jobID: String, paused: Bool, for profile: String) async throws {
        try await client.setRoutinePaused(profile, jobID: jobID, paused: paused)
    }

    /// What this bot carries into every turn, read fresh: memory is rewritten by the agent whenever
    /// it learns something, so a cached copy would be a copy of what it knew last week.
    public func memory(for profile: String) async throws -> BotMemory {
        try await client.memory(profile)
    }

    /// Where this device's banners go while the app is shut.
    ///
    /// Registering is the whole of the setup: the URL is the Bark app's own push address, and the
    /// host keeps it per device. No Apple account, no key — see the bridge's `push.py` for why.
    public func registerPushRelay(_ url: String) async throws {
        try await client.registerPushRelay(url)
    }

    /// Tell the host which bot this device is reading, so its replies are not announced to it.
    public func reportPresence(bot: String?) async {
        try? await client.reportPresence(bot: bot)
    }

    /// One banner right now, from the Settings screen's own button.
    public func sendTestPush() async throws {
        try await client.sendTestPush()
    }

    /// Hand the host each bot's face, so a banner carries the portrait the roster shows.
    ///
    /// Rendering lives in the UI (`PushIcon`), so the model takes a closure rather than importing a
    /// view layer it must not depend on. Unchanged faces cost one request and no write: the hash is
    /// kept here and the host compares it to what it already has.
    public func syncPushIcons(render: @MainActor (String) -> Data?) async {
        for bot in bots {
            guard let data = render(bot.id) else { continue }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if pushIconDigests[bot.id] == digest { continue }
            do {
                try await client.uploadPushIcon(bot: bot.id, png: data, sha256: digest)
                pushIconDigests[bot.id] = digest
            } catch {
                // A banner with no image is a smaller loss than a banner that is late: try again on
                // the next launch, say nothing.
                continue
            }
        }
    }

    /// What this device last sent, per bot, so an unchanged face is not re-uploaded every launch.
    private var pushIconDigests: [String: String] {
        get { Self.defaults.dictionary(forKey: "hermey.pushIconDigests") as? [String: String] ?? [:] }
        set { Self.defaults.set(newValue, forKey: "hermey.pushIconDigests") }
    }

    /// This bot's own note, read from the host — the same file on every device.
    public func notes(for profile: String) async throws -> BotNotes {
        try await client.notes(profile)
    }

    /// Write the note back. The host holds one file per bot, so this is what the phone and the Mac
    /// both read afterwards: there is no local copy to drift.
    @discardableResult
    public func saveNotes(_ text: String, for profile: String) async throws -> BotNotes {
        try await client.saveNotes(text, for: profile)
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
        do {
            try await client.answer(request.id, with: .object(["choice": .string(choice)]))
            pendingRequests.removeAll { $0.id == request.id }
        } catch {
            lastSendError = "could not send the answer: \(error.localizedDescription)"
        }
    }

    public func answers(_ request: ServerRequest, _ answers: [String: String]) async {
        let value = JSONValue.object(answers.mapValues { JSONValue.string($0) })
        do {
            try await client.answer(request.id, with: .object(["answers": value]))
            pendingRequests.removeAll { $0.id == request.id }
        } catch {
            lastSendError = "could not send the answers: \(error.localizedDescription)"
        }
    }

    /// Refuse a request the client cannot render *at all*.
    ///
    /// This sends JSON-RPC `-32601`, and Hermes deliberately reads that as "no client here can
    /// answer this" — it *withdraws* the queued approval and tells the agent to update the app.
    /// It is NOT a denial: nothing was refused. Use `deny(_:)` when the user pressed Deny.
    public func decline(_ request: ServerRequest) async {
        do {
            try await client.decline(request.id, with: .methodNotFound)
            pendingRequests.removeAll { $0.id == request.id }
        } catch {
            lastSendError = "could not withdraw the request: \(error.localizedDescription)"
        }
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
        do {
            try await client.answer(request.id, with: params)
            pendingRequests.removeAll { $0.id == request.id }
        } catch {
            lastSendError = "could not send the answer: \(error.localizedDescription)"
        }
    }

    /// Allow, in the strongest form the host offered (`once` by default).
    ///
    /// - Parameter remembering: send `always` instead, which the host records in its own allow-list and
    ///   honours in later sessions (`tools/approval.py: is_approved() honours 'always' choices from
    ///   previous sessions`). This is the same `choice` field the CLI's `[a]lways` sends; the gateway
    ///   advertises it in `choices` only when a permanent answer is allowed, which is why the card asks
    ///   the request before offering the button.
    public func approve(_ request: ServerRequest, remembering: Bool = false) async {
        let offered = Self.choices(for: request)
        let wanted = remembering ? "always" : "once"
        // Only a choice the host advertised is sent: inventing `always` for a request that did not offer
        // it would be this client deciding a security question on the host's behalf.
        let choice = offered.contains(wanted)
            ? wanted
            : (offered.first { $0 == "once" } ?? offered.first ?? "once")
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
        noteWireEvent(event)
        // Before any of the branches below: an event for a bot the user is not looking at is still
        // *that bot's* activity, and those branches return early for exactly that reason.
        trackActivity(event)
        // And the same for the transcript it belongs to: the branch will drop the event, so the one
        // fact worth keeping — that session has moved — is recorded here, while it is still in hand.
        if let moving = Self.session(of: event), moving != selectedSessionID {
            noteUnseen(moving)
        }
        // And after every one of them, including the early returns: the model's own run flags are
        // the authority for the open bot, whatever the event said.
        defer { syncActivityWithRunState() }
        switch event {
        case .ready:
            connection = .connected
            // A session that could not be opened while the socket was down has been opened again
            // by the resume on `ready`; the sentence about it is stale the moment the wire is up.
            if lastSendError?.hasPrefix("could not open this session") == true {
                lastSendError = nil
            }
            // The clock has to exist whatever brought the socket up: a VPN flapping or a phone
            // returning from the background also lands here, and neither goes through `start()`.
            startUnreadSweep()
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
                setStreamed("")
                return
            }
            // Its own row, appended *now*: the cards that follow this commentary belong under it,
            // and waiting for `message.complete` would put the line after the answer it preceded.
            // The row that a tool call already sealed is this same commentary; the gate inside keeps
            // it from being written a second time a minute later (which is what was on screen).
            appendAssistantRow(id: "interim-\(key)", text: text, at: Date())
            // When the host says the words already went out as deltas, they are sitting in the
            // live bubble; the row above replaces it, so the bubble must let go of them.
            if alreadyStreamed { setStreamed("") }

        case .messageDelta(let session, let text):
            guard session == selectedSessionID else { return }
            beginLiveTurn()
            isStreaming = true
            runningSessions.insert(session)
            appendStreamed(text)
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
                // Kept for the one case it can still be true in — a bot selected while no window is
                // showing one (`visibleBotID` nil). The guard at the top of this branch means a reply
                // for a *different* bot never reaches here at all; that bot's dot and banner come
                // from the sweep (`noteRemoteActivity`), which is the only reader that sees every
                // bot's newest message. Believing otherwise is what made the cache shortcut in
                // `endlessSession` look safe.
                if visibleBotID != bot { unreadBots.insert(bot) }
            }
            // A completion with no text would otherwise leave a blank bubble beside the streamed
            // one; the deltas already hold the reply.
            let finalText = text.isEmpty ? streamedText : text
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
            setStreamed("")
            isStreaming = false
            reasoningText = ""
            sealedInterimKeys.removeAll()
            sealedCommentary.removeAll()
            runningSessions.remove(session)
            // The reply just rendered *is* the host's newest message for this bot, so the sweep has
            // nothing to reconcile here; and the session is on screen, so it is no longer unseen.
            markTranscriptCurrent()
            unseenSessions.remove(session)
            unseenSessionOrder.removeAll { $0 == session }
            // The turn is now part of what a re-open should show instantly.
            remember(session, entries: transcript, cursor: earlierCursor, total: historyTotal)
            cacheTranscriptSoon(session)
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

    // MARK: Activity

    /// Remember which bot a session belongs to, so an event can be attributed to a face.
    private func noteSessionOwner(_ id: SessionID) {
        guard let bot = selectedBotID else { return }
        sessionBots[id] = bot
    }

    /// Reduce one event into the tracker, for the bot the event's session belongs to.
    ///
    /// A session this launch has never seen has no face to move: attributing it to the open bot
    /// because it happens to be open would light up the wrong row.
    private func trackActivity(_ event: ClientEvent) {
        switch event {
        case .toolStart(let session, _, _, _),
             .toolProgress(let session, _, _),
             .toolComplete(let session, _, _, _, _, _),
             .thinkingDelta(let session, _),
             .messageDelta(let session, _),
             .interimMessage(let session, _, _, _),
             .messageComplete(let session, _):
            guard let bot = sessionBots[session] ?? (session == selectedSessionID ? selectedBotID : nil) else { return }
            botActivityTracker.apply(event, bot: bot)
        case .request(let request):
            // Waiting is a run paused on the user. A request that names no session still blocks the
            // run the app is showing, so it is the open bot's.
            let session = Self.sessionID(of: request)
            guard let bot = session.flatMap({ sessionBots[$0] }) ?? selectedBotID else { return }
            botActivityTracker.apply(event, bot: bot)
        case .ready, .state, .requestCancelled, .contextUsage, .sessionUpdated, .error, .unknown:
            // A transport state is not a bot's state, and `error` is the gateway's error, not a
            // failed run: a run's failure has no event of its own.
            break
        }
    }

    /// Reconcile the open bot's face with the model's own run flags.
    ///
    /// The event stream is not the only authority: `isStreaming` is set by `select`, by a resume and
    /// by `interrupt`, none of which sends a tool event — and a request answered by the user clears
    /// `pendingRequests` without a `request.cancelled`. Both are read here, once, rather than by
    /// each view.
    private func syncActivityWithRunState() {
        guard let bot = selectedBotID else { return }
        if let session = selectedSessionID { sessionBots[session] = bot }
        botActivityTracker.setStreaming(
            isStreaming || isCompressing || runningSessions.contains(selectedSessionID ?? ""),
            for: bot)
        botActivityTracker.setWaitingOnUser(!pendingRequests.isEmpty, for: bot)
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
        let text = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sealedCommentary.append(text)
        appendAssistantRow(id: "commentary-\(UUID().uuidString)", text: text, at: Date())
        setStreamed("")
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
        guard !loadingEarlier, let sid = selectedSessionID, (earlierCursor ?? 0) > 0 else { return }
        loadingEarlier = true
        defer { loadingEarlier = false }
        let fold = transcript.first?.id

        // Two attempts at most: a page that brings nothing new but *does* move the cursor is a
        // cursor that was one page stale (the transcript was replaced under it), and asking again
        // from where the host says to continue is the whole fix. A page that brings nothing new and
        // does not move the cursor means there is nothing older, so the row stops offering it.
        for attempt in 1...2 {
            guard let cursor = earlierCursor, cursor > 0 else { return }
            do {
                let page = try await client.historyPage(sid, profile: selectedBotID,
                                                        cursor: cursor, limit: limit)
                guard selectedSessionID == sid else { return }
                let known = Set(transcript.map(\.id))
                let fresh = page.entries.filter { !known.contains($0.id) }
                ClientLog.note("earlier page: asked at \(cursor), got \(page.entries.count) rows, "
                               + "\(fresh.count) new, cursor now \(page.cursor.map(String.init) ?? "nil")",
                               level: .info, category: "paging")
                earlierCursor = page.cursor
                if page.total > 0 { historyTotal = page.total }
                guard !fresh.isEmpty else {
                    if page.cursor == nil {
                        // Nothing older exists; say so by taking the row away rather than leaving a
                        // button that answers with nothing.
                        earlierCursor = nil
                    } else if attempt == 2 {
                        ClientLog.note("earlier page kept returning rows already on screen",
                                       level: .warning, category: "paging")
                    }
                    continue
                }
                transcript.insert(contentsOf: SentAttachmentVault.decorate(fresh, sessionID: sid),
                                  at: 0)
                turnRowStart += fresh.count
                earlierAnchor = fold
                earlierLoads += 1
                cacheTranscriptSoon(sid)
                return
            } catch {
                guard selectedSessionID == sid else { return }
                lastSendError = "could not load earlier messages: \(error.localizedDescription)"
                ClientLog.note("session.history failed: \(error.localizedDescription)",
                               level: .warning, category: "paging")
                return
            }
        }
    }

    /// The rows the transcript draws. Every other reader (counts, search over history, the last
    /// reply) keeps `transcript`: hiding a card is a display choice, not a loss of history.
    public var visibleTranscript: [TranscriptEntry] {
        if let cached = visibleTranscriptCache,
           cached.showToolCalls == showToolCalls,
           cached.showReasoning == showReasoning {
            return cached.rows
        }
        let rows = TranscriptVisibility.rows(transcript,
                                              showToolCalls: showToolCalls,
                                              showReasoning: showReasoning)
        visibleTranscriptCache = (showToolCalls, showReasoning, rows)
        return rows
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

    /// Preview has no host, so a key-based service cannot ask it what to collect or send anything to it. These
    /// exist to satisfy the protocol rather than to pretend: the preview Integrations screen shows the cards and
    /// nothing behind them.
    public func exportBackupZip() async throws -> Data { Data() }
    public func importPrompt() async throws -> String { throw BotAdminUnavailable() }
    public func importBackup(_ file: Data, mode: BotImportMode, dryRun: Bool) async throws -> BackupImportResult {
        throw BotAdminUnavailable()
    }

    public func integrationKeyFields(slug: String) async throws -> [IntegrationKeyField] { [] }

    public func connectIntegrationWithKey(slug: String, values: [String: String]) async throws {}

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
