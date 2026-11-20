#if canImport(Combine)
import Foundation
import HermesKit

/// A gateway that answers from a script instead of a socket, so `AppModel`'s state machine can be
/// driven event by event.
///
/// Only the calls the tests use return anything meaningful; the rest throw `GatewayError.notConnected`
/// on purpose — an unexpected call is a bug in the test, not something to paper over with `nil`.
final class ScriptedHost: GatewayClientProtocol, @unchecked Sendable {

    let session: SessionID
    /// The transcript a resume answers with. Tests rewrite it to model what the host persisted.
    var entries: [TranscriptEntry]
    /// Rows per profile, for the tests that need two bots to answer with two different transcripts.
    /// Empty by default: every existing fixture has one transcript for every profile.
    var entriesByProfile: [String: [TranscriptEntry]] = [:]
    private(set) var submitted: [String] = []

    private let continuation: AsyncStream<ClientEvent>.Continuation
    private let scriptedEvents: AsyncStream<ClientEvent>
    // Lifecycle regressions use the real client's subscription implementation while retaining
    // this host's deterministic session/catalogue responses. Existing fixtures remain unchanged.
    private let eventClient: GatewayClientProtocol?
    var events: AsyncStream<ClientEvent> { eventClient?.events ?? scriptedEvents }

    init(session: SessionID, entries: [TranscriptEntry] = [],
         eventClient: GatewayClientProtocol? = nil) {
        self.session = session
        self.entries = entries
        self.eventClient = eventClient
        var captured: AsyncStream<ClientEvent>.Continuation!
        scriptedEvents = AsyncStream { captured = $0 }
        continuation = captured
    }

    var state: TransportState { get async { .open } }

    /// Push one wire event into the model.
    func emit(_ event: ClientEvent) { continuation.yield(event) }

    // MARK: Handshake

    func connect() async throws { try await eventClient?.connect() }
    func disconnect() async { await eventClient?.disconnect() }

    // MARK: Bots

    var bots: [Bot] = [Bot(id: "assistant")]
    /// Every `configureDescription` call, so a test can prove what crossed the client boundary.
    private(set) var descriptions: [(String, String)] = []

    func listBots() async throws -> [Bot] { bots }
    func configureDescription(profile: String, description: String) async throws {
        descriptions.append((profile, description))
    }

    // MARK: Previews

    /// What the bridge's `POST /v1/bots/previews` answers. A test that wants a reply to arrive
    /// on a bot nobody is looking at rewrites this and calls `loadBotPreviews()`.
    var previewFeed = BotPreviewFeed()

    func botPreviews() async throws -> [String: BotConversationPreview] { previewFeed.previews }

    func botPreviews(since marks: [String: Double]) async throws -> BotPreviewFeed { previewFeed }

    // MARK: Sessions

    func ping() async throws {}
    func listSessions(limit: Int) async throws -> [SessionSummary] { [summary] }
    /// What the profile-scoped listing answers. Defaults to the one scripted session; a test that needs
    /// "this bot already has conversations" sets it.
    var profileSessions: [SessionSummary]?

    func listSessions(limit: Int, profile: String?, includeHidden: Bool) async throws -> [SessionSummary] {
        profileSessions ?? [summary]
    }

    private var summary: SessionSummary {
        SessionSummary(id: session, title: "test thread")
    }

    /// How long a resume takes. Zero for every existing test; a test that needs to look at the
    /// screen *while* the host is still thinking sets it.
    var resumeDelay: Duration?
    /// The same, per bot: a slow answer for the bot the user leaves, a fast one for the bot they
    /// move to, which is the ordering that made a late resume land in the wrong window.
    var resumeDelayByProfile: [String: Duration] = [:]

    /// Ids this host has forgotten, while it still knows the others. `resumeError` fails every resume;
    /// this fails only the ids named, which is what a stale pointer actually looks like.
    var staleIDs: Set<SessionID> = []

    func resumeSession(_ id: SessionID) async throws -> SessionResume {
        resumed.append(id)
        if let resumeDelay { try? await Task.sleep(for: resumeDelay) }
        if let resumeError { throw resumeError }
        if staleIDs.contains(id) { throw GatewayError.rpc(RPCError(code: 4007, message: "session not found")) }
        return resume()
    }

    /// Two bots can be two sessions, for the tests that need an event aimed at the one nobody is
    /// looking at. Empty by default: every existing fixture has one session for every profile.
    var sessionByProfile: [String: SessionID] = [:]

    func resumeSession(_ id: SessionID, profile: String?) async throws -> SessionResume {
        resumed.append(id)
        // Whichever delay applies, per bot first: a test that scripts a slow answer for one bot and
        // a fast one for another is scripting the order the two answers arrive in.
        if let delay = profile.flatMap({ resumeDelayByProfile[$0] }) ?? resumeDelay {
            try? await Task.sleep(for: delay)
        }
        if let resumeError { throw resumeError }
        if staleIDs.contains(id) { throw GatewayError.rpc(RPCError(code: 4007, message: "session not found")) }
        return resume(sessionByProfile[profile ?? ""] ?? session, profile: profile)
    }

