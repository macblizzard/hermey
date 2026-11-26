import Foundation

/// A pet's chat, on disk, keyed by bot id.
///
/// Closing the balloon is not a reset, and neither is quitting the app: the thread comes back with
/// its history. The design's first version said a desktop pet's transcript "is not a document" and
/// kept it in memory only; the owner then asked for a chat that survives closing, which makes it one
/// — a small one, next to the app's other local caches, not a second transcript store.
///
/// Layout, under `Application Support/Hermey/PetChat/`:
///
/// ```
/// <bot-slug>-<fingerprint>.json   one bot's conversation, `{version, bot, messages}`
/// ```
///
/// The file name is a readable slug plus the same 64-bit FNV-1a fingerprint `CacheKey` uses, so a
/// bot id can never walk out of the directory and two ids that slug the same still land apart. Every
/// write is atomic; a file that will not decode is a miss and is deleted, never repaired or trusted.
///
/// One file per bot per Mac, not per host: a pet is a local decoration of *this* desk, and the bot
/// ids it decorates are already unique to the paired host they came from.
public struct PetConversationStore {
    public static let folderName = "PetChat"
    /// Bumped only when the document's shape changes; an older version is read as a miss.
    public static let version = 1

    public let botID: String
    public let fileURL: URL

    private let fileManager: FileManager

    public init(botID: String, root: URL? = nil, fileManager: FileManager = .default) {
        self.botID = botID
        self.fileManager = fileManager
        self.fileURL = (root ?? Self.defaultRoot(fileManager: fileManager))
            .appendingPathComponent(Self.fileName(for: botID) + ".json", isDirectory: false)
    }

    /// `Application Support/Hermey/PetChat` — beside the transcript cache, and in Application
    /// Support rather than Caches because the system may purge Caches whenever it likes and this is
    /// a conversation the owner expects to still be there.
    public static func defaultRoot(fileManager: FileManager = .default) -> URL {
        let support = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("Hermey", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// What is on disk, or an empty conversation. Never throws: a missing or corrupt file is a pet
    /// that has not been spoken to yet, which is not a failure anyone can act on.
    public func load() -> PetConversation {
        guard let data = try? Data(contentsOf: fileURL) else { return PetConversation() }
        guard let document = try? JSONDecoder().decode(Document.self, from: data),
              document.version == Self.version
        else {
            try? fileManager.removeItem(at: fileURL)
            return PetConversation()
        }
        return PetConversation(messages: document.messages)
    }

    /// Write the thread. An empty conversation removes the file rather than storing `[]`: `New` is a
    /// clear, and a clear that leaves the old rows on disk is not one.
    public func save(_ conversation: PetConversation) {
        guard !conversation.isEmpty else {
            clear()
            return
        }
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let document = Document(version: Self.version, bot: botID,
                                    messages: conversation.messages)
            try encoder.encode(document).write(to: fileURL, options: .atomic)
        } catch {
            // A pet that cannot write its little chat still has the one in memory; nothing here is
            // worth interrupting a conversation for.
        }
    }

    public func clear() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try? fileManager.removeItem(at: fileURL)
    }

    // MARK: - Naming

    /// The on-disk name for one bot: a readable slug, then a fingerprint so two ids that slug the
    /// same cannot collide. Same shape as `CacheKey.fileName(for:)`, and deliberately its own copy:
    /// the cache's key is internal to that actor's story, and this file's name must not change when
    /// that one does.
    public static func fileName(for botID: String) -> String {
        var slug = ""
        for scalar in botID.unicodeScalars {
            switch scalar.value {
            case 48 ... 57, 65 ... 90, 97 ... 122: // 0-9 A-Z a-z
                slug.unicodeScalars.append(scalar)
            case 45, 95: // - _
                slug.append("-")
            default:
                slug.append("-")
            }
        }
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "pet" }
        if slug.count > 48 {
            slug = String(slug.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        return "\(slug)-\(fingerprint(botID))"
    }

    /// FNV-1a, 64-bit. Not a security hash: it only has to be stable, and to separate two ids that
    /// slug to the same readable name.
    static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// The document on disk. A version field rather than a bare array: the day a message grows a
    /// field, the old file can be recognised instead of half-decoded.
    private struct Document: Codable {
        var version: Int
        var bot: String
        var messages: [PetMessage]
    }
}
