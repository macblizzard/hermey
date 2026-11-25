import Foundation

/// What a tool row's stored JSON actually means.
///
/// The host stores a call and its result as JSON, and rendering those verbatim — which is what the
/// cards did — turned every expanded row into a wall of escaped text:
///
///     {"output":"=== recent commits\naf6b435 fix(tools): …","exit_code":0,"cwd":"…","error":null}
///
/// Nobody reads that, and the one thing a reader wants (the command's own output, or a file's
/// contents with real line breaks) is inside it. This unwraps the fields that carry human content
/// and keeps the machine facts for the footer, where they belong.
public enum ToolPayload {

    public struct Info: Equatable {
        /// The text worth reading, with real newlines.
        public var body: String
        /// The shell exit status, when the result carried one.
        public var exitCode: Int?
        /// How many lines `body` has — what the footer reports instead of repeating the body.
        public var lineCount: Int?
        /// "35 lines", "4 matches", "truncated" — facts that sit beside the body, not inside it.
        public var notes: [String]
    }

    /// The fields the host uses for a result, in the order worth reading. `output` is a shell
    /// command's stdout, `content` a file's text, `result`/`message` the generic ones.
    private static let bodyKeys = ["output", "stdout", "matches_text", "content", "diff", "text",
                                   "result", "message"]

    /// The fields a *call* is described by, most specific first: a terminal call's command says
    /// more than its timeout, and a search's pattern says more than its path.
    private static let headlineKeys = ["command", "description", "pattern", "query",
                                       "path", "file_path", "url", "name"]

    // MARK: Result

