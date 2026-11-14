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
    public let chars: Int
    public let present: Bool
    public let error: String?

    public var id: String { name }

    public init(name: String, label: String, text: String = "", chars: Int = 0,
                present: Bool = false, error: String? = nil) {
        self.name = name
        self.label = label
        self.text = text
        self.chars = chars
        self.present = present
        self.error = error
    }

    /// "2,981 characters" — the size of the thing being replayed into every turn.
    public var sizeText: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let count = formatter.string(from: NSNumber(value: chars)) ?? "\(chars)"
        return chars == 1 ? "1 character" : "\(count) characters"
    }

    static func decode(_ object: [String: Any], fallbackName: String) -> BotMemoryDocument {
        let text = object["text"] as? String ?? ""
        return BotMemoryDocument(
            name: (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName,
            label: object["label"] as? String ?? "",
            text: text,
            // Trust the server's count when it sends one — it is the file's own length — and fall
            // back to the text we hold so the sheet never says "0 characters" over real words.
            chars: object["chars"] as? Int ?? text.count,
            present: object["present"] as? Bool ?? !text.isEmpty,
            error: object["error"] as? String
        )
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
