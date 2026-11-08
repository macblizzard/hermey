import Foundation

/// One line of a hunk body.
public enum DiffLineKind: String, CaseIterable, Equatable, Sendable {
    case context
    case addition
    case deletion
    /// `\ No newline at end of file` — metadata attached to the previous line.
    case noNewline
}

public struct DiffLine: Equatable, Sendable {
    public var kind: DiffLineKind
    /// The line as it exists in the file, without the ` ` / `+` / `-` prefix.
    public var text: String
    /// 1-based line number in the old file, when the line exists there.
    public var oldNumber: Int?
    /// 1-based line number in the new file, when the line exists there.
    public var newNumber: Int?

    public init(kind: DiffLineKind, text: String, oldNumber: Int? = nil, newNumber: Int? = nil) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
    }
}

public struct DiffHunk: Equatable, Sendable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// The function context git appends after the closing `@@`.
    public var section: String?
    public var lines: [DiffLine]

    public init(
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        section: String? = nil,
        lines: [DiffLine] = []
    ) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.section = section
        self.lines = lines
    }
}

public struct DiffFile: Equatable, Sendable {
    public var oldPath: String?
    public var newPath: String?
    public var isBinary: Bool
    public var hunks: [DiffHunk]

    public init(oldPath: String? = nil, newPath: String? = nil, isBinary: Bool = false, hunks: [DiffHunk] = []) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.isBinary = isBinary
        self.hunks = hunks
    }

    /// The path to show in a header: the new one, unless this deletes the file.
    public var displayPath: String { newPath ?? oldPath ?? "" }

    public var addedCount: Int {
        hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .addition }.count }
    }

    public var removedCount: Int {
        hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .deletion }.count }
    }
}

/// A flattened row for a diff view: headers and hunk separators are rows too, so
/// a `List` can show a whole patch without knowing about the nested model.
public enum DiffRow: Equatable, Sendable {
    case file(index: Int, oldPath: String?, newPath: String?)
    case hunk(fileIndex: Int, hunkIndex: Int, header: String)
    case line(fileIndex: Int, hunkIndex: Int, line: DiffLine)
    case binary(fileIndex: Int, path: String)
}

/// A unified-diff parser (`git diff`, `diff -u`, `gh pr diff`).
///
/// Tool output is untrusted and can arrive truncated: the parser never throws,
/// keeps going through lines it does not understand, and treats a line that is not
/// hunk body as the end of the hunk.
public enum UnifiedDiff {

    // MARK: Parsing

    public static func parse(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var file: DiffFile?
        var hunk: DiffHunk?
        var oldCursor = 0
        var newCursor = 0
        var oldRemaining = 0
        var newRemaining = 0
        var sawOldHeader = false

        func closeHunk() {
            if let finished = hunk, file != nil {
                file?.hunks.append(finished)
            }
            hunk = nil
        }

        func closeFile() {
            closeHunk()
            if let finished = file { files.append(finished) }
            file = nil
            sawOldHeader = false
        }

        /// A hunk ends when its declared old/new line counts are used up — prefixes
        /// alone cannot tell a `--- ` header from a deleted line that begins `-- `.
        func finishIfExhausted() {
            if hunk != nil, oldRemaining <= 0, newRemaining <= 0 {
                closeHunk()
            }
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw

            if line.hasPrefix("diff --git ") {
                closeFile()
                let paths = parseGitHeaderPaths(String(line.dropFirst("diff --git ".count)))
                file = DiffFile(oldPath: paths.0, newPath: paths.1)
                sawOldHeader = false
                continue
            }

            if line.hasPrefix("@@") {
                if let parsed = parseHunkHeader(String(line)) {
                    closeHunk()
                    hunk = parsed
                    oldCursor = parsed.oldStart
                    newCursor = parsed.newStart
                    oldRemaining = parsed.oldCount
                    newRemaining = parsed.newCount
                }
                continue
            }

            if hunk != nil {
                guard var active = hunk else { continue }
                if line.isEmpty {
                    // A completely empty line inside a hunk: a context line whose
                    // trailing space git stripped.
                    active.lines.append(DiffLine(
                        kind: .context, text: "", oldNumber: oldCursor, newNumber: newCursor
                    ))
                    oldCursor += 1
                    newCursor += 1
                    oldRemaining -= 1
                    newRemaining -= 1
                    hunk = active
                    finishIfExhausted()
                    continue
                }

                switch line.first {
                case " ":
                    active.lines.append(DiffLine(
                        kind: .context,
                        text: String(line.dropFirst()),
                        oldNumber: oldCursor,
                        newNumber: newCursor
                    ))
                    oldCursor += 1
                    newCursor += 1
                    oldRemaining -= 1
                    newRemaining -= 1
                case "+":
                    active.lines.append(DiffLine(
                        kind: .addition,
                        text: String(line.dropFirst()),
                        oldNumber: nil,
                        newNumber: newCursor
                    ))
                    newCursor += 1
                    newRemaining -= 1
                case "-":
                    active.lines.append(DiffLine(
                        kind: .deletion,
                        text: String(line.dropFirst()),
                        oldNumber: oldCursor,
                        newNumber: nil
                    ))
                    oldCursor += 1
                    oldRemaining -= 1
                case "\\":
                    active.lines.append(DiffLine(
                        kind: .noNewline,
                        text: String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                    ))
                default:
                    closeHunk()
                    continue
                }
                hunk = active
                finishIfExhausted()
                continue
            }

            if line.hasPrefix("\\"), var finished = file, !finished.hunks.isEmpty {
                // `\ No newline at end of file` arriving after the hunk counts are
                // exhausted still belongs to that hunk.
                let last = finished.hunks.count - 1
                finished.hunks[last].lines.append(DiffLine(
                    kind: .noNewline,
                    text: String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                ))
                file = finished
                continue
            }

            if line.hasPrefix("--- ") {
                // A second `---` without a `diff --git` starts the next file of a
                // plain `diff -u` patch.
                if sawOldHeader { closeFile() }
                if file == nil { file = DiffFile() }
                file?.oldPath = parsePath(String(line.dropFirst(4)))
                sawOldHeader = true
                continue
            }

            if line.hasPrefix("+++ ") {
                if file == nil { file = DiffFile() }
                file?.newPath = parsePath(String(line.dropFirst(4)))
                continue
            }

            if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                if file == nil { file = DiffFile() }
                file?.isBinary = true
                continue
            }
        }

