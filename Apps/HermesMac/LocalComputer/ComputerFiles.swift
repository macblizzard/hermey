import Foundation

/// One shared workspace for every bot allowed to drive this Mac. File tools are confined to it;
/// shell commands remain full-access by owner decision.
enum ComputerFileError: LocalizedError {
    case outside
    case badPath
    case tooLarge
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .outside: return "Path escapes the Hermey workspace."
        case .badPath: return "Path must be a relative path inside the workspace."
        case .tooLarge: return "File exceeds the 4 MB workspace limit."
        case .missing(let path): return "No such file: \(path)."
        }
    }
}

final class ComputerFiles {
    static let shared = ComputerFiles()
    private let maxBytes = 4_000_000

    /// `~/Library/Application Support/Hermey/Computer/Workspace/`
    let root: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Hermey", isDirectory: true)
            .appendingPathComponent("Computer", isDirectory: true)
            .appendingPathComponent("Workspace", isDirectory: true)
        let url = base ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Hermey/Computer/Workspace")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private func safeURL(_ raw: String) throws -> URL {
        guard !raw.isEmpty, !raw.hasPrefix("/") else { throw ComputerFileError.badPath }
        let cleaned = raw.replacingOccurrences(of: "\\", with: "/")
        let url = root.appendingPathComponent(cleaned).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        // `standardizedFileURL` removes `..` lexically but happily follows a symlink the full-access
        // shell may have planted inside the workspace. Resolve it and re-check the root prefix.
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/") else {
            throw ComputerFileError.outside
        }
        return resolved
    }

    func perform(_ request: [String: Any]) throws -> [String: Any] {
        guard let op = request["op"] as? String else { throw ComputerFileError.badPath }
        let path = request["path"] as? String ?? ""
        let url = try safeURL(path)
        switch op {
        case "read":
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ComputerFileError.missing(path)
            }
            // Size-check before loading, so a huge file cannot spike memory just to be rejected.
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            guard size <= maxBytes else { throw ComputerFileError.tooLarge }
            let data = try Data(contentsOf: url)
            return ["op": "read", "path": path, "size": data.count,
                    "content_base64": data.base64EncodedString()]
        case "write":
            guard let encoded = request["content_base64"] as? String,
                  let data = Data(base64Encoded: encoded) else { throw ComputerFileError.badPath }
            guard data.count <= maxBytes else { throw ComputerFileError.tooLarge }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return ["op": "write", "path": path, "size": data.count]
        case "list":
            let entries = try FileManager.default.contentsOfDirectory(at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])
            let listed: [[String: Any]] = entries.compactMap { entry in
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                return ["name": entry.lastPathComponent,
                        "directory": values?.isDirectory ?? false,
                        "size": values?.fileSize ?? 0]
            }.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
            return ["op": "list", "path": path, "entries": listed]
        case "mkdir":
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return ["op": "mkdir", "path": path]
        default:
            throw ComputerFileError.badPath
        }
    }
}
