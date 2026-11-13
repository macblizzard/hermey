import Foundation
import HermesAppKit
import HermesKit

/// A frozen host for the macOS UI tests, and the only place one can be built.
///
/// **How it can be reached.** Only by launching the app with *both*
/// `-uiTestFixture` and `-uiTestFixtureToken <the token below>`. There is no default, no
/// environment variable, no `UserDefaults` key and no "am I under XCTest?" sniffing: with the
/// arguments absent `storeForLaunch()` returns the ordinary `WorkspaceStore()` and nothing else
/// in this file runs at all. Typing the flag without the token is inert too, so a stray or
/// half-copied argument cannot put a fake conversation in front of a real user.
///
/// **What it cannot touch.** The fixture branch never constructs the real store:
/// `WorkspaceStore(model:pairing:)` deliberately skips `PairingStore.savedAddress()`, the only
/// keychain read in the app, so the pair record is never read or written. The address it does
/// hold is ticket-only (empty `deviceID`), which is the shape `WorkspaceStore` already refuses
/// to use for bot icons (`loadBotFaces` returns early, `saveBotFace` throws
/// `devicePairingRequired`) — so even the one path that would build a URL has nothing to dial.
/// Every `GatewayClientProtocol` method answers from constants; the ones with a side effect
/// (submit, attach, compress, configure, answer) throw `notConnected` rather than pretending a
/// host agreed.
///
/// **Preferences.** `WorkspaceStore` and `AppModel` read `UserDefaults.standard` directly, so a
/// suite cannot be injected without changing both (and the geometry keys are private to
/// `WorkspaceStore`). Rather than betting on defaults-domain ordering, the fixture reaches the
/// same three facts through the app's public API after `start()`:
/// `setSidebarWidth` (wide list, so the bot block is drawn), `showsContext` (panel shown) and
/// `togglePin` (Assistant first). The only keys it ever names are `hermes.pinnedBots.hermes-fixture` /
/// `hermes.botActivity.hermes-fixture` / `hermes.hiddenBots.hermes-fixture` — `hermes-fixture`
/// is not a host any real pairing can produce (`displayHost` is a DNS label), so the developer's
/// own pins, activity and window geometry are neither read nor overwritten.
enum UITestFixture {

    /// Both are required; either one alone does nothing.
    static let launchArgument = "-uiTestFixture"
    static let tokenArgument = "-uiTestFixtureToken"

    /// The exact token the UI tests pass. A different value is refused, not ignored-and-run.
    static let launchToken = "hermes-mac-uitest-fixture"

    /// The host name every fixture key is namespaced under.
    static let hostName = "hermes-fixture"

    /// The one session the fixture serves, and the one the transcript lives in.
    static let sessionID: SessionID = "fixture-session-1"

    /// The bot that starts pinned.
    static let pinnedBotID = "assistant"

    /// The reply delivered after launch through `AppModel`'s own `.messageComplete` path —
    /// see `deliverLateReply`. It is what makes the unread dot real rather than injected.
    static let lateReply = "Backup verified while you were in the bot list."

    /// Set by `storeForLaunch`; read by `attachFixtureHostIfNeeded`.
    fileprivate(set) static var isActive = false
    fileprivate(set) static var didAttach = false
    fileprivate static var client: FixtureGatewayClient?

    /// `@StateObject`'s autoclosure is not contractually once-only, and a second fixture store
    /// would own a second client — the late reply would go to a wire nothing is listening on.
    /// So the fixture store is built once and handed out again.
    private static var cachedStore: WorkspaceStore?

    // MARK: Launch gate

    /// `true` only when both arguments are present, adjacent, and the token is the expected one.
    static func requestsFixture(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        guard let flag = arguments.firstIndex(of: launchArgument),
              arguments.indices.contains(flag + 1),
              arguments[flag + 1] == tokenArgument,
              let token = arguments.firstIndex(of: tokenArgument),
              arguments.indices.contains(token + 1),
              arguments[token + 1] == launchToken
        else { return false }
        return true
    }

    // MARK: Store

