import Foundation

/// One file a stored message refers to, with the prose around it left alone.
///
/// The host stores an attachment as a *path*, never as bytes: a photo from the phone lands in
/// `…/profiles/<profile>/images/upload_<slug>.<ext>` and the message carries
/// `@image:<that path>`; a document arrives as `@file:<path>` inside the engine's
/// `📎 … — Attached Context —` block. The device that uploaded it holds the bytes and every other
/// device holds this string — which is why there is one parser here, shared by both shells, and not
/// one per platform.
///
/// The three shapes the host writes, all of which map to this one struct:
///
/// ```text
/// @image:/root/.hermes/profiles/cody/images/upload_1v5jm9lm.jpg
/// @file:.hermes/profiles/cody/attachments/MICs.xlsx
/// 📎 @file:.hermes/profiles/cody/attachments/MICs.xlsx (application/vnd…sheet, 20.8 KB) — binary…
/// ```
public struct MessageAttachment: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case image
        case file
    }

    /// The reference itself, which is also the cache key: one file referenced twice (the
    /// `@file:` line and the `📎` block naming the same path) is one attachment.
    public let id: String
    public let kind: Kind
    /// The path exactly as stored, wrappers off — host-absolute for `@image:`, and either form for
    /// `@file:`. Resolved by the host route, which owns the scope rules.
    public let path: String
    /// The last path component, which is what a row shows and what the on-disk cache is keyed by.
    public let name: String
    /// From the `📎` block, when the message carried one. The plain `@file:` line has neither.
    public let mimeType: String?
    /// Bytes, likewise from the `📎` block's `(…, 20.8 KB)`. `nil` shows the type's word instead of
    /// a made-up size.
    public let size: Int?

    public init(id: String, kind: Kind, path: String, name: String,
                mimeType: String? = nil, size: Int? = nil) {
        self.id = id
        self.kind = kind
        self.path = path
        self.name = name
        self.mimeType = mimeType
        self.size = size
    }

    public var isImage: Bool { kind == .image }
    public var kindOfFile: AttachmentKind { AttachmentKind(name: name) }
}

/// A message body as drawing needs it: the words, and the files they came with.
public struct MessageAttachmentScan: Sendable, Equatable {
    public let body: String
    public let attachments: [MessageAttachment]

    public init(body: String, attachments: [MessageAttachment]) {
        self.body = body
        self.attachments = attachments
    }
}

extension MessageRefs {

    /// The `--- Attached Context ---` heading the engine writes before its `📎` block.
    static let contextHeading = "--- Attached Context ---"
    /// The block's own mark. Everything from here on is host bookkeeping.
    static let pin = "📎"

    /// Splits a stored message into the words to draw and the attachments it names.
    ///
    /// The rules, and why each one is what it is:
    ///
    ///   * a reference is a **line** that starts with `@image:` or `@file:` — the host appends one
    ///     per file after the typed words, and a `@file:` mentioned mid-sentence stays prose
    ///     (a mention is not an upload);
    ///   * the path is everything after the marker, up to whitespace, with the punctuation a
    ///     sentence would put after it trimmed — and in backticks or quotes when the name holds a
    ///     space, which is the engine's own wrapping (`office.rs::file_refs` reads it the same way);
    ///   * the `📎` block starts at its heading (or at the `📎` line, if the heading is missing) and
    ///     runs to the end: it *repeats* the reference with its mime type and size, so it is merged
    ///     into the attachment the line above already named rather than becoming a second one;
    ///   * everything else is kept verbatim, in order, so the bubble still reads as what was typed.
    public static func attachments(in text: String) -> MessageAttachmentScan {
        var body: [String] = []
        var found: [MessageAttachment] = []
        var inContextBlock = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == contextHeading || trimmed.hasPrefix(contextHeading) {
                inContextBlock = true
                continue
            }
            if inContextBlock {
                if trimmed.hasPrefix(pin) { merge(pinReference(trimmed), into: &found) }
                continue
            }
            if trimmed.hasPrefix(pin) {
                merge(pinReference(trimmed), into: &found)
                continue
            }
            if let reference = reference(fromLine: trimmed) {
                merge(reference, into: &found)
                continue
            }
            body.append(line)
        }