    /// The paging state a resume reports: nil `earlierCursor` means "this is the whole transcript".
    var earlierCursor: Int?
    var historyTotal = 0
    private func resume(_ id: SessionID? = nil, profile: String? = nil) -> SessionResume {
        // Per bot when the test scripted one, the single fixture otherwise.
        let rows = profile.flatMap { entriesByProfile[$0] } ?? entries
        return SessionResume(id: id ?? session, entries: rows, inflight: nil, openRequests: [],
                             earlierCursor: earlierCursor, historyTotal: historyTotal)
    }

    /// Every `session.create` this host was asked for, so a test can prove no blank conversation was
    /// minted behind the person's back.
    private(set) var createdSessions: [String?] = []

    func createSession(model: String?, provider: String?) async throws -> SessionID {
        createdSessions.append(nil)
        return session
    }

    func createSession(model: String?, provider: String?, profile: String?) async throws -> SessionID {
        createdSessions.append(profile)
        return session
    }

    func createSession(model: String?, provider: String?, profile: String?,
                       idempotencyKey: String?) async throws -> SessionID {
        createKeys.append(idempotencyKey)
        return session
    }
    /// How many times a page was read, so a test can prove a sweep skipped a bot.
    private(set) var historyReads = 0

    func history(_ id: SessionID, limit: Int) async throws -> [TranscriptEntry] {
        historyReads += 1
        return entries
    }

    // MARK: Older transcript pages

    /// Pages keyed by the cursor the model sent. A missing key answers `HistoryPage.none`, which is
    /// what "the host thinks this was the whole conversation" looks like.
    var pages: [Int: HistoryPage] = [:]
    /// Every page request that crossed the client boundary, in order.
    private(set) var pageRequests: [(cursor: Int, limit: Int)] = []

    func historyPage(_ id: SessionID, profile: String?, cursor: Int,
                     limit: Int) async throws -> HistoryPage {
        pageRequests.append((cursor, limit))
        return pages[cursor] ?? .none
    }

    // MARK: Shared conversation pointer

    /// What the bridge answers for `sharedSessionID(forBot:)`. `nil` is "the bridge has no pointer
    /// for this bot"; `hostPointerError` models a bridge that cannot be asked at all.
    var hostPointer: String?
    var hostPointerError: Error?
    var publishError: Error?
    /// Thrown by every resume, to model a host that forgot the session (4001/4007).
    var resumeError: Error?
    /// Every publish that crossed the client boundary, in order — `nil` id means "clear it".
    private(set) var published: [(id: SessionID?, profile: String)] = []
    /// Every id this host was asked to resume, so a test can prove *which* stored id opened.
    private(set) var resumed: [SessionID] = []
    /// Every idempotency key a create carried, in order.
    private(set) var createKeys: [String?] = []

    // MARK: The host's canonical Bot Chat

    /// What the host answers for `canonicalBotChat(forProfile:)`.
    ///
    /// `.absent` by default, because that is what a bot created before Bot Mode exists looks like:
    /// the host answered and named no canonical chat, which licenses this app to adopt or mint one.
    /// `canonicalChatError` models a host that cannot be asked at all.
    var canonicalChat: CanonicalBotChat.HostState = .absent
    var canonicalChatError: Error?
    /// Every `titleSession` that crossed the boundary, so a test can prove what was named what.
    private(set) var titled: [(id: SessionID, title: String)] = []
    var titleError: Error?
    /// Every `session.archive`, so a reset can be proved to retire rather than orphan.
    private(set) var archived: [SessionID] = []
    var archiveError: Error?

    func canonicalBotChat(forProfile profile: String) async throws -> CanonicalBotChat.HostState {
        if let canonicalChatError { throw canonicalChatError }
        return canonicalChat
    }

    func titleSession(_ session: SessionID, title: String, profile: String?) async throws {
        if let titleError { throw titleError }
        titled.append((session, title))
    }

    func archiveSession(_ session: SessionID, profile: String?) async throws {
        if let archiveError { throw archiveError }
        archived.append(session)
    }

    /// Every canonical create, so a test can tell "minted the canonical chat" from "minted a plain
    /// conversation".
    private(set) var canonicalCreates = 0

    func createCanonicalSession(profile: String, idempotencyKey: String?) async throws -> SessionID {
        canonicalCreates += 1
        createKeys.append(idempotencyKey)
        return session
    }

    /// A pointer per bot, for the same reason as `sessionByProfile`: two bots, two conversations.
    var hostPointerByProfile: [String: SessionID] = [:]

    func sharedSessionID(forBot profile: String) async throws -> SessionID? {
        if let hostPointerError { throw hostPointerError }
        return hostPointerByProfile[profile] ?? hostPointer
    }

    func publishSharedSessionID(_ id: SessionID?, forBot profile: String) async throws {
        if let publishError { throw publishError }
        published.append((id, profile))
    }