        closeFile()
        return files
    }

    /// Flat rows for a `List`, headers included.
    public static func rows(_ text: String) -> [DiffRow] {
        var rows: [DiffRow] = []
        for (fileIndex, file) in parse(text).enumerated() {
            rows.append(.file(index: fileIndex, oldPath: file.oldPath, newPath: file.newPath))
            if file.isBinary {
                rows.append(.binary(fileIndex: fileIndex, path: file.displayPath))
            }
            for (hunkIndex, hunk) in file.hunks.enumerated() {
                rows.append(.hunk(
                    fileIndex: fileIndex,
                    hunkIndex: hunkIndex,
                    header: header(for: hunk)
                ))
                for line in hunk.lines {
                    rows.append(.line(fileIndex: fileIndex, hunkIndex: hunkIndex, line: line))
                }
            }
        }
        return rows
    }

    /// `@@ -1,5 +1,6 @@ section` for a parsed hunk.
    public static func header(for hunk: DiffHunk) -> String {
        func side(_ sign: Character, start: Int, count: Int) -> String {
            count == 1 ? "\(sign)\(start)" : "\(sign)\(start),\(count)"
        }
        var header = "@@ \(side("-", start: hunk.oldStart, count: hunk.oldCount)) "
            + "\(side("+", start: hunk.newStart, count: hunk.newCount)) @@"
        if let section = hunk.section, !section.isEmpty { header += " \(section)" }
        return header
    }

    // MARK: Helpers

    private static func parsePath(_ raw: String) -> String? {
        var path = raw
        if let tab = path.firstIndex(of: "\t") { path = String(path[..<tab]) }
        path = path.trimmingCharacters(in: .whitespaces)
        if path == "/dev/null" || path.isEmpty { return nil }
        if path.hasPrefix("a/") || path.hasPrefix("b/") { path = String(path.dropFirst(2)) }
        if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 {
            path = String(path.dropFirst().dropLast())
        }
        return path
    }

    private static func parseGitHeaderPaths(_ raw: String) -> (String?, String?) {
        if raw.hasPrefix("\""), let split = raw.range(of: "\" \"") {
            return (
                parsePath(String(raw[..<split.lowerBound]) + "\""),
                parsePath("\"" + String(raw[split.upperBound...]))
            )
        }
        guard let split = raw.range(of: " b/") else {
            return (parsePath(raw), nil)
        }
        return (
            parsePath(String(raw[..<split.lowerBound])),
            parsePath("b/" + String(raw[split.upperBound...]))
        )
    }

    private static func parseHunkHeader(_ line: String) -> DiffHunk? {
        // @@ -old[,count] +new[,count] @@ section
        guard line.count > 2,
              let closing = line.range(of: "@@", range: line.index(line.startIndex, offsetBy: 2)..<line.endIndex)
        else { return nil }

        let rangesPart = line[line.index(line.startIndex, offsetBy: 2)..<closing.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        let section = line[closing.upperBound...].trimmingCharacters(in: .whitespaces)

        var oldStart = 0, oldCount = 1, newStart = 0, newCount = 1
        var sawOld = false, sawNew = false
        for token in rangesPart.split(separator: " ") {
            guard let sign = token.first, sign == "-" || sign == "+" else { continue }
            var body = token.dropFirst()
            var count = 1
            if let comma = body.firstIndex(of: ",") {
                count = Int(body[body.index(after: comma)...]) ?? 0
                body = body[..<comma]
            }
            guard let start = Int(body) else { return nil }
            if sign == "-" {
                oldStart = start
                oldCount = count
                sawOld = true
            } else {
                newStart = start
                newCount = count
                sawNew = true
            }
        }
        guard sawOld, sawNew else { return nil }
        return DiffHunk(
            oldStart: oldStart,
            oldCount: oldCount,
            newStart: newStart,
            newCount: newCount,
            section: section.isEmpty ? nil : String(section)
        )
    }
}
