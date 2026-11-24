import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What kind of file an attachment is, decided from its name.
///
/// The app never parses an office document: the host extracts the text. What the app owes the
/// person is the *look* of the thing they attached or the bot wrote — a page for a PDF, a table for
/// a spreadsheet, a document for Word — and the one name the file has. Every decision here is
/// extension-based on purpose, so it is the same on both platforms and costs no file read.
public enum AttachmentKind: String, Sendable, CaseIterable, Equatable {
    case image
    case pdf
    case word
    case spreadsheet
    case other

    /// The three office types the pickers offer beside photographs.
    public static let officeExtensions: [String] = ["pdf", "docx", "xlsx"]

    public init(name: String) {
        self.init(fileExtension: (name as NSString).pathExtension)
    }

    public init(fileExtension rawExtension: String) {
        switch rawExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp":
            self = .image
        case "pdf":
            self = .pdf
        case "doc", "docx", "rtf", "odt", "pages", "txt", "md", "markdown":
            self = .word
        case "xls", "xlsx", "csv", "tsv", "numbers", "ods":
            self = .spreadsheet
        default:
            self = .other
        }
    }

    public var isImage: Bool { self == .image }

    /// The SF Symbol a row wears: chosen by what the file *is*, never by its name's shape.
    public var symbolName: String {
        switch self {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .word: return "doc.text"
        case .spreadsheet: return "tablecells"
        case .other: return "doc"
        }
    }

    /// The quiet word a row shows when it does not know the byte count.
    public var displayName: String {
        switch self {
        case .image: return "Image"
        case .pdf: return "PDF"
        case .word: return "Document"
        case .spreadsheet: return "Spreadsheet"
        case .other: return "File"
        }
    }
}

/// Where the bytes of a file live on the host.
///
/// Two shapes, because the chat produces files two ways: something the person attached (the host
/// stored it and the transcript quotes its name) and something the bot wrote into its workspace (a
/// link in the reply body names a path). Both are fetched through the same device bearer; the route
/// is the only difference.
public enum AttachmentLocation: Hashable, Sendable {
    /// `GET /v1/attachments/{profile}/{name}` — the route the pictures already use.
    case uploaded(profile: String, name: String)
    /// `GET /v1/workspace/{profile}/file?path=…` — the route the Library already uses.
    case workspaceFile(profile: String, path: String)

    public var profile: String {
        switch self {
        case let .uploaded(profile, _): return profile
        case let .workspaceFile(profile, _): return profile
        }
    }

    /// The file's own name, which is what a row shows.
    public var displayName: String {
        switch self {
        case let .uploaded(_, name):
            return (name as NSString).lastPathComponent
        case let .workspaceFile(_, path):
            let tail = (path as NSString).lastPathComponent
            return tail.isEmpty ? path : tail
        }
    }

    public var kind: AttachmentKind { AttachmentKind(name: displayName) }

    /// The name the bytes sit under in the attachment cache.
    ///
    /// An uploaded file keeps the host's own name, because that is the handle the transcript quotes
    /// back and the cache was already keyed that way for pictures. A workspace file is keyed by a
    /// fingerprint of its path *plus* its extension: two folders may legally hold `report.xlsx`, and
    /// Quick Look picks a viewer from the suffix.
    public var cacheKey: String {
        switch self {
        case let .uploaded(_, name):
            return (name as NSString).lastPathComponent
        case let .workspaceFile(_, path):
            let name = (path as NSString).lastPathComponent
            let suffix = (name as NSString).pathExtension.lowercased()
            let stem = "workspace-\(Self.fingerprint(path))"
            return suffix.isEmpty ? stem : "\(stem).\(suffix)"
        }
    }

    /// FNV-1a over the UTF-8 bytes: small, stable between launches, and not Swift's randomised
    /// `hashValue` (a cache key must survive a relaunch).
    private static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

/// A bot-made file, as the reply body names it: `/v1/workspace/{profile}/file?path=…`.
///
/// The list route is the host's own shape (`WorkspaceBrowser.swift` speaks it too), so the link is
/// recognised, not guessed: four path segments, the last one `file`, and a `path` query item.
public struct WorkspaceFileLink: Hashable, Sendable {
    /// The one substring a body must contain for a link to be one of these.
    public static let routeMarker = "/v1/workspace/"

    public let profile: String
    /// Relative to the bot's workspace folder, exactly as the host spells it.
    public let path: String
    /// The size the link declared, when it declared one (`?size=`), in bytes.
    public let size: Int?
    /// What the message actually carried — kept so the prose can be edited without re-parsing.
    public let text: String