        let joined = body.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return MessageAttachmentScan(body: joined, attachments: found)
    }

    // MARK: Shapes

    /// `@image:<path>` or `@file:<path>` starting the line.
    private static func reference(fromLine line: String) -> MessageAttachment? {
        for marker in markers {
            guard line.hasPrefix(marker) else { continue }
            let rest = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            guard let path = target(rest), !path.isEmpty else { return nil }
            return attachment(path: path, marker: marker)
        }
        return nil
    }

    /// The `📎 @file:<path> (mime, size) — …` line of an Attached Context block.
    private static func pinReference(_ line: String) -> MessageAttachment? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let markerRange = markers.compactMap({ marker in
            trimmed.range(of: marker).map { (marker, $0) }
        }).min(by: { $0.1.lowerBound < $1.1.lowerBound }) else { return nil }
        let (marker, range) = markerRange
        let rest = String(trimmed[range.upperBound...])
        guard let path = target(rest), !path.isEmpty else { return nil }

        // The type and size are in the parentheses that follow the path, when they are there at
        // all: `(application/vnd…sheet, 20.8 KB)`.
        var mimeType: String?
        var size: Int?
        if let open = rest.range(of: "("), let close = rest.range(of: ")", range: open.upperBound..<rest.endIndex) {
            let inside = String(rest[open.upperBound..<close.lowerBound])
            let parts = inside.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                mimeType = parts[0].isEmpty ? nil : parts[0]
                size = bytes(from: parts[1])
            } else if let single = parts.first, !single.isEmpty, single.contains("/") {
                mimeType = single
            }
        }
        return attachment(path: path, marker: marker, mimeType: mimeType, size: size)
    }

    private static func attachment(path: String, marker: String,
                                   mimeType: String? = nil, size: Int? = nil) -> MessageAttachment {
        let name = (path as NSString).lastPathComponent
        let displayName = name.isEmpty ? path : name
        // The marker wins over the extension: `@image:` is the engine saying it is a picture, even
        // if the upload kept an extension this app does not know. A `@file:` of a `.jpg` is still a
        // picture, because that is what a bubble can draw.
        let isImage = marker == "@image:" || AttachmentKind(name: displayName).isImage
        return MessageAttachment(id: path,
                                 kind: isImage ? .image : .file,
                                 path: path,
                                 name: displayName,
                                 mimeType: mimeType,
                                 size: size)
    }

    /// The path after a marker: backtick/quote wrapped when the name holds a space, otherwise up to
    /// whitespace with a sentence's punctuation trimmed. Mirrors `office.rs::file_refs`.
    private static func target(_ rest: String) -> String? {
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard let first = text.first else { return nil }
        if first == "`" || first == "\"" || first == "'" {
            let inner = String(text.dropFirst())
            if let close = inner.firstIndex(of: first) {
                return String(inner[..<close]).trimmingCharacters(in: .whitespaces)
            }
            return inner.trimmingCharacters(in: .whitespaces)
        }
        let end = text.firstIndex(where: { $0.isWhitespace }) ?? text.endIndex
        var bare = String(text[..<end])
        let trailing: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}"]
        while let last = bare.last, trailing.contains(last) { bare.removeLast() }
        return bare
    }

    /// One attachment per path. The `📎` block is the richer spelling of a reference the line above
    /// already gave, so the later copy *fills in* the type and size instead of adding a second row.
    private static func merge(_ reference: MessageAttachment?, into list: inout [MessageAttachment]) {
        guard let reference else { return }
        if let index = list.firstIndex(where: { $0.id == reference.id }) {
            let existing = list[index]
            list[index] = MessageAttachment(id: existing.id,
                                            kind: existing.kind,
                                            path: existing.path,
                                            name: existing.name,
                                            mimeType: existing.mimeType ?? reference.mimeType,
                                            size: existing.size ?? reference.size)
            return
        }
        list.append(reference)
    }

    /// `20.8 KB` → bytes. The engine humanises with `1000`s (`KB`, `MB`); `KiB` and friends are
    /// read with `1024`s because a name that says `KiB` means it.
    static func bytes(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(digits) else { return nil }
        let unit = trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespaces).uppercased()
        let binary = unit.hasSuffix("IB")
        let scale: Double
        switch unit.replacingOccurrences(of: "IB", with: "B") {
        case "B", "": scale = 1
        case "KB": scale = binary ? 1024 : 1000
        case "MB": scale = binary ? 1024 * 1024 : 1000 * 1000
        case "GB": scale = binary ? 1024 * 1024 * 1024 : 1_000_000_000
        case "TB": scale = binary ? 1024.0 * 1024 * 1024 * 1024 : 1_000_000_000_000
        default: return nil
        }
        let bytes = value * scale
        return bytes > 0 && bytes < Double(Int.max) ? Int(bytes.rounded()) : nil
    }
}

