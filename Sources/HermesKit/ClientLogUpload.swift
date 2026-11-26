import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Handing the log to the host, so it can be read where the log lives.
///
/// The owner's words: "wouldn't it better if u save the log on server side as well so that i wont have
/// to paste the whole log for u to investigate?" A copy leaves the app in a chat message; this leaves
/// it as a file on the machine the app is paired to, which is where anyone diagnosing it already is.
///
/// **Plain bearer HTTP, not the socket.** The relay is the busiest thing in this program: a large
/// transcript streaming over it must not be able to delay, reorder or drop a log upload, and an upload
/// must not occupy a relay slot while a chat is open. This posts to `POST /v1/client-logs` over
/// `URLSession`, minting its own single-use ticket exactly like `HostUpdateClient` and
/// `AttachmentFileClient`, so a busy socket cannot block it and a failed upload cannot disturb one.
///
/// **Nothing is sent that a copy would not have written.** The payload's `text` is the very string the
/// sheet's Copy action puts on the clipboard (`ClientLog.text(of:header:)`), byte for byte, and the
/// envelope beside it carries only what a reader needs to interpret it: which device, which app build,
/// which OS, when, and which filters were on. There is no field for a credential, and the log itself
/// has never carried card or secret values.
///
/// **One tap, one file.** Nothing here is scheduled, retried, or triggered by an error: the sheet calls
/// `send` when the owner presses the button, and a refusal is shown rather than repeated behind him.
public struct ClientLogUploadPayload: Sendable, Equatable {
    /// This device's own name, as its owner set it — the host puts it in the filename.
    public var device: String
    /// `CFBundleShortVersionString`.
    public var appVersion: String
    /// `CFBundleVersion`.
    public var appBuild: String
    /// e.g. `iOS 18.2`, `macOS 15.1`.
    public var osVersion: String
    /// The copy this file corresponds to, as `ClientLogCopyScope.rawValue`.
    public var scope: String
    /// The active level filter's name (`Errors`, `Warnings`, `Info`), or nil for every level.
    public var level: String?
    /// The active category filter, or nil.
    public var category: String?
    /// The active search phrase, or nil. Whitespace-only is sent as nil: it is not a filter.
    public var search: String?
    /// When the app assembled the file (device clock, sent as epoch seconds).
    public var capturedAt: Date
    /// The log text itself: exactly the bytes a copy writes.
    public var text: String

    public init(device: String,
                appVersion: String,
                appBuild: String,
                osVersion: String,
                scope: ClientLogCopyScope = .all,
                level: String? = nil,
                category: String? = nil,
                search: String? = nil,
                capturedAt: Date = Date(),
                text: String) {
        self.device = device
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.osVersion = osVersion
        self.scope = scope.rawValue
        self.level = level
        self.category = category
        self.search = search
        self.capturedAt = capturedAt
        self.text = text
    }
}

/// `POST /v1/client-logs`'s 201: where the file landed, and how big it is.
public struct ClientLogUploadReceipt: Sendable, Equatable {
    /// The absolute path on the host, e.g. `/var/log/hermey/client-moes-iphone-20261125T2130Z.log`.
    /// This is what the sheet shows, because it is the one thing the owner can act on.
    public let path: String
    /// Bytes written, for a line that can be checked against the file.
    public let bytes: Int

    public init(path: String, bytes: Int) {
        self.path = path
        self.bytes = bytes
    }
}

/// Why an upload did not happen. Each case has a sentence, because the sheet keeps itself open on a
/// failure and has nothing else to say: a bare "failed" is the complaint this whole sheet exists for.
public enum ClientLogUploadError: Error, Equatable, LocalizedError {
    /// No host is paired, or this pairing has no refresh token to mint a ticket from.
    case notConfigured
    /// The log is over the ceiling the host enforces. Refused here first, so the bytes are never sent.
    case tooLarge(bytes: Int, limit: Int)
    case notHTTP
    case rejected(status: Int, detail: String?)
    /// The request never got an answer: off the tailnet, wrong port, host asleep.
    case unreachable(detail: String)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "This device is not paired with a host, so there is nowhere to save the log."
        case let .tooLarge(bytes, limit):
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            let cap = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
            return "This log is \(size), over the \(cap) a host will store. Copy a portion of it instead."
        case .notHTTP:
            return "The host's answer was not HTTP, so nothing was saved."
        case let .unreachable(detail):
            return detail
        case let .rejected(status, detail):
            if let detail, !detail.isEmpty { return detail }
            if status == 403 { return "The host would not take a log from this device (403)." }
            if status == 413 { return "The host refused the log: it is larger than it will store (413)." }
            if status == 409 { return "The host already has a log with that name, and nothing was overwritten." }
            return "The host refused the log (HTTP \(status))."
        case .malformedResponse:
            return "The host took the log but its answer could not be read, so the path is unknown."
        }
    }

    /// Whether the sheet should offer the path at all: only a real receipt has one.
    public var isRefusal: Bool {
        if case .malformedResponse = self { return false }
        return true
    }
}

