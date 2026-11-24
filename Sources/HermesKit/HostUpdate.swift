import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The host's own next version: what `GET /v1/update` says, and the press that installs it.
///
/// This is deliberately *not* the app's updater. Sparkle replaces the .app bundle; this replaces
/// `/opt/hermey/bin/hermeyd` on the machine the app is paired to — a different program, a different
/// release series (`hermeyd-v*`) and a different failure mode (a host that does not come back).
/// Both apps read it, so one contract is written here and drawn twice.
///
/// The host answers in snake_case with a nullable `latest`: `null` means the release feed could not
/// be read, which is **unknown**, never "you are up to date". A row is only ever drawn from a real
/// answer, which is why nothing in this file invents a version.
public struct HostUpdateStatus: Equatable, Sendable {
    /// The version this host is running now.
    public let current: String
    /// The newest published version, or nil when the host could not ask.
    public let latest: String?
    public let available: Bool
    /// The release page, for the quiet "What's new" link.
    public let notesURL: URL?
    /// When the host last asked the feed (the host's clock, not this device's).
    public let checkedAt: Date?
    /// False when the host will not update itself: self-update off, no build for its platform, or
    /// a binary it cannot write. The row is not drawn at all in that case.
    public let canSelfUpdate: Bool
    /// `linux-x86_64` and friends — what the host would download.
    public let arch: String
    /// Why `latest` is nil, in the host's own words.
    public let error: String?
    /// The stage of a press that is running right now: `downloading`, `verifying`, `installing`.
    public let progress: String?
    /// What the last install did — the record the rollback is read from.
    public let lastUpdate: HostUpdateRecord?

    public init(current: String,
                latest: String? = nil,
                available: Bool = false,
                notesURL: URL? = nil,
                checkedAt: Date? = nil,
                canSelfUpdate: Bool = false,
                arch: String = "",
                error: String? = nil,
                progress: String? = nil,
                lastUpdate: HostUpdateRecord? = nil) {
        self.current = current
        self.latest = latest
        self.available = available
        self.notesURL = notesURL
        self.checkedAt = checkedAt
        self.canSelfUpdate = canSelfUpdate
        self.arch = arch
        self.error = error
        self.progress = progress
        self.lastUpdate = lastUpdate
    }
}

/// `update-state.json` as the host reports it: which build was installed over which, and where that
/// left the service. `state` is `pending`, `healthy` or `rolled-back`.
public struct HostUpdateRecord: Equatable, Sendable {
    public let target: String
    public let previous: String
    public let state: String
    public let attempts: Int
    public let startedAt: Date?

    public init(target: String, previous: String, state: String, attempts: Int, startedAt: Date?) {
        self.target = target
        self.previous = previous
        self.state = state
        self.attempts = attempts
        self.startedAt = startedAt
    }

    /// The previous build is back. The one terminal outcome the apps draw as neither success nor
    /// failure.
    public var isRolledBack: Bool { state == "rolled-back" }
    /// The install is still on trial: the host has not yet served its minute.
    public var isPending: Bool { state == "pending" }
}

/// `POST /v1/update`'s 202.
public struct HostUpdateAck: Equatable, Sendable {
    public let target: String
    public let state: String
}

public enum HostUpdateError: Error, Equatable, LocalizedError {
    case notHTTP
    case malformedResponse
    case rejected(status: Int, detail: String?)
    case noHost

    public var errorDescription: String? {
        switch self {
        case .notHTTP:
            return "the host did not answer over HTTP"
        case .malformedResponse:
            return "the host's answer was not readable"
        case .rejected(let status, let detail):
            if let detail, !detail.isEmpty { return detail }
            if status == 403 { return "this host does not update itself" }
            if status == 409 { return "an update is already running" }
            return "the host refused the update (\(status))"
        case .noHost:
            return "no host is paired"
        }
    }
}

/// The two calls. One freshly minted ticket per request, exactly like `BotComputerClient`: the host
/// spends a ticket on the request that carries it.
public struct HostUpdateClient: Sendable {
    public typealias Endpoint = @Sendable () async throws -> (baseURL: URL, ticket: String)

    private let endpoint: Endpoint
    private let session: URLSession