    public init?(text rawText: String) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>")))
        guard trimmed.contains(Self.routeMarker) else { return nil }
        // A body may carry the route as a path (`/v1/workspace/…`) or as a whole URL. A host name is
        // never part of what we need, so a stand-in is used when there is no scheme at all.
        var candidate = trimmed
        if !candidate.contains("://") {
            candidate = "https://workspace.invalid" + (candidate.hasPrefix("/") ? candidate : "/" + candidate)
        }
        guard let components = URLComponents(string: candidate) else { return nil }
        let segments = components.path.split(separator: "/").map(String.init)
        guard segments.count == 4, segments[0] == "v1", segments[1] == "workspace", segments[3] == "file"
        else { return nil }
        let profile = segments[2]
        guard !profile.isEmpty else { return nil }
        guard let rawPath = components.queryItems?.first(where: { $0.name == "path" })?.value,
              !rawPath.isEmpty else { return nil }
        let path = rawPath.removingPercentEncoding ?? rawPath
        // A workspace path is relative and cannot walk out of the folder it names. The host refuses
        // it too; refusing it here keeps a hostile link from becoming a fetch.
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        self.text = trimmed
        self.profile = profile
        self.path = path
        self.size = components.queryItems?
            .first(where: { $0.name == "size" })?.value
            .flatMap { Int($0) }
    }

    public var name: String {
        let tail = (path as NSString).lastPathComponent
        return tail.isEmpty ? path : tail
    }

    public var location: AttachmentLocation { .workspaceFile(profile: profile, path: path) }
}

/// A reply split into the words to draw and the bot-made files it names.
///
/// A link to the workspace route is not prose: a 90-character tailnet URL in the middle of a
/// sentence is noise, and the file it points at deserves a row with a name, a size and an icon. The
/// label of a markdown link stays in the sentence ("here is [the report](…)" reads "here is the
/// report"); a bare URL is taken out whole.
public struct WorkspaceLinkScan: Sendable, Equatable {
    public let prose: String
    public let links: [WorkspaceFileLink]

    public init(prose: String, links: [WorkspaceFileLink]) {
        self.prose = prose
        self.links = links
    }

    public static func scan(_ body: String) -> WorkspaceLinkScan {
        var links: [WorkspaceFileLink] = []
        var edits: [(range: Range<String.Index>, replacement: String)] = []
        var cursor = body.startIndex

        while let marker = body.range(of: WorkspaceFileLink.routeMarker, range: cursor..<body.endIndex) {
            guard let urlRange = urlRange(around: marker.lowerBound, in: body) else {
                cursor = marker.upperBound
                continue
            }
            defer { cursor = urlRange.upperBound }
            guard let link = WorkspaceFileLink(text: String(body[urlRange])) else { continue }
            links.append(link)
            edits.append(replacement(for: urlRange, link: link, in: body))
        }

        guard !links.isEmpty else { return WorkspaceLinkScan(prose: body, links: []) }
        var prose = body
        for edit in edits.reversed() where prose.indices.contains(edit.range.lowerBound) {
            prose.replaceSubrange(edit.range, with: edit.replacement)
        }
        return WorkspaceLinkScan(prose: tidy(prose), links: links)
    }

    // MARK: Ranges

    /// The characters a URL is allowed to contain inside a message: everything but the ones that
    /// end it (whitespace, a closing bracket, punctuation a sentence puts after it).
    private static func isURLCharacter(_ character: Character) -> Bool {
        if character.isWhitespace { return false }
        return !"()[]<>\"'`".contains(character)
    }

    /// The whole URL around a route marker: walk left to its first character, right to its last.
    private static func urlRange(around marker: String.Index, in body: String) -> Range<String.Index>? {
        var start = marker
        while start > body.startIndex {
            let previous = body.index(before: start)
            guard isURLCharacter(body[previous]) else { break }
            start = previous
        }
        var end = marker
        while end < body.endIndex, isURLCharacter(body[end]) {
            end = body.index(after: end)
        }
        // A sentence's full stop is not part of the file name.
        while end > start, ".,;:!?'\"".contains(body[body.index(before: end)]) {
            end = body.index(before: end)
        }
        guard start < end else { return nil }
        return start..<end
    }

    /// What a link is replaced with: the markdown label when there is one, nothing otherwise.
    ///
    /// A bare URL is taken out whole. A `[label](url)` keeps its label so the sentence still reads;
    /// the row underneath carries the name, which is why an empty label is simply removed.
    private static func replacement(for urlRange: Range<String.Index>,
                                    link: WorkspaceFileLink,
                                    in body: String) -> (range: Range<String.Index>, replacement: String) {
        guard urlRange.lowerBound > body.startIndex else { return (urlRange, "") }
        let before = body.index(before: urlRange.lowerBound)
        guard body[before] == "(" else { return (urlRange, "") }
        guard before > body.startIndex else { return (urlRange, "") }
        let closeBracket = body.index(before: before)
        guard body[closeBracket] == "]" else { return (urlRange, "") }
        guard urlRange.upperBound < body.endIndex, body[urlRange.upperBound] == ")" else {
            return (urlRange, "")
        }

        var openBracket = closeBracket
        while openBracket > body.startIndex {
            openBracket = body.index(before: openBracket)
            let character = body[openBracket]
            if character == "\n" { break }
            if character == "[" {
                let label = String(body[body.index(after: openBracket)..<closeBracket])
                    .trimmingCharacters(in: .whitespaces)
                let end = body.index(after: urlRange.upperBound)
                return (openBracket..<end, label.isEmpty ? link.name : label)
            }
        }
        return (urlRange, "")
    }

