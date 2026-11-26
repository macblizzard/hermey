import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - What a bot remembers

/// One of the two documents a profile carries into every turn.
///
/// `present` and `error` are separate on purpose: "there is no file yet" is an ordinary state for a
/// new bot, while "the file is there and could not be read" is a fault the owner may need to fix.
/// Collapsing them into an empty string would draw both as "nothing remembered".
public struct BotMemoryDocument: Hashable, Sendable, Identifiable {
    /// The file's own name (`MEMORY.md` / `USER.md`) — what the heading shows.
    public let name: String
    /// One line saying whose notes these are, in the sheet's words.
    public let label: String
    public let text: String
    /// Characters the runtime counts this document at, which is what its budget measures.
    public let chars: Int
    /// The file's size on disk. Bytes, not characters: `§` is two of them.
    public let bytes: Int
    /// The runtime's character budget for this document, from the bot's own config.
    public let limit: Int
    public let present: Bool
    /// When the file was last written, as the host saw it. `nil` for a document with no file.
    public let modifiedAt: Date?
    public let error: String?

    public var id: String { name }

    /// The two documents a bot's memory can be: an allow-list, never a path.
    ///
    /// The host refuses any other name with a 422 naming these two (`DOCUMENTS` in hermeyd's
    /// `bot_docs.rs`). The app keeps the same list so it cannot build a request it already knows the
    /// host will refuse, and so a name that arrived from somewhere else is never joined into a path.
    public static let allowedNames = ["MEMORY.md", "USER.md"]

    public static func isAllowedName(_ name: String) -> Bool {
        allowedNames.contains(name)
    }

    public init(name: String, label: String, text: String = "", chars: Int = 0,
                bytes: Int = 0, limit: Int = 0, present: Bool = false,
                modifiedAt: Date? = nil, error: String? = nil) {
        self.name = name
        self.label = label
        self.text = text
        self.chars = chars
        self.bytes = bytes
        self.limit = limit
        self.present = present
        self.modifiedAt = modifiedAt
        self.error = error
    }

    /// "2,981 characters" — the size of the thing being replayed into every turn.
    public var sizeText: String {
        let count = NumberFormatter.decimal.string(from: NSNumber(value: chars)) ?? "\(chars)"
        return chars == 1 ? "1 character" : "\(count) characters"
    }

    /// "4,210 / 6,100 characters" — what the memory tool itself prints when it refuses a write.
    ///
    /// The same shape the runtime uses (`MemoryStore._usage_pct`), so a number the owner reads here
    /// and a number the agent reports in a chat are the same accounting, not two that disagree.
    public var budgetText: String {
        let used = NumberFormatter.decimal.string(from: NSNumber(value: chars)) ?? "\(chars)"
        let budget = NumberFormatter.decimal.string(from: NSNumber(value: limit)) ?? "\(limit)"
        return "\(used) / \(budget) characters"
    }

    /// "when it was last written", in a line, or nothing when there is no file.
    public var editedText: String? {
        guard let modifiedAt else { return nil }
        return "edited \(modifiedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    /// How far over the budget the text the pane holds would be, or `nil` when it fits.
    ///
    /// Counted the runtime's way rather than by raw length — the memory tool measures the entries it
    /// parses, so a document padded with blank lines is cheaper than its bytes suggest and one long
    /// entry is exactly as expensive as it looks.
    public func overBudget(by text: String) -> Int? {
        let over = MemoryBudget.counted(text) - limit
        return over > 0 ? over : nil
    }

    static func decode(_ object: [String: Any], fallbackName: String) -> BotMemoryDocument {
        let text = object["text"] as? String ?? ""
        return BotMemoryDocument(
            name: (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName,
            label: object["label"] as? String ?? "",
            text: text,
            // Trust the server's count when it sends one — it is the runtime's own count — and fall
            // back to counting the text we hold so the sheet never says "0 characters" over real words.
            chars: object["chars"] as? Int ?? MemoryBudget.counted(text),
            bytes: object["bytes"] as? Int ?? text.utf8.count,
            limit: object["limit"] as? Int ?? 0,
            present: object["present"] as? Bool ?? !text.isEmpty,
            modifiedAt: BotMemoryDocument.date(object["modified_at"]),
            error: object["error"] as? String
        )
    }

    /// One document on its own (`GET /v1/bots/{profile}/memory/{name}`).
    ///
    /// A payload is a memory document only if it carries a name and the two members that describe the
    /// file; anything else is a host that answered with something this app must not draw as text.
    public static func decode(_ data: Data) -> BotMemoryDocument? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["name"] is String,
              object.keys.contains("text"),
              object.keys.contains("present") else {
            return nil
        }
        return .decode(object, fallbackName: "MEMORY.md")
    }

    /// ISO-8601 from the host, or nothing. The host sends a string; a number here is a shape this app
    /// does not draw, and drawing "1970" would be worse than drawing no date at all.
    ///
    /// Two parsers because the host's `iso_at` has no fractional seconds while other timestamps on
    /// this host do: one formatter would silently read half of them as "no date".
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return BotMemoryDocument.formatter.date(from: text)
            ?? BotMemoryDocument.preciseFormatter.date(from: text)
    }

    private static let formatter = ISO8601DateFormatter()

    private static let preciseFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// The runtime's memory accounting, mirrored so the pane can refuse a save before it is sent.
///
/// `tools/memory_tool_store.py` stores a document as its entries joined by `ENTRY_DELIMITER` and
/// counts `len(ENTRY_DELIMITER.join(entries))` against `memory_char_limit` / `user_char_limit`. This is
/// that arithmetic in Swift: a save the pane offers as fitting must be one the memory tool accepts,
/// and a save it offers as too large must be one the tool would refuse.
public enum MemoryBudget {
    /// The separator the runtime joins entries with (`ENTRY_DELIMITER`).
    public static let entryDelimiter = "\n§\n"