/// The upload itself. One request, one ticket, one file.
public struct ClientLogUploadClient: Sendable {
    public typealias Endpoint = @Sendable () async throws -> (baseURL: URL, ticket: String)

    /// The host's own ceiling (`MAX_LOG_BYTES` in `hermeyd/src/client_logs.rs`). Both ends apply it:
    /// this one so an oversized log is refused without uploading it, the host's so the ceiling does
    /// not depend on a client behaving.
    public static let maximumBytes = 2 * 1024 * 1024

    private let endpoint: Endpoint
    private let session: URLSession

    public init(endpoint: @escaping Endpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    /// `POST /v1/client-logs`. Answers the path the host wrote, which the sheet shows.
    public func send(_ payload: ClientLogUploadPayload) async throws -> ClientLogUploadReceipt {
        // Refused before a byte goes up: a 2 MiB phone upload over a tailnet is a real wait, and the
        // host would answer 413 anyway.
        let size = payload.text.utf8.count
        guard size <= Self.maximumBytes else {
            throw ClientLogUploadError.tooLarge(bytes: size, limit: Self.maximumBytes)
        }

        let prepared = try await endpoint()
        var request = URLRequest(url: prepared.baseURL.appendingPathComponent("v1/client-logs"))
        request.httpMethod = "POST"
        // Generous compared with the other calls, and still bounded: a log is tens of kilobytes, but
        // the answer is only sent after the host has written and closed the file.
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A bearer, minted for this one request. Not `Authorization` on a socket handshake: the point
        // of this route is that it does not queue behind the relay.
        request.setValue("Bearer \(prepared.ticket)", forHTTPHeaderField: "Authorization")
        request.httpBody = try Self.encodedBody(of: payload)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // No host, no route, no answer: the sheet says so and stays open. Not retried — one tap,
            // one file, and a silent second attempt is exactly the automatic upload this must not be.
            throw ClientLogUploadError.unreachable(detail: Self.reachability(error))
        }
        guard let http = response as? HTTPURLResponse else { throw ClientLogUploadError.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientLogUploadError.rejected(status: http.statusCode,
                                                detail: Self.detail(from: data))
        }
        return try Self.decode(data)
    }

    // MARK: The wire

    /// The shape the host reads (`Upload` in `client_logs.rs`). Kept private so the public payload can
    /// be Swift-named without a key strategy that would rewrite both halves.
    private struct Wire: Encodable {
        let device: String
        let appVersion: String
        let appBuild: String
        let osVersion: String
        let scope: String
        let level: String?
        let category: String?
        let search: String?
        let capturedAt: Double
        let text: String
    }

    /// The bytes this upload puts on the wire. Public because the shape is a contract with
    /// `hermeyd/src/client_logs.rs` and worth pinning in a test that never opens a socket.
    public static func encodedBody(of payload: ClientLogUploadPayload) throws -> Data {
        let wire = Wire(device: payload.device,
                        appVersion: payload.appVersion,
                        appBuild: payload.appBuild,
                        osVersion: payload.osVersion,
                        scope: payload.scope,
                        level: payload.level,
                        category: payload.category,
                        search: payload.search,
                        capturedAt: payload.capturedAt.timeIntervalSince1970,
                        text: payload.text)
        let encoder = JSONEncoder()
        // Sorted keys so the body is the same bytes twice — a log upload is something a person may
        // compare against a copy, and a body that reshuffles makes that harder than it needs to be.
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(wire)
    }

    private static func decode(_ data: Data) throws -> ClientLogUploadReceipt {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = object["path"] as? String, !path.isEmpty else {
            throw ClientLogUploadError.malformedResponse
        }
        return ClientLogUploadReceipt(path: path, bytes: object["bytes"] as? Int ?? 0)
    }

    /// The host's own sentence, when it sent one: a 413 that says "over 2 MiB" is worth more than
    /// "the host refused the log".
    private static func detail(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let detail = object["detail"] as? String { return detail }
        if let error = object["error"] as? [String: Any] {
            return (error["message"] as? String) ?? (error["detail"] as? String)
        }
        return object["message"] as? String
    }

    /// `URLError`'s own words, indented into the sheet's sentence. "unreachable" is the fact the owner
    /// needs: a phone off the tailnet is the common failure, and it is not the host's fault.
    private static func reachability(_ error: Error) -> String {
        let reason = (error as? URLError)?.localizedDescription ?? error.localizedDescription
        return "The host could not be reached, so nothing was saved — \(reason)"
    }
}
