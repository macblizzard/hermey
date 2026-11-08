import Foundation
import HermesKit

/// The client an unpaired app runs on.
///
/// Launch must not dial out, but the shell still needs an `AppModel`: every pane renders
/// from one, and a `nil` model would mean a second code path for "no host". So the
/// unpaired app holds a client whose every verb fails with one honest sentence. Nothing is
/// invented: `connect()` throws, so `AppModel.connection` stays `.idle` until the user
/// pairs a host on purpose.
final class UnpairedGatewayClient: GatewayClientProtocol, @unchecked Sendable {

    enum Reason: LocalizedError {
        case noHost

        var errorDescription: String? {
            switch self {
            case .noHost:
                return "No host is paired yet — pair one to connect."
            }
        }
    }

    /// Never yields and never finishes; `connect()` fails before anyone iterates it.
    let events: AsyncStream<ClientEvent> = AsyncStream<ClientEvent> { _ in }

    var state: TransportState { get async { .idle } }

    func connect() async throws { throw Reason.noHost }
    func disconnect() async {}

    /// No host, so there is no profile directory to list. Throwing leaves `bots` empty,
    /// which is what the unpaired rail shows ("No host paired") — it never dials out.
    func listBots() async throws -> [Bot] { throw Reason.noHost }

    func ping() async throws { throw Reason.noHost }
    func listSessions(limit: Int) async throws -> [SessionSummary] { throw Reason.noHost }
    func listSessions(limit: Int, profile: String?, includeHidden: Bool) async throws -> [SessionSummary] {
        throw Reason.noHost
    }
    func resumeSession(_ id: SessionID) async throws -> SessionResume { throw Reason.noHost }
    func createSession(model: String?, provider: String?) async throws -> SessionID { throw Reason.noHost }
    func history(_ id: SessionID, limit: Int) async throws -> [TranscriptEntry] { throw Reason.noHost }

    func submit(session: SessionID, text: String) async throws -> TurnDelivery { throw Reason.noHost }
    func steer(session: SessionID, text: String) async throws { throw Reason.noHost }
    func interrupt(session: SessionID) async throws { throw Reason.noHost }
    func rewind(session: SessionID, toRowID: Int64, then text: String) async throws { throw Reason.noHost }

    func modelOptions() async throws -> [ModelOption] { throw Reason.noHost }
    func answer(_ request: ServerRequestID, with result: JSONValue) async throws { throw Reason.noHost }
    func decline(_ request: ServerRequestID, with error: RPCError) async throws { throw Reason.noHost }
}