/// The bytes of a reference, kept in memory under the reference string.
///
/// Two rows that name the same photo, and every re-render of the row that holds it, must not become
/// two fetches or two disk reads: the transcript repaints on every body pass, and a streaming turn
/// makes twenty-five passes a second. Least-recently-used, sixty-four entries — a long conversation
/// with a picture in every message still fits, and the bound is what keeps it a cache instead of a
/// leak. `AttachmentImageStore` stays the disk half (240 files, pruned oldest-first), so a relaunch
/// draws what this device has already seen without asking the host.
public enum AttachmentByteCache {

    /// Entries held at once. Big enough for a screenful of conversations, small enough to forget.
    public static let capacity = 64

    private static let lock = NSLock()
    private static var entries: [String: Data] = [:]
    /// Oldest first; the first element is what an eviction takes.
    private static var order: [String] = []

    public static func data(for reference: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = entries[reference] else { return nil }
        touch(reference)
        return data
    }

    public static func contains(_ reference: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[reference] != nil
    }

    public static func store(_ data: Data, for reference: String) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        entries[reference] = data
        touch(reference)
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    /// How many references are held — for tests, and for a log line that must not lie about it.
    public static var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// The order they would be evicted in, oldest first. Exposed so the eviction rule is a tested
    /// fact rather than a comment.
    public static var recency: [String] {
        lock.lock()
        defer { lock.unlock() }
        return order
    }

    public static func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        order.removeAll()
    }

    private static func touch(_ reference: String) {
        if let index = order.firstIndex(of: reference) {
            order.remove(at: index)
        }
        order.append(reference)
    }
}

/// Resolve one attachment's bytes, in the order that costs the least.
///
///  1. the in-memory cache, keyed by the reference;
///  2. the on-disk cache, keyed by the file name the host chose (survives a relaunch, works
///     offline once the picture has been seen);
///  3. the host, through the route the app already uses for a file it opens — the caller supplies
///     it, because the model that holds the device bearer belongs to the app.
///
/// Whatever arrives is written to both caches, so the next render is a memory read.
public enum AttachmentReferenceReader {

    public static func bytes(for attachment: MessageAttachment,
                             profile: String,
                             fetch: (AttachmentLocation) async throws -> URL) async throws -> Data {
        if let hit = AttachmentByteCache.data(for: attachment.id) { return hit }
        if let disk = AttachmentImageStore.data(named: attachment.name) {
            AttachmentByteCache.store(disk, for: attachment.id)
            return disk
        }
        let url = try await fetch(.reference(profile: profile, path: attachment.path))
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw AttachmentFetchError.cacheUnavailable
        }
        AttachmentByteCache.store(data, for: attachment.id)
        // The disk half is the existing cache, so a relaunch and an offline open both work without
        // a second store to keep honest.
        AttachmentImageStore.save(data, as: attachment.name)
        return data
    }
}
