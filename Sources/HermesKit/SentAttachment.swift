import Foundation

/// One file that travelled with a message the user sent.
///
/// The host keeps no record of an image's bytes that a phone can read back: `file.attach` queues
/// the picture for the next turn and returns no reference at all, so the stored transcript knows a
/// turn happened and nothing about what was in it. The bubble therefore has to remember its own
/// attachments, and this type is that memory — kept beside the entry and, so a relaunch does not
/// erase every picture from the chat, in a small on-disk vault.
public struct SentAttachment: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let isImage: Bool
    /// Only for images: what the bubble draws. Never sent anywhere — the upload already happened.
    public let imageData: Data?

    public init(id: String = UUID().uuidString, name: String, isImage: Bool, imageData: Data? = nil) {
        self.id = id
        self.name = name
        self.isImage = isImage
        self.imageData = imageData
    }
}

/// The on-disk record of what went with which message.
///
/// Matching is by the bubble's own text, consumed oldest-first: the host stores the prompt it
/// received (a typed line, or the joined names for an attachment-only send), so that text is the
/// one thing both sides agree on. It is a heuristic, and it fails in exactly one way — two
/// messages with identical text on the same bot — which is worth a picture in the right place
/// most of the time rather than no pictures at all.
public enum SentAttachmentVault {

    private struct Record: Codable {
        var text: String
        var at: Double
        var items: [Item]
    }

    private struct Item: Codable {
        var id: String
        var name: String
        var isImage: Bool
        /// File name inside the vault directory, for images only.
        var file: String?
    }

    private static let folder = "sent-attachments"

    // MARK: Writing

    public static func record(sessionID: String, text: String, attachments: [SentAttachment]) {
        guard !attachments.isEmpty, let directory = directory() else { return }
        var items: [Item] = []
        for attachment in attachments {
            var file: String?
            if let data = attachment.imageData {
                let name = "\(attachment.id).bin"
                if (try? data.write(to: directory.appendingPathComponent(name))) != nil { file = name }
            }
            items.append(Item(id: attachment.id, name: attachment.name,
                              isImage: attachment.isImage, file: file))
        }
        var records = read(sessionID: sessionID)
        records.append(Record(text: MessageRefs.display(text), at: Date().timeIntervalSince1970,
                              items: items))
        // A chat that has sent a thousand files does not need a thousand rows of bookkeeping — and
        // the rows are not the expensive part: every trimmed row owned a file on disk that nothing
        // would ever read again. Deleting with the record is what keeps this a cache.
        if records.count > 200 {
            let dropped = records.prefix(records.count - 200)
            for record in dropped {
                for item in record.items {
                    if let file = item.file {
                        try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
                    }
                }
            }
            records.removeFirst(records.count - 200)
        }
        write(records, sessionID: sessionID)
    }

    // MARK: Reading

    /// Attaches the stored pictures to the user rows they belong to, oldest record to oldest row.
    public static func decorate(_ entries: [TranscriptEntry], sessionID: String) -> [TranscriptEntry] {
        let records = read(sessionID: sessionID)
        guard !records.isEmpty else { return entries }

        var used = Set<Int>()
        var result = entries
        for index in result.indices where result[index].role == .user {
            guard result[index].attachments.isEmpty else { continue }
            // Compare what the user wrote. The stored text carries the host's `@image:` lines
            // after an upload, so a raw comparison never matches the bubble it belongs to.
            let text = result[index].displayText
            if let match = records.indices.first(where: { !used.contains($0) && records[$0].text == text }) {
                used.insert(match)
                result[index].attachments = load(records[match])
                continue
            }
            // An attachment with no words leaves an empty sentence after the references are
            // stripped, while the record remembers the joined file names. Both sides are in send
            // order, so the next unclaimed record is that row's.
            if text.isEmpty,
               let match = records.indices.first(where: { !used.contains($0) && !records[$0].text.isEmpty }) {
                used.insert(match)
                result[index].attachments = load(records[match])
            }
        }
        return result
    }

    private static func load(_ record: Record) -> [SentAttachment] {
        let directory = directory()
        return record.items.map { item in
            var data: Data?
            if let file = item.file, let directory {
                data = try? Data(contentsOf: directory.appendingPathComponent(file))
            }
            return SentAttachment(id: item.id, name: item.name, isImage: item.isImage, imageData: data)
        }
    }

    // MARK: Plumbing

    private static func directory() -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let directory = caches.appendingPathComponent(folder, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private static func url(sessionID: String) -> URL? {
        guard let directory = directory() else { return nil }
        // Session ids are hex-ish, but a name is never allowed to walk out of the directory.
        let safe = sessionID.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(safe).json")
    }

    private static func read(sessionID: String) -> [Record] {
        guard let url = url(sessionID: sessionID),
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([Record].self, from: data)
        else { return [] }
        return records
    }

    private static func write(_ records: [Record], sessionID: String) {
        guard let url = url(sessionID: sessionID), let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

public extension TranscriptEntry {
    /// What the bubble can draw for a stored user message: the host's `@image:`/`@file:` references,
    /// with a picture attached when this device still holds those bytes.
    ///
    /// This is the reliable path back from a relaunch. The vault matches a send to its row by the
    /// sentence the user typed, which is a heuristic; the reference names the exact file the host
    /// stored, and the image store is keyed by that same name.
    var referenceAttachments: [SentAttachment] {
        guard role == .user, attachments.isEmpty else { return [] }
        return MessageRefs.split(text).refs.map { path in
            let name = (path as NSString).lastPathComponent
            let isImage = Self.imageExtensions.contains((name as NSString).pathExtension.lowercased())
            return SentAttachment(id: path,
                                  name: name.isEmpty ? path : name,
                                  isImage: isImage,
                                  imageData: isImage ? AttachmentImageStore.data(named: name) : nil)
        }
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif",
                                                       "webp", "tiff", "bmp"]
}
