import Foundation

/// The pictures this device has sent, kept under the host's own file name.
///
/// Matching a sent photo to its bubble by the message's text was a guess: the host stores the
/// upload as an `@image:/…/upload_ab12.png` reference inside the user row, so a picture could only
/// come back if the sentence still matched exactly — and after a relaunch it often did not. The
/// attach reply already tells us the path the host gave the file, and that same path is what the
/// transcript quotes back. Keying the bytes by that name turns the guess into a join.
public enum AttachmentImageStore {

    private static let folder = "attachment-images"
    /// Enough for a long conversation's worth of pictures, small enough to stay a cache.
    private static let keep = 240

    /// Records the bytes under the name the host will quote in the transcript.
    public static func save(_ data: Data, as name: String) {
        guard let directory = directory(), let file = file(named: name, in: directory) else { return }
        try? data.write(to: file, options: .atomic)
        prune(in: directory)
    }

    public static func data(named name: String) -> Data? {
        guard let directory = directory(), let file = file(named: name, in: directory) else { return nil }
        return try? Data(contentsOf: file)
    }

    // MARK: Plumbing

    /// Only the last path component is used: the host's path is meaningless on the phone, and a
    /// name is never allowed to walk out of the cache directory.
    private static func file(named name: String, in directory: URL) -> URL? {
        let last = (name as NSString).lastPathComponent
        let safe = last.replacingOccurrences(of: "/", with: "_")
        guard !safe.isEmpty, safe != ".", safe != ".." else { return nil }
        return directory.appendingPathComponent(safe)
    }

    private static func directory() -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let directory = caches.appendingPathComponent(folder, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    /// Oldest first. A cache that grows without bound is a bug the user pays for in storage.
    private static func prune(in directory: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                      includingPropertiesForKeys: keys)
        else { return }
        guard files.count > keep else { return }
        let ordered = files.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return left < right
        }
        for file in ordered.prefix(files.count - keep) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