    /// The largest document the host will accept, in bytes (`MAX_DOCUMENT_BYTES` in hermeyd).
    public static let maxBytes = 256 * 1024

    /// The characters the runtime would count in `text`: each entry trimmed, empties dropped, rejoined.
    public static func counted(_ text: String) -> Int {
        text.components(separatedBy: entryDelimiter)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: entryDelimiter)
            .count
    }

    /// One sentence for a save that would not fit, naming the file, the limit and the overage.
    ///
    /// The host sends the same sentence when a save is refused, but the pane refuses first: letting the
    /// owner type and then answering 409 would mean a request that could never have succeeded, and the
    /// sentence would arrive after the decision instead of before it.
    public static func overBudgetSentence(name: String, used: Int, limit: Int) -> String {
        let over = used - limit
        return "\(name) would hold \(used) characters of a \(limit)-character budget — \(over) over. "
            + "Shorten it, or raise this bot's memory limit in its config."
    }

    /// One sentence for a document bigger than the host will take.
    public static func overBytesSentence(name: String, bytes: Int) -> String {
        "\(name) is \(bytes) bytes; the host takes at most \(maxBytes)."
    }
}

/// Why a memory read or save was refused, in words both shells show unchanged.
///
/// A save is the one thing here that changes what a bot carries into its next turn, so every failure
/// ends by saying whether anything was written.
public enum MemoryFailure {
    public static func sentence(_ error: Error) -> String {
        if error is URLError {
            return "The host could not be reached, so nothing was changed."
        }
        if error is BotAdminUnavailable {
            return "This host's bridge does not edit memory yet, so nothing was changed. "
                + "Update hermeyd on the host."
        }
        if let failure = error as? BridgeBotSessionPointer.Failure {
            switch failure {
            case .rejected(let status, let detail):
                let why = detail.map { ": \($0)" } ?? "."
                return "The host refused the change (\(status))\(why)"
            case .notHTTP, .malformedResponse:
                return "The host's answer was not a memory document, so nothing was changed."
            case .noProfile:
                return "This app is not pointed at a bot, so it cannot reach its memory."
            }
        }
        return "The host could not save that memory: \(error.localizedDescription)"
    }
}

private extension NumberFormatter {
    /// One grouping style for every count in the pane, so "4,210" and "6,100" line up.
    static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}


/// The three calls the memory pane needs, in one value.
///
/// A door hands the pane a *pane's worth* of access rather than three closures it might wire
/// inconsistently: the list, the fresh read the editor opens with, and the save. Both shells build one
/// of these from the same `AppModel` calls, so the Mac and the phone cannot reach different routes.
public struct BotMemoryAccess {
    public let load: () async throws -> BotMemory
    public let read: (String) async throws -> BotMemoryDocument
    public let save: (String, String) async throws -> BotMemoryDocument

    public init(load: @escaping () async throws -> BotMemory,
                read: @escaping (String) async throws -> BotMemoryDocument,
                save: @escaping (String, String) async throws -> BotMemoryDocument) {
        self.load = load
        self.read = read
        self.save = save
    }
}

/// A bot's memory, both documents (`GET /v1/bots/{profile}/memory`).
public struct BotMemory: Hashable, Sendable {
    public let memory: BotMemoryDocument
    public let user: BotMemoryDocument

    public init(memory: BotMemoryDocument, user: BotMemoryDocument) {
        self.memory = memory
        self.user = user
    }

    /// Nothing remembered on either side: a real state, and the one a sheet can say out loud.
    public var isEmpty: Bool {
        !memory.present && !user.present && memory.error == nil && user.error == nil
    }

    public static func decode(_ data: Data) -> BotMemory? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let memory = object["memory"] as? [String: Any] ?? [:]
        let user = object["user"] as? [String: Any] ?? [:]
        // A payload with neither key is not a memory answer — say so rather than draw two blanks
        // over a bot that may well have plenty remembered.
        guard object["memory"] != nil || object["user"] != nil else { return nil }
        return BotMemory(memory: .decode(memory, fallbackName: "MEMORY.md"),
                         user: .decode(user, fallbackName: "USER.md"))
    }
}

// MARK: - Handing a document to the share sheet

/// Staging for a share: a temp file that keeps the document's own name.
///
/// The alternative — sharing a URL — cannot work here: the bridge hands out single-use tickets, so a
/// link to a workspace file is dead before the other app can follow it. What leaves the phone has to
/// be the bytes, under the name the file actually has.
public enum WorkspaceSharing {
    /// Write `bytes` to a fresh temporary file called `name`.
    ///
    /// The name comes from the host, so it is reduced to one path component first: a document called
    /// `../../etc/passwd` must not be able to write outside the temp directory.
    public static func stage(_ bytes: Data, named name: String,
                             in directory: URL? = nil) throws -> URL {
        let safeName = safeFileName(name)
        let root = (directory ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("hermey-share", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(safeName, isDirectory: false)
        try bytes.write(to: url, options: .atomic)
        return url
    }

    /// Remove a staged file once the share sheet has closed.
    public static func discard(_ url: URL?) {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// One path component, non-empty, and never able to climb out of the directory it lands in.
    static func safeFileName(_ name: String) -> String {
        let last = name.split(separator: "/").last.map(String.init) ?? name
        let cleaned = last.replacingOccurrences(of: "\u{0}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "document" }
        return cleaned
    }
}
