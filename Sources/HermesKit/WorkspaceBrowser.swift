import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One document in a bot's workspace — either something it wrote or something you sent it.
///
/// `path` is relative to the folder it came from (`workspace/` or `attachments/`), which is what the
/// byte route resolves against; `id` keeps the two folders apart, because the same name can legally
/// exist in both.
public struct WorkspaceFile: Decodable, Identifiable, Sendable, Equatable {
    public let name: String
    public let path: String
    /// `workspace` for files the bot prepared, `attachments` for files the user sent.
    public let source: String
    /// Lowercased extension, or `file` when there is none.
    public let kind: String
    public let size: Int
    /// ISO-8601, UTC. Kept as text: the host is the authority and a date formatter belongs to the view.
    public let modified: String
    /// Whether the app can draw it. A `.docx` cannot be previewed from bytes alone; it is still listed.
    public let previewable: Bool

    public var id: String { "\(source):\(path)" }

    public var isFromBot: Bool { source == "workspace" }

    public init(name: String, path: String, source: String, kind: String, size: Int,
                modified: String, previewable: Bool) {
        self.name = name
        self.path = path
        self.source = source
        self.kind = kind
        self.size = size
        self.modified = modified
        self.previewable = previewable
    }
}

/// `GET /v1/workspace/<profile>`
public struct WorkspaceListing: Decodable, Sendable {
    public let profile: String
    public let files: [WorkspaceFile]
    /// True when the host stopped walking at its own cap — the list is the newest 400, not the whole disk.
    public let truncated: Bool

    public init(profile: String, files: [WorkspaceFile], truncated: Bool = false) {
        self.profile = profile
        self.files = files
        self.truncated = truncated
    }
}

public enum WorkspaceError: Error, Equatable, LocalizedError {
    case rejected(status: Int, detail: String?)
    case notHTTP
    case tooLarge(Int)
    case unreadable

    public var errorDescription: String? {
        switch self {
        case let .rejected(status, detail):
            if let detail, !detail.isEmpty { return detail }
            return status == 404 ? "that file is no longer in the workspace" : "the host refused (\(status))"
        case .notHTTP: return "the host's answer was not HTTP"
        case let .tooLarge(bytes): return "\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) is too large to open here"
        case .unreadable: return "this file has no readable text"
        }
    }
}

/// The workspace half of the bridge: the list, and the bytes of one document.
///
/// Same ticket rule as the computer and the icons — every request mints its own single-use ticket,
/// because the bridge spends it on that one call.
public struct WorkspaceClient: Sendable {
    public typealias Endpoint = @Sendable () async throws -> (baseURL: URL, ticket: String)

    private let endpoint: Endpoint
    private let session: URLSession

    /// A phone will not thank us for pulling a 60 MB scan over the tailnet to show one page of it.
    public static let viewLimit = 24 * 1024 * 1024

    public init(endpoint: @escaping Endpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    public func list(profile: String) async throws -> WorkspaceListing {
        let resolved = try await endpoint()
        var url = resolved.baseURL.appendingPathComponent("v1/workspace/\(profile)")
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = nil
            if let built = components.url { url = built }
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(resolved.ticket)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WorkspaceError.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw WorkspaceError.rejected(status: http.statusCode, detail: Self.detail(from: data))
        }
        return try JSONDecoder().decode(WorkspaceListing.self, from: data)
    }

    /// The document itself, and the type the host said it was.
    public func data(profile: String, file: WorkspaceFile) async throws -> (bytes: Data, contentType: String?) {
        guard file.size <= Self.viewLimit else { throw WorkspaceError.tooLarge(file.size) }
        let resolved = try await endpoint()
        var components = URLComponents(url: resolved.baseURL.appendingPathComponent("v1/workspace/\(profile)/file"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "path", value: file.path)]
        guard let url = components?.url else { throw WorkspaceError.notHTTP }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(resolved.ticket)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WorkspaceError.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw WorkspaceError.rejected(status: http.statusCode, detail: Self.detail(from: data))
        }
        return (data, http.value(forHTTPHeaderField: "Content-Type"))
    }

    private static func detail(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["detail"] as? String
    }
}

// MARK: - Kinds a viewer knows what to do with

public extension WorkspaceFile {
    /// Text the app can draw in a scroll view rather than handing to a document viewer.
    var isText: Bool {
        ["txt", "md", "markdown", "json", "csv", "tsv", "log", "yaml", "yml", "xml", "html", "swift",
         "py", "js", "ts", "sh", "css", "toml", "ini"].contains(kind)
    }

    var isPDF: Bool { kind == "pdf" }

    var isImage: Bool { ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(kind) }

    /// The SF Symbol a row wears. Chosen by what the file *is*, never by its name.
    var symbolName: String {
        switch kind {
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return "photo"
        case "md", "markdown": return "text.document"
        case "csv", "tsv", "xlsx": return "tablecells"
        case "json", "yml", "yaml", "toml": return "curlybraces"
        case "zip": return "archivebox"
        case "mp4", "mov": return "film"
        default: return isText ? "doc.text" : "doc"
        }
    }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    /// "3 hours ago" style, from the host's ISO-8601 stamp.
    func whenText(now: Date = Date()) -> String {
        guard let date = ISO8601DateFormatter().date(from: modified) else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