    public init(endpoint: @escaping Endpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    /// `GET /v1/update`. `refresh` asks the host to re-read its release feed instead of using its
    /// six-hour cache — used by the About tab's own "check now", never by the poll.
    public func status(refresh: Bool = false) async throws -> HostUpdateStatus {
        var path = "v1/update"
        if refresh { path += "?refresh=1" }
        let prepared = try await endpoint()
        var request = URLRequest(url: prepared.baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(prepared.ticket)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HostUpdateError.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw HostUpdateError.rejected(status: http.statusCode, detail: Self.detail(from: data))
        }
        return try Self.decode(data)
    }

    /// `POST /v1/update` — 202 and the target, while the host downloads. Nothing is installed
    /// unless the host's own verification passes, so this call is the whole of the app's authority.
    public func apply() async throws -> HostUpdateAck {
        let prepared = try await endpoint()
        var request = URLRequest(url: prepared.baseURL.appendingPathComponent("v1/update"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(prepared.ticket)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HostUpdateError.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw HostUpdateError.rejected(status: http.statusCode, detail: Self.detail(from: data))
        }
        struct Body: Decodable { let target: String; let state: String? }
        let body: Body
        do {
            body = try JSONDecoder().decode(Body.self, from: data)
        } catch {
            throw HostUpdateError.malformedResponse
        }
        return HostUpdateAck(target: body.target, state: body.state ?? "started")
    }

    // MARK: Plumbing

    /// The wire shape. Kept private so the public model can be Swift-named (`notesURL`,
    /// `canSelfUpdate`) without a key strategy that would also rewrite the fields that are already
    /// snake_case in one place and camel in another.
    private struct Wire: Decodable {
        let current: String
        let latest: String?
        let available: Bool?
        let notesUrl: String?
        let checkedAt: Double?
        let canSelfUpdate: Bool?
        let arch: String?
        let error: String?
        let progress: String?
        let lastUpdate: WireRecord?
    }

    private struct WireRecord: Decodable {
        let target: String?
        let previous: String?
        let state: String?
        let attempts: Int?
        let startedAt: Double?
    }

    private static func decode(_ data: Data) throws -> HostUpdateStatus {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let wire: Wire
        do {
            wire = try decoder.decode(Wire.self, from: data)
        } catch {
            throw HostUpdateError.malformedResponse
        }
        let record = wire.lastUpdate.map { payload in
            HostUpdateRecord(target: payload.target ?? "",
                             previous: payload.previous ?? "",
                             state: payload.state ?? "",
                             attempts: payload.attempts ?? 0,
                             startedAt: seconds(payload.startedAt))
        }
        return HostUpdateStatus(
            current: wire.current,
            latest: wire.latest,
            // `available` is the host's statement, and an unreadable feed never claims one.
            available: wire.available ?? false,
            notesURL: wire.notesUrl.flatMap { URL(string: $0) },
            checkedAt: seconds(wire.checkedAt),
            canSelfUpdate: wire.canSelfUpdate ?? false,
            arch: wire.arch ?? "",
            error: wire.error,
            progress: wire.progress,
            lastUpdate: record
        )
    }

    private static func seconds(_ raw: Double?) -> Date? {
        guard let raw, raw > 0 else { return nil }
        // Hosts write epoch seconds; a value this large is milliseconds in some other schema, not a
        // date in the year 57000.
        let value = raw > 100_000_000_000 ? raw / 1000 : raw
        return Date(timeIntervalSince1970: value)
    }

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
}

// MARK: - The row both apps draw

/// A host update, as the bell's first row draws it.
///
/// Nothing here talks to the host, and nothing here applies anything: `HostUpdateTracker` (in
/// `HermesAppKit`) decides the phase from answers the model already asked for, and this value is
/// what the Mac's popover, the phone's sheet and Settings ▸ About draw — one set of words, so the
/// two apps cannot describe the same press differently.
///
/// It lives in `HermesKit` rather than with the tracker because `HermeyUI` depends on this module
/// and not on `HermesAppKit`; a view that imported the app state would have to re-implement it.
public struct HostUpdate: Equatable, Sendable {
    /// Where a press is, in the order a press moves through it.
    ///
    /// `restarting` is deliberately a *state* and not an error: the socket dropping during a host
    /// update is the expected middle of it, and painting it red would train the owner to ignore red.
    public enum Phase: Equatable, Sendable {
        /// A version is published and this host could install it. The row's button is live.
        case available
        case downloading
        case verifying
        case restarting
        case updated(String)
        case rolledBack(String)
        case failed(String)
    }

    /// What this host is running.
    public let current: String
    /// The version it would move to.
    public let latest: String
    /// The release page. Absent on a host that did not send one, and then no link is drawn.
    public let notesURL: URL?
    public let phase: Phase
    /// The host said it may update itself. False is a row that is never drawn at all.
    public let canUpdate: Bool

    public init(current: String,
                latest: String,
                notesURL: URL? = nil,
                phase: Phase,
                canUpdate: Bool = true) {
        self.current = current
        self.latest = latest
        self.notesURL = notesURL
        self.phase = phase
        self.canUpdate = canUpdate
    }

    /// The row's title. "Host update" and not "Update": this replaces the service on the machine,
    /// not the app in the Dock, and the two must never be confused in a screenshot.
    public var headline: String { "Host update" }

    /// "0.3.9 → 0.4.0" — the whole of what is on offer.
    public var versionLine: String { "\(current) → \(latest)" }

    /// The second line: what the press is doing, or what it did.
    public var stateText: String? {
        switch phase {
        case .available: return nil
        case .downloading: return "Downloading…"
        case .verifying: return "Verifying…"
        case .restarting: return "Restarting…"
        case .updated(let version): return "Updated to \(version)"
        case .rolledBack(let version): return "Rolled back to \(version)"
        case .failed(let reason): return "Update failed: \(reason)"
        }
    }

    /// A press is in flight: the row shows a spinner and no button.
    public var isBusy: Bool {
        switch phase {
        case .downloading, .verifying, .restarting: return true
        default: return false
        }
    }

    /// The press is over — success, rollback or failure. The row can be dismissed.
    public var isSettled: Bool {
        switch phase {
        case .updated, .rolledBack, .failed: return true
        default: return false
        }
    }

    /// Something is waiting behind the bell. Only `available`: a press that is running is visible
    /// because the owner is in the list, and a settled row is news rather than work.
    public var wantsAttention: Bool { phase == .available }

    /// What the button says, or `nil` when there is no button.
    public var buttonTitle: String? {
        switch phase {
        case .available: return "Update"
        case .failed: return "Try again"
        default: return nil
        }
    }

    /// Whether the row's button does anything right now: an available update, or a failed press the
    /// owner may retry. Never while one is running, and never when the host said it cannot.
    public var canStartPress: Bool {
        guard canUpdate else { return false }
        switch phase {
        case .available, .failed: return true
        default: return false
        }
    }

    /// Whether the "What's new" link is drawn: not during a press, and only when the host sent one.
    public var showsNotes: Bool { notesURL != nil && !isBusy }
}