    /// The workspace this launch should use: the frozen one when both launch arguments are
    /// present, the ordinary one otherwise.
    ///
    /// `hostName` is passed through so `AppModel`'s per-host keys
    /// (`pinnedBots.<host>`, `botActivity.<host>`) point at the fixture namespace.
    @MainActor
    static func storeForLaunch(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> WorkspaceStore {
        guard requestsFixture(arguments) else { return WorkspaceStore() }
        if let cached = cachedStore { return cached }

        FixtureDefaults.reset(hostName: hostName)
        let client = FixtureGatewayClient()
        self.client = client
        isActive = true
        let store = WorkspaceStore(model: AppModel(client: client, hostName: hostName),
                                   pairing: PairingAddress(baseURL: "wss://hermes-fixture.invalid",
                                                           deviceID: "",
                                                           token: "fixture-only"))
        cachedStore = store
        return store
    }
}

// MARK: - Attach

@MainActor
extension WorkspaceStore {
    /// Connect the fixture host, arrange the workspace, then deliver the one live event.
    ///
    /// `attachPreviewHost()` is the app's existing preview path: `model.start()` over an offline
    /// client plus "open the first session". Idempotent here because the window may re-run
    /// `.task` when it comes back.
    func attachFixtureHostIfNeeded() async {
        guard UITestFixture.isActive, !UITestFixture.didAttach else { return }
        UITestFixture.didAttach = true

        await attachPreviewHost()

        // After `start()`, through the same setters the UI uses — so this is the app's own
        // state, not a mock of it. Nothing here writes a preference: `setSidebarWidth` and
        // `showsContext` only persist from `endSidebarDrag` / `toggleContextPanel`.
        setSidebarWidth(280)
        // The context panel defaults to visible; setting the published property directly avoids
        // `toggleContextPanel`, which would write `hermes.workspace.showsContext` to the user's
        // real preferences from a test launch.
        showsContextPanel = true
        if !model.isPinned(botID: UITestFixture.pinnedBotID) {
            model.togglePin(botID: UITestFixture.pinnedBotID)
        }

        UITestFixture.deliverLateReply(on: model)
    }
}

extension UITestFixture {
    /// A reply that lands while the bot list is showing.
    ///
    /// This is the only way an unread dot can exist: `AppModel` inserts one in
    /// `.messageComplete` exactly when `visibleBotID != selectedBotID`. So the fixture does what
    /// the app does when the user is looking at the list — `setVisibleBot(nil)`, public API, on
    /// the main actor — and then yields the event through the same stream a live client uses.
    /// Nothing inside `AppModel` is poked from outside.
    @MainActor
    fileprivate static func deliverLateReply(on model: AppModel) {
        guard let client = UITestFixture.client else { return }
        Task { @MainActor in
            // A beat, so the pane's `.onAppear` has already claimed the bot as visible.
            try? await Task.sleep(nanoseconds: 600_000_000)
            model.setVisibleBot(nil)
            client.emit(.messageComplete(session: sessionID, text: lateReply))
        }
    }
}

// MARK: - Isolated defaults

/// The fixture's own corner of the app's defaults, and the only defaults this file touches.
///
/// Every key here is suffixed with the fixture host name. `reset()` exists so a second launch on
/// the same machine starts from the same state: a pin left behind by an earlier run would make
/// `togglePin` unpin instead of pin, and the sidebar assertion would fail for the wrong reason.
enum FixtureDefaults {

    /// Every key is suffixed with the fixture host name. Nothing outside `hermes-fixture` is
    /// named, so a real host's pins, activity and hidden list are untouched.
    static func keys(hostName: String) -> [String] {
        [
            "hermes.pinnedBots.\(hostName)",     // AppModel.pinnedBotsKey
            "hermes.botActivity.\(hostName)",    // AppModel.botActivityKey
            "hermes.hiddenBots.\(hostName)",     // AppModel.hiddenKey
        ]
    }

    static func reset(hostName: String, defaults: UserDefaults = .standard) {
        for key in keys(hostName: hostName) { defaults.removeObject(forKey: key) }
    }
}

// MARK: - Content

/// Everything the fixture host says, in one place, frozen.
///
/// The transcript exercises the three renderings the conversation pane exists for: a markdown
/// **table**, a fenced **code block**, and a **long paragraph** — plus a tool row, so the card
/// path is on screen too. The prose is fixed so a search count is a fact, not a race.
enum FixtureContent {

    /// Fixed, not `Date()`: a relative timestamp would make two runs differ. Ordering in the
    /// sidebar is pinned-first, then the host's own order — no activity is seeded, because the
    /// pin is the affordance under test.
    static let bots: [Bot] = [
        Bot(id: "assistant", displayName: "Assistant", description: "Runs the workshop"),
        Bot(id: "ops", displayName: "Ops", description: "Reads the archives"),
        Bot(id: "charlie", displayName: "Scribe", description: "Keeps the minutes"),
    ]

    static let sessions: [SessionSummary] = [
        SessionSummary(id: UITestFixture.sessionID,
                       title: "Vault backup + docs audit",
                       updatedAt: Date(timeIntervalSince1970: 1_767_225_600),
                       preview: "1,204 files copied · 3 docs changed"),
    ]

    static let longParagraph = """
    I take the first snapshot before touching anything else, because a cold vault is 1.2 GB and every later pass is a delta against it — paying that cost once keeps the rest of the run cheap. The copy finished with 1,204 files in the backup and no errors. The diff is deliberately scoped to docs, the one tree I wrote into, so a changed attachment or note cannot hide behind an unchanged file count. Nothing was deleted from either side; the source tree was only read. If the numbers below disagree with what you expect, the place to look first is the attachments folder, which is unchanged on purpose and therefore proves the filter worked.
    """