    public static func info(raw: String?) -> Info? {
        guard let raw, let object = jsonObject(raw) else { return nil }

        var info = Info(body: "", exitCode: nil, lineCount: nil, notes: [])

        // A search result is a list, not a blob: one line per match reads the way the tool reported.
        if let matches = object["matches"] as? [[String: Any]], !matches.isEmpty {
            info.body = matches.map { match in
                let path = (match["path"] as? String) ?? ""
                let line = (match["line"] as? Int).map(String.init) ?? ""
                let content = ((match["content"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { return "\(path): \(content)" }
                return "\(path):\(line): \(content)"
            }
            .joined(separator: "\n")
            info.notes.append(matches.count == 1 ? "1 match" : "\(matches.count) matches")
        }

        if info.body.isEmpty {
            for key in bodyKeys {
                if let text = object[key] as? String, !text.isEmpty {
                    info.body = text
                    break
                }
            }
        }

        // A *call* whose arguments are the content. History keeps no result for a terminal row —
        // `session_history` omits ordinary command output — so what a card opens with is the call
        // itself, and its JSON is one long escaped string whose whole point is the command inside.
        // Only the two shapes where that is true are unwrapped: a `patch` call keeps its JSON,
        // because its hunks are several fields and the path alone is not the story.
        if info.body.isEmpty, let command = object["command"] as? String, !command.isEmpty {
            info.body = tidy(command)
        } else if info.body.isEmpty, let pattern = object["pattern"] as? String, !pattern.isEmpty {
            info.body = pattern
        } else if info.body.isEmpty, let code = object["code"] as? String, !code.isEmpty {
            // `execute_code` — the script *is* the call. A card that opened on
            // `{"code":"import …"}` buried the only thing worth reading.
            info.body = tidy(code)
        }

        // A search that reports `total_count` but was given no `matches` array still counted.
        if let total = object["total_count"] as? Int, !info.notes.contains(where: { $0.contains("match") }) {
            info.notes.append(total == 1 ? "1 match" : "\(total) matches")
        }

        // A failure whose payload is only an error still has something to say.
        if info.body.isEmpty, let error = object["error"] as? String, !error.isEmpty {
            info.body = error
        }

        if let code = object["exit_code"] as? Int {
            info.exitCode = code
        }
        if let total = object["total_lines"] as? Int {
            info.lineCount = total
        }
        if object["truncated"] as? Bool == true {
            info.notes.append("truncated")
        }
        if let size = object["file_size"] as? Int {
            info.notes.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }

        // A body always has a line count; a caller's footer should not have to count again.
        if info.lineCount == nil, !info.body.isEmpty {
            info.lineCount = info.body.split(separator: "\n", omittingEmptySubsequences: false).count
        }
        guard !info.body.isEmpty || info.exitCode != nil || !info.notes.isEmpty else { return nil }
        return info
    }

    /// Whether the row failed, from the result the host stored: an exit status other than zero, or
    /// an error field with something in it. The cards used to print a green tick over a command that
    /// exited 2, because nothing looked at the payload.
    public static func failed(raw: String?) -> Bool {
        guard let raw, let object = jsonObject(raw) else { return false }
        if let code = object["exit_code"] as? Int, code != 0 { return true }
        if let error = object["error"] as? String,
           !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return false
    }

    // MARK: Call

    /// One line describing what the call asked for.
    ///
    /// Prefers the parsed JSON; falls back to the host's preview when that preview was cut off
    /// mid-object (it is capped at ~80 characters, so `{"command":"cd …` is a real case).
    public static func headline(raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        if let object = jsonObject(raw) {
            for key in headlineKeys {
                if let text = object[key] as? String, let line = firstLine(text) { return line }
            }
            if let first = object.values.compactMap({ $0 as? String }).first, let line = firstLine(first) {
                return line
            }
            return nil
        }

        // A truncated object: salvage the first value so the header reads `cd ~/jobs …` rather
        // than `{"command":"cd ~/jobs …`.
        if raw.hasPrefix("{"), let colon = raw.firstIndex(of: ":") {
            let rest = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            var cleaned = String(rest.drop(while: { $0 == "\"" || $0 == " " }))
            cleaned = cleaned
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\n", with: " ")
            return firstLine(cleaned)
        }

        return firstLine(raw)
    }

    /// A card's header is one line: the first non-empty one, clipped so the layout has a bound.
    /// The host sometimes double-escapes the solidus (`\\/root\\/jobs`), which is valid JSON but
    /// leaves the command reading like a regex. The value is what matters, not the escaping.
    private static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: "\\/", with: "/")
    }

    private static func firstLine(_ text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                return trimmed.count > 100 ? String(trimmed.prefix(100)) + "…" : trimmed
            }
        }
        return nil
    }

    // MARK: Remembered reads

    /// `info(raw:)` for a payload that has already been read once.
    ///
    /// A tool card's body is evaluated on every publish — every 40 ms while a turn streams, and
    /// every frame of a scroll — and `info(raw:)` is a `JSONSerialization` pass over the whole
    /// result. On a conversation full of long logs that is the expensive thing a row does, and it
    /// used to redo it to draw a tick. The result is a pure function of the text, so it is
    /// remembered per distinct text, bounded, and evicted when the cap is reached.
    public static func remembered(_ raw: String?) -> Info? {
        guard let raw, !raw.isEmpty else { return nil }
        if let hit = PayloadMemo.shared.info(for: raw) { return hit }
        let parsed = info(raw: raw)
        PayloadMemo.shared.store(info: parsed, for: raw)
        return parsed
    }

    /// `failed(raw:)` for a payload that has already been read once.
    public static func rememberedFailure(_ raw: String?) -> Bool {
        guard let raw, !raw.isEmpty else { return false }
        if let hit = PayloadMemo.shared.failure(for: raw) { return hit }
        let isFailed = failed(raw: raw)
        PayloadMemo.shared.store(failure: isFailed, for: raw)
        return isFailed
    }

    // MARK: Plumbing

    private static func jsonObject(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// The remembered payload reads behind `ToolPayload.remembered`.
///
/// Bounded twice: by entry count and by total characters, because the entries are whole tool results
/// and a session can hold hundreds of them. A payload larger than `maxPayloadCharacters` is read
/// once and not kept — the transcript already holds it, and hoarding a second copy of a megabyte of
/// log to save one parse is not a trade worth making.
private final class PayloadMemo {
    static let shared = PayloadMemo()

    private struct Entry {
        var info: ToolPayload.Info? = nil
        var failed: Bool? = nil
        var infoRead = false
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var characters = 0

    private let limit = 96
    private let maxCharacters = 512 * 1024
    private let maxPayloadCharacters = 256 * 1024

    /// The remembered `info` for this text, or `nil` when it has not been read. The double optional
    /// distinguishes "not remembered" from "remembered as unreadable".
    func info(for raw: String) -> ToolPayload.Info?? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[raw], entry.infoRead else { return nil }
        return .some(entry.info)
    }

    func failure(for raw: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return entries[raw]?.failed
    }

    func store(info: ToolPayload.Info?, for raw: String) {
        mutate(raw) { $0.info = info; $0.infoRead = true }
    }

    func store(failure: Bool, for raw: String) {
        mutate(raw) { $0.failed = failure }
    }

    private func mutate(_ raw: String, _ change: (inout Entry) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if var entry = entries[raw] {
            change(&entry)
            entries[raw] = entry
            return
        }
        guard raw.count <= maxPayloadCharacters else { return }
        var entry = Entry()
        change(&entry)
        entries[raw] = entry
        order.append(raw)
        characters += raw.count
        while order.count > limit || characters > maxCharacters {
            guard !order.isEmpty else { break }
            let old = order.removeFirst()
            entries.removeValue(forKey: old)
            characters -= old.count
        }
    }
}
