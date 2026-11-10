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

    // MARK: Sessions

    func ping() async throws {}
    func listSessions(limit: Int) async throws -> [SessionSummary] { [summary] }
    func listSessions(limit: Int, profile: String?, includeHidden: Bool) async throws -> [SessionSummary] { [summary] }

    private var summary: SessionSummary {
        SessionSummary(id: session, title: "test thread")
    }

    func resumeSession(_ id: SessionID) async throws -> SessionResume {
        resumed.append(id)
        if let resumeError { throw resumeError }
        return resume()
    }

    func resumeSession(_ id: SessionID, profile: String?) async throws -> SessionResume {
        resumed.append(id)
        if let resumeError { throw resumeError }
        return resume()
    }

    /// The paging state a resume reports: nil `earlierCursor` means "this is the whole transcript".
    var earlierCursor: Int?
    var historyTotal = 0
    private func resume() -> SessionResume {
        SessionResume(id: session, entries: entries, inflight: nil, openRequests: [],
                      earlierCursor: earlierCursor, historyTotal: historyTotal)
    }

    func createSession(model: String?, provider: String?) async throws -> SessionID { session }
    func createSession(model: String?, provider: String?, profile: String?) async throws -> SessionID { session }

    func createSession(model: String?, provider: String?, profile: String?,
                       idempotencyKey: String?) async throws -> SessionID {
        createKeys.append(idempotencyKey)
        return session
    }
    func history(_ id: SessionID, limit: Int) async throws -> [TranscriptEntry] { entries }

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

    func sharedSessionID(forBot profile: String) async throws -> SessionID? {
        if let hostPointerError { throw hostPointerError }
        return hostPointer
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

    // MARK: Discovery

    func modelOptions() async throws -> [ModelOption] { [] }
    func modelCatalog() async throws -> ModelCatalog { ModelCatalog(current: nil, options: []) }

    // MARK: Compaction and requests

    func compress(session: SessionID) async throws {}
    func answer(_ request: ServerRequestID, with result: JSONValue) async throws {}
    func decline(_ request: ServerRequestID, with error: RPCError) async throws {}
}
#endif