    /// Ids are stable strings so a test can speak about a row without depending on order.
    static let transcript: [TranscriptEntry] = [
        TranscriptEntry(id: "fixture-row-1", role: .user,
                        text: "Audit the vault backup and tell me which files changed."),
        TranscriptEntry(id: "fixture-row-2", role: .assistant, text: """
        # Vault backup audit

        \(longParagraph)

        | Folder | Files | Delta |
        | --- | --- | --- |
        | vault/notes | 812 | +12 |
        | vault/attachments | 331 | 0 |
        | docs/ | 61 | -3 |

        ```sh
        rsync -a --delete ~/vault/ ~/backup/vault/
        diff -rq ~/vault/docs ~/backup/vault/docs
        ```

        The only tree I wrote into is docs, and the three changed files are listed above.
        """),
        TranscriptEntry(id: "fixture-row-3", role: .tool,
                        text: "bash · rsync -a --delete ~/vault/ ~/backup/vault/ · 0.8s · exit 0",
                        tool: TranscriptEntry.ToolDetail(
                            name: "bash",
                            context: "rsync -a --delete ~/vault/ ~/backup/vault/",
                            args: "{\"command\": \"rsync -a --delete ~/vault/ ~/backup/vault/\"}",
                            content: "sent 1,204 files · 1.2G · exit 0")),
        TranscriptEntry(id: "fixture-row-4", role: .assistant,
                        text: "Diff is scoped to docs: three files changed, none removed."),
    ]
}

// MARK: - Client

/// The offline wire. Every answer is a constant; the calls that would change a host throw, so a
/// screen that thinks it talked to something is a test failure rather than a fiction.
final class FixtureGatewayClient: GatewayClientProtocol, @unchecked Sendable {

    var state: TransportState { get async { .open } }

    let events: AsyncStream<ClientEvent>
    private let continuation: AsyncStream<ClientEvent>.Continuation

    init() {
        var captured: AsyncStream<ClientEvent>.Continuation!
        events = AsyncStream { captured = $0 }
        continuation = captured
    }

    /// Push one event onto the same stream `AppModel.observeEvents` consumes from a live client.
    func emit(_ event: ClientEvent) {
        continuation.yield(event)
    }

    // MARK: Connection

    func connect() async throws {
        continuation.yield(.ready(replayEpoch: nil))
    }

    func disconnect() async {}
    func ping() async throws {}

    // MARK: Bots and sessions

    func listBots() async throws -> [Bot] { FixtureContent.bots }

    func listSessions(limit: Int) async throws -> [SessionSummary] { FixtureContent.sessions }

    func listSessions(limit: Int, profile: String?, includeHidden: Bool) async throws -> [SessionSummary] {
        // Only the pinned bot has rows: a row leaking between bots would otherwise look
        // plausible on screen, which is exactly what a fixture must not do.
        guard profile == nil || profile == UITestFixture.pinnedBotID else { return [] }
        return FixtureContent.sessions
    }

    func resumeSession(_ id: SessionID) async throws -> SessionResume { resume(id) }

    func resumeSession(_ id: SessionID, profile: String?) async throws -> SessionResume { resume(id) }

    private func resume(_ id: SessionID) -> SessionResume {
        SessionResume(id: id,
                      entries: id == UITestFixture.sessionID ? FixtureContent.transcript : [],
                      inflight: nil,
                      openRequests: [])
    }

    func createSession(model: String?, provider: String?) async throws -> SessionID { "fixture-new-session" }

    func createSession(model: String?, provider: String?, profile: String?) async throws -> SessionID {
        "fixture-new-session"
    }

    func history(_ id: SessionID, limit: Int) async throws -> [TranscriptEntry] {
        id == UITestFixture.sessionID ? FixtureContent.transcript : []
    }

    // MARK: Turns — refuse, never pretend

    func submit(session: SessionID, text: String) async throws -> TurnDelivery { throw GatewayError.notConnected }
    func steer(session: SessionID, text: String) async throws { throw GatewayError.notConnected }
    func interrupt(session: SessionID) async throws { throw GatewayError.notConnected }
    func rewind(session: SessionID, toRowID: Int64, then text: String) async throws {
        throw GatewayError.notConnected
    }

    // MARK: Discovery

    private static let currentModel = ModelOption(id: "deepseek-v4.1-flash",
                                                  provider: "opencode-go",
                                                  label: "deepseek-v4.1-flash")

    func modelOptions() async throws -> [ModelOption] { [Self.currentModel] }

    func modelCatalog() async throws -> ModelCatalog {
        ModelCatalog(current: Self.currentModel, options: [Self.currentModel])
    }

    func modelCatalog(profile: String?) async throws -> ModelCatalog {
        ModelCatalog(current: Self.currentModel, options: [Self.currentModel])
    }

    func configureModel(profile: String, model: String, provider: String, confirm: Bool) async throws -> ProfileModelChange {
        throw GatewayError.notConnected
    }

    func configureDescription(profile: String, description: String) async throws {
        throw GatewayError.notConnected
    }

    // MARK: Effects

    func attach(session: SessionID, name: String, data: Data, isImage: Bool) async throws -> AttachmentReceipt {
        throw GatewayError.notConnected
    }

    func compress(session: SessionID) async throws { throw GatewayError.notConnected }

    func answer(_ request: ServerRequestID, with result: JSONValue) async throws {
        throw GatewayError.notConnected
    }

    func decline(_ request: ServerRequestID, with error: RPCError) async throws {
        throw GatewayError.notConnected
    }
}