    // MARK: Turns

    func submit(session: SessionID, text: String) async throws -> TurnDelivery {
        submitted.append(text)
        return .streaming
    }
    func steer(session: SessionID, text: String) async throws {}
    func interrupt(session: SessionID) async throws {}
    func rewind(session: SessionID, toRowID: Int64, then text: String) async throws {}

    // MARK: Rooms

    /// The room list this host answers with, and each room's log after the highest `seq` asked for.
    var roomList: [RoomSummary] = []
    var roomLogs: [String: [RoomMessage]] = [:]

    func rooms() async throws -> [RoomSummary] { roomList }

    func roomPage(_ roomID: String, since: Int?) async throws -> RoomPage {
        let all = roomLogs[roomID] ?? []
        let floor = since ?? 0
        return RoomPage(messages: all.filter { $0.seq > floor },
                        latestSeq: all.map(\.seq).max() ?? 0)
    }

    // MARK: Categories

    /// The host's category document, exactly as the bridge would hold it: groups plus assignments.
    /// A test rewrites it to model what the *other* device did while this one was open.
    var categoryState = BotCategoryState.empty
    /// Every read that reached the host, so a test can prove a connect (or a write) refreshed.
    private(set) var categoryReads = 0
    /// Every write that reached the host, in order: `create:Work`, `assign:cody:work`.
    private(set) var categoryWrites: [String] = []
    /// Set to make every category call fail, the way a host that is not there does.
    var categoryError: Error?
    /// How long a read takes before its answer arrives. The document is captured first, so a slow
    /// read answers with what the host held when it was asked — which is what a late answer is.
    var categoryReadDelay: Duration?

    func botCategories() async throws -> BotCategoryState {
        if let categoryError { throw categoryError }
        categoryReads += 1
        let answer = categoryState
        if let categoryReadDelay { try? await Task.sleep(for: categoryReadDelay) }
        return answer
    }

    func createBotCategory(name: String) async throws -> BotCategoryState {
        if let categoryError { throw categoryError }
        categoryWrites.append("create:\(name)")
        let category = BotCategory(id: "cat-\(categoryState.categories.count + 1)", name: name)
        categoryState = BotCategoryState(categories: categoryState.categories + [category],
                                         assignments: categoryState.assignments)
        return categoryState
    }

    func renameBotCategory(id: String, name: String) async throws -> BotCategoryState {
        if let categoryError { throw categoryError }
        categoryWrites.append("rename:\(id):\(name)")
        categoryState = BotCategoryState(
            categories: categoryState.categories.map { $0.id == id ? BotCategory(id: id, name: name) : $0 },
            assignments: categoryState.assignments)
        return categoryState
    }

    func deleteBotCategory(id: String) async throws -> BotCategoryState {
        if let categoryError { throw categoryError }
        categoryWrites.append("delete:\(id)")
        categoryState = BotCategoryState(
            categories: categoryState.categories.filter { $0.id != id },
            assignments: categoryState.assignments.filter { $0.value != id })
        return categoryState
    }

    func reorderBotCategories(ids: [String]) async throws -> BotCategoryState {
        if let categoryError { throw categoryError }
        categoryWrites.append("order:" + ids.joined(separator: ","))
        // The host answers with the document already arranged, the way the bridge does.
        let byID = Dictionary(uniqueKeysWithValues: categoryState.categories.map { ($0.id, $0) })
        categoryState = BotCategoryState(
            categories: ids.compactMap { byID[$0] },
            assignments: categoryState.assignments,
            order: ids)
        return categoryState
    }

    func setBotCategory(profile: String, categoryID: String?) async throws -> BotCategoryState {
        if let categoryError { throw categoryError }
        categoryWrites.append("assign:\(profile):\(categoryID ?? "-")")
        var assignments = categoryState.assignments
        assignments[profile] = categoryID
        categoryState = BotCategoryState(categories: categoryState.categories,
                                         assignments: assignments)
        return categoryState
    }

    // MARK: Discovery

    func modelOptions() async throws -> [ModelOption] { [] }
    func modelCatalog() async throws -> ModelCatalog { ModelCatalog(current: nil, options: []) }

    // MARK: Compaction and requests

    /// What the host answers a compaction with. `nil` means "it worked"; the case that matters is a
    /// transport failure thrown a heartbeat after the request, which is what a backgrounded phone
    /// does to a compaction that is still running on the host.
    var compressError: Error?
    /// How long a compaction takes before it answers. A real one is 74–163 s on this host.
    var compressDelay: Duration?
    var compressCalls = 0

    func compress(session: SessionID) async throws {
        compressCalls += 1
        if let compressDelay { try? await Task.sleep(for: compressDelay) }
        if let compressError { throw compressError }
    }
    func answer(_ request: ServerRequestID, with result: JSONValue) async throws {}
    func decline(_ request: ServerRequestID, with error: RPCError) async throws {}
}
#endif