    /// Runs of blank lines left behind by a removed link are collapsed, and the ends trimmed, so a
    /// reply does not grow a gap where its URL was.
    private static func tidy(_ text: String) -> String {
        var prose = text
        while prose.contains("\n\n\n") {
            prose = prose.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return prose.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Why a file could not be fetched, in the words a row shows.
public enum AttachmentFetchError: Error, LocalizedError, Equatable, Sendable {
    /// No paired host, or the app never injected a client.
    case notConfigured
    /// The host answered 404. For a bot-made file this is usually "still being written".
    case notReady
    case refused(Int)
    case tooLarge(Int)
    case notHTTP
    /// The bytes arrived but could not be put in the cache, so no viewer can be handed a URL.
    case cacheUnavailable

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "This device is not paired with the host."
        case .notReady: return "That file is not on the host yet."
        case let .refused(status): return "The host refused that file (HTTP \(status))."
        case let .tooLarge(bytes):
            return "\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) is too large to open here"
        case .notHTTP: return "The host's answer was not HTTP."
        case .cacheUnavailable: return "That file could not be saved for viewing."
        }
    }

    /// The quiet state a 404 deserves. A bot that announced a file a moment before writing it is
    /// not an error; the row says it is not there yet and offers to look again.
    public var isNotReady: Bool {
        if case .notReady = self { return true }
        if case .refused(404) = self { return true }
        return false
    }
}

/// The bytes of one attachment, over the device bearer.
///
/// Same ticket rule as the workspace, computer and icon clients: every request mints its own
/// single-use ticket, because the host spends it on that one call. This is the file half of the
/// client the transcript's pictures already use — the route for an upload is byte-for-byte
/// `GET /v1/attachments/{profile}/{name}`.
public struct AttachmentFileClient: Sendable {
    public typealias Endpoint = @Sendable () async throws -> (baseURL: URL, ticket: String)

    /// A document someone asked to open, not a file store: the same ceiling the workspace viewer
    /// applies, so a 60 MB scan over a tailnet is refused before it is pulled into memory.
    public static let maximumBytes = 24 * 1024 * 1024

    private let endpoint: Endpoint
    private let session: URLSession

    public init(endpoint: @escaping Endpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    public func bytes(for location: AttachmentLocation) async throws -> Data {
        let resolved = try await endpoint()
        let url: URL
        switch location {
        case let .uploaded(profile, name):
            guard !name.isEmpty, name != ".", name != "..",
                  !name.contains("/"), !name.contains("\\"),
                  let encodedProfile = profile.addingPercentEncoding(withAllowedCharacters: URLPath.componentAllowed),
                  let encodedName = name.addingPercentEncoding(withAllowedCharacters: URLPath.componentAllowed)
            else { throw AttachmentFetchError.notHTTP }
            url = resolved.baseURL
                .appendingPathComponent("v1/attachments/\(encodedProfile)/\(encodedName)")
        case let .workspaceFile(profile, path):
            guard let encodedProfile = profile.addingPercentEncoding(withAllowedCharacters: URLPath.componentAllowed),
                  var components = URLComponents(url: resolved.baseURL
                        .appendingPathComponent("v1/workspace/\(encodedProfile)/file"),
                                                 resolvingAgainstBaseURL: false)
            else { throw AttachmentFetchError.notHTTP }
            components.queryItems = [URLQueryItem(name: "path", value: path)]
            guard let built = components.url else { throw AttachmentFetchError.notHTTP }
            url = built
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(resolved.ticket)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AttachmentFetchError.notHTTP }
        if http.statusCode == 404 { throw AttachmentFetchError.notReady }
        guard (200..<300).contains(http.statusCode) else {
            throw AttachmentFetchError.refused(http.statusCode)
        }
        guard data.count <= Self.maximumBytes else { throw AttachmentFetchError.tooLarge(data.count) }
        return data
    }
}

/// The attachment cache, addressed by a location rather than a bare name.
///
/// Bytes live in `AttachmentImageStore` — the same on-disk cache the pictures already use, with the
/// same 240-file prune — because one cache with one policy is easier to keep honest than two. The
/// URL it hands back is a real file with the file's own extension, which is what Quick Look and the
/// iOS share sheet need to pick a viewer.
public enum AttachmentFileCache {

    /// A local file for this location, when its bytes are already cached.
    public static func cachedURL(for location: AttachmentLocation) -> URL? {
        AttachmentImageStore.url(named: location.cacheKey)
    }

    public static func cachedSize(for location: AttachmentLocation) -> Int? {
        AttachmentImageStore.size(named: location.cacheKey)
    }

    /// Writes the bytes under the location's cache key and answers the file a viewer can open.
    @discardableResult
    public static func store(_ data: Data, for location: AttachmentLocation) -> URL? {
        guard !data.isEmpty else { return nil }
        AttachmentImageStore.save(data, as: location.cacheKey)
        return AttachmentImageStore.url(named: location.cacheKey)
    }
}
