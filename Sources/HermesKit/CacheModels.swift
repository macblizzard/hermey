import Foundation

// MARK: - What the cache keeps

/// One of the three things the Caching screen can switch off.
///
/// The three are separate *directories*, not one bucket with a flag: switching one off is a delete
/// of exactly what it kept, and a cache with a section disabled must leave nothing behind for it on
/// disk. The raw values are the directory names — stable, because a cache written by one build is
/// read by the next.
public enum CacheSection: String, CaseIterable, Codable, Hashable, Sendable {
    /// The bot directory and each row's third line.
    case chatList = "chat-list"
    /// The transcript rows of chats this device has opened.
    case messages
    /// The images, files and links mentioned inside those rows.
    case filesAndLinks = "files-and-links"

    public var title: String {
        switch self {
        case .chatList: return "Chat List"
        case .messages: return "Messages"
        case .filesAndLinks: return "Files & Links"
        }
    }

    /// The one-line explanation under each switch. Both apps draw these exact words.
    public var explanation: String {
        switch self {
        case .chatList:
            return "Bot names, previews and times, so the list opens without waiting for the host."
        case .messages:
            return "Recent messages from chats you have opened, so a chat has something to show."
        case .filesAndLinks:
            return "Files and links mentioned in those messages, indexed for quick access."
        }
    }

    /// What the Usage row counts: "18 bots", "412 messages", "37 items".
    public var countNoun: String {
        switch self {
        case .chatList: return "bots"
        case .messages: return "messages"
        case .filesAndLinks: return "items"
        }
    }
}

/// What the Caching screen's switches and stepper store.
///
/// Defaults are all-on and 100 chats: caching is what makes the app usable on a train, so a fresh
/// install should have it, and 100 is the number the official screen calls "a good balance for
/// daily use". Persisted beside the cache (`settings.json`), not in `UserDefaults`: the copies must
/// never disagree with the files they govern, and resetting the cache must not reset the switches.
public struct CachePreferences: Codable, Equatable, Sendable {
    public var chatListEnabled: Bool
    public var messagesEnabled: Bool
    public var filesAndLinksEnabled: Bool
    public var chatLimit: Int

    public init(chatListEnabled: Bool = true,
                messagesEnabled: Bool = true,
                filesAndLinksEnabled: Bool = true,
                chatLimit: Int = HermesCacheStore.defaultChatLimit) {
        self.chatListEnabled = chatListEnabled
        self.messagesEnabled = messagesEnabled
        self.filesAndLinksEnabled = filesAndLinksEnabled
        self.chatLimit = chatLimit
    }

    public static let standard = CachePreferences()

    public func isEnabled(_ section: CacheSection) -> Bool {
        switch section {
        case .chatList: return chatListEnabled
        case .messages: return messagesEnabled
        case .filesAndLinks: return filesAndLinksEnabled
        }
    }

    public mutating func set(_ section: CacheSection, enabled: Bool) {
        switch section {
        case .chatList: chatListEnabled = enabled
        case .messages: messagesEnabled = enabled
        case .filesAndLinks: filesAndLinksEnabled = enabled
        }
    }

    /// Clamped into the stepper's range so a hand-edited file cannot make the cache unbounded.
    public mutating func clampLimit() {
        chatLimit = min(max(chatLimit, HermesCacheStore.chatLimitRange.lowerBound),
                        HermesCacheStore.chatLimitRange.upperBound)
    }

    // A settings file from a newer build may omit a key; decoding must fill in the default rather
    // than fail the whole document and silently switch caching off.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CachePreferences.standard
        chatListEnabled = try container.decodeIfPresent(Bool.self, forKey: .chatListEnabled) ?? defaults.chatListEnabled
        messagesEnabled = try container.decodeIfPresent(Bool.self, forKey: .messagesEnabled) ?? defaults.messagesEnabled
        filesAndLinksEnabled = try container.decodeIfPresent(Bool.self, forKey: .filesAndLinksEnabled) ?? defaults.filesAndLinksEnabled
        chatLimit = try container.decodeIfPresent(Int.self, forKey: .chatLimit) ?? defaults.chatLimit
        clampLimit()
    }
}

/// How much the cache actually occupies, measured from the files themselves.
///
/// Not an estimate: every number is a sum of real file sizes and a count of decoded rows, because
/// the whole point of the Usage section is that it answers "what will I get back if I reset this".
public struct CacheUsage: Equatable, Sendable {
    public struct SectionUse: Equatable, Sendable {
        public let bytes: Int
        public let count: Int

        public init(bytes: Int = 0, count: Int = 0) {
            self.bytes = max(0, bytes)
            self.count = max(0, count)
        }

        public static let zero = SectionUse()
    }

    public let sections: [CacheSection: SectionUse]
    /// Chats with at least one cached file — what the Limit stepper governs.
    public let chatCount: Int

    public init(sections: [CacheSection: SectionUse] = [:], chatCount: Int = 0) {
        self.sections = sections
        self.chatCount = max(0, chatCount)
    }

    public static let empty = CacheUsage(
        sections: Dictionary(uniqueKeysWithValues: CacheSection.allCases.map { ($0, SectionUse.zero) }),
        chatCount: 0)

    public var totalBytes: Int {
        sections.values.reduce(0) { $0 + $1.bytes }
    }

    public func use(_ section: CacheSection) -> SectionUse {
        sections[section] ?? .zero
    }

    public func bytes(_ section: CacheSection) -> Int {
        use(section).bytes
    }

    public func count(_ section: CacheSection) -> Int {
        use(section).count
    }
}

/// The cache's own byte and count formatting, so the Mac tab and the phone screen cannot disagree
/// about what "1.2 MB" means. Decimal units, the same convention as the system's storage screen.
public enum CacheFormat {
    public static func size(_ bytes: Int) -> String {
        let value = max(0, bytes)
        if value < 1_000 { return "\(value) B" }
        let kilobytes = Double(value) / 1_000
        if kilobytes < 1_000 { return String(format: "%.0f KB", kilobytes) }
        let megabytes = kilobytes / 1_000
        if megabytes < 10 { return String(format: "%.1f MB", megabytes) }
        if megabytes < 1_000 { return String(format: "%.0f MB", megabytes) }
        return String(format: "%.1f GB", megabytes / 1_000)
    }

    public static func count(_ value: Int, _ section: CacheSection) -> String {
        let noun = section.countNoun
        // "1 messages" is the kind of line that makes a screen feel unfinished.
        let word = (value == 1) ? String(noun.dropLast()) : noun
        return "\(value) \(word)"
    }
}

// MARK: - Stored shapes

/// A bot as the list needs it, without the `Bot` type's non-`Codable` construction rules.
public struct CachedBot: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var displayName: String
    public var label: String
    public var avatarInitials: String
    public var description: String?

    public init(bot: Bot) {
        id = bot.id
        name = bot.name
        displayName = bot.displayName
        label = bot.label
        avatarInitials = bot.avatarInitials
        description = bot.description
    }

    public var bot: Bot {
        Bot(id: id, name: name, displayName: displayName, label: label,
            avatarInitials: avatarInitials, description: description)
    }
}

/// A bot row's third line, as the bridge reported it.
public struct CachedPreview: Codable, Hashable, Sendable {
    public var text: String
    public var role: String
    public var timestamp: Double?

    public init(text: String, role: String = "assistant", timestamp: Double? = nil) {
        self.text = text
        self.role = role
        self.timestamp = timestamp
    }

    public init(_ preview: BotConversationPreview) {
        text = preview.text
        role = preview.role
        timestamp = preview.timestamp
    }
}

/// The Chat List section: who the bots are and what their rows said the last time the host answered.
public struct CachedChatList: Codable, Sendable {
    public static let currentSchema = 1

    public var schema: Int
    public var savedAt: Double
    public var bots: [CachedBot]
    public var previews: [String: CachedPreview]
    /// Unread counts are stored so the document is a faithful snapshot, but they are **never**
    /// painted from the cache: a badge is a claim about right now, and a stale one is a lie the user
    /// reads as "something arrived".
    public var unread: [String: Int]

    public init(schema: Int = CachedChatList.currentSchema,
                savedAt: Double = 0,
                bots: [CachedBot] = [],
                previews: [String: CachedPreview] = [:],
                unread: [String: Int] = [:]) {
        self.schema = schema
        self.savedAt = savedAt
        self.bots = bots
        self.previews = previews
        self.unread = unread
    }
}

/// One tool row's detail, flattened for storage (`ToolDetail` is not `Codable`).
public struct CachedTool: Codable, Hashable, Sendable {
    public var name: String
    public var context: String?
    public var args: String?
    public var content: String?
    public var labels: [String]

    public init(_ detail: TranscriptEntry.ToolDetail) {
        name = detail.name
        context = detail.context
        args = detail.args
        content = detail.content
        labels = detail.labels
    }

    public var detail: TranscriptEntry.ToolDetail {
        TranscriptEntry.ToolDetail(name: name, context: context, args: args,
                                   content: content, labels: labels)
    }
}

/// One cached transcript row. Attachments' bytes are deliberately absent: the pictures already
/// have their own store (`AttachmentImageStore`) and duplicating them here would double the cache
/// for no benefit.
public struct CachedMessage: Codable, Hashable, Sendable {
    public var id: String
    public var rowID: Int64?
    public var role: String
    public var text: String
    public var at: Double?
    public var tool: CachedTool?

    public init(_ entry: TranscriptEntry) {
        id = entry.id
        rowID = entry.rowID
        role = entry.role.rawValue
        text = entry.text
        // Host timestamps are epoch seconds; milliseconds are normalised so a relaunch does not
        // suddenly place a message in the year 57000.
        at = entry.at.map { $0.timeIntervalSince1970 }
        tool = entry.tool.map(CachedTool.init)
    }

    public var entry: TranscriptEntry {
        TranscriptEntry(id: id,
                        rowID: rowID,
                        role: TranscriptEntry.Role(rawValue: role) ?? .system,
                        text: text,
                        at: at.map { Date(timeIntervalSince1970: $0) },
                        tool: tool?.detail,
                        attachments: [])
    }
}

/// The Messages section for one chat.
public struct CachedTranscript: Codable, Sendable {
    public static let currentSchema = 1

    public var schema: Int
    public var chatID: String
    public var savedAt: Double
    /// Where older rows continue from, when the host gave one and the rows were not truncated.
    public var cursor: Int?
    public var total: Int
    public var entries: [CachedMessage]

    public init(schema: Int = CachedTranscript.currentSchema,
                chatID: String,
                savedAt: Double = 0,
                cursor: Int? = nil,
                total: Int = 0,
                entries: [CachedMessage] = []) {
        self.schema = schema
        self.chatID = chatID
        self.savedAt = savedAt
        self.cursor = cursor
        self.total = total
        self.entries = entries
    }

    public var messages: [TranscriptEntry] {
        entries.map(\.entry)
    }
}

/// What an attachment/link index row is.
public enum CachedLinkKind: String, Codable, Hashable, Sendable {
    case image
    case file
    case link
}

/// One file, picture or URL found in a chat's cached messages.
public struct CachedLink: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: CachedLinkKind
    /// The host path for a file/image, the absolute URL for a link.
    public var target: String
    /// What a row shows: a file name, or a link's host.
    public var name: String
    /// The message the reference appeared in, so an attachment can be re-attached to its row.
    public var messageID: String
    public var at: Double?

    public init(id: String, kind: CachedLinkKind, target: String,
                name: String, messageID: String, at: Double?) {
        self.id = id
        self.kind = kind
        self.target = target
        self.name = name
        self.messageID = messageID
        self.at = at
    }

    /// The chip a cached transcript row should draw for this item, when the vault has no bytes.
    public var attachment: SentAttachment {
        SentAttachment(id: id, name: name, isImage: kind == .image, imageData: nil)
    }
}

/// The Files & Links section for one chat: the index built from the rows as they were cached.
public struct CachedLinkIndex: Codable, Sendable {
    public static let currentSchema = 1

    public var schema: Int
    public var chatID: String
    public var savedAt: Double
    public var items: [CachedLink]

    public init(schema: Int = CachedLinkIndex.currentSchema,
                chatID: String,
                savedAt: Double = 0,
                items: [CachedLink] = []) {
        self.schema = schema
        self.chatID = chatID
        self.savedAt = savedAt
        self.items = items
    }

    /// Build the index from transcript rows. Only user and assistant text is scanned: a tool card
    /// quotes commands and paths that were never attachments.
    public static func build(chatID: String, entries: [TranscriptEntry], at: Date = Date()) -> CachedLinkIndex {
        var items: [CachedLink] = []
        var seen = Set<String>()
        for entry in entries where entry.role == .user || entry.role == .assistant {
            for item in CacheLinkScanner.links(in: entry) where seen.insert(item.id).inserted {
                items.append(item)
            }
        }
        return CachedLinkIndex(chatID: chatID,
                               savedAt: at.timeIntervalSince1970,
                               items: items)
    }

    /// Fill in attachment chips for cached rows that have none, so an image or file reference is
    /// still a named chip when the vault has no bytes. Links are not attachments and are skipped.
    public func attachMissing(to entries: [TranscriptEntry]) -> [TranscriptEntry] {
        guard !items.isEmpty else { return entries }
        var byMessage: [String: [CachedLink]] = [:]
        for item in items where item.kind == .image || item.kind == .file {
            byMessage[item.messageID, default: []].append(item)
        }
        guard !byMessage.isEmpty else { return entries }
        return entries.map { entry in
            guard entry.attachments.isEmpty, let rows = byMessage[entry.id], !rows.isEmpty else {
                return entry
            }
            var copy = entry
            copy.attachments = rows.map(\.attachment)
            return copy
        }
    }
}

/// Finds the references the host stores inside a message.
///
/// The marker strings match `MessageRefs`' own; that type splits a stored message for display and
/// throws the marker away, which is exactly the bit the index needs (an image and a file are drawn
/// differently), so the scan lives here rather than duplicating a display concern there.
enum CacheLinkScanner {
    private static let markers: [(String, CachedLinkKind)] = [
        ("@image:", .image),
        ("@file:", .file),
    ]

    static func links(in entry: TranscriptEntry) -> [CachedLink] {
        var items: [CachedLink] = []
        var body: [String] = []
        for line in entry.text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = markers.first(where: { trimmed.hasPrefix($0.0) }) {
                let target = String(trimmed.dropFirst(marker.0.count))
                    .trimmingCharacters(in: .whitespaces)
                guard !target.isEmpty else { continue }
                let name = (target as NSString).lastPathComponent
                items.append(CachedLink(id: "\(entry.id)|\(marker.1.rawValue)|\(target)",
                                        kind: marker.1,
                                        target: target,
                                        name: name.isEmpty ? target : name,
                                        messageID: entry.id,
                                        at: entry.at?.timeIntervalSince1970))
            } else {
                body.append(String(line))
            }
        }

        for target in urls(in: body.joined(separator: "\n")) {
            let host = URL(string: target)?.host ?? target
            items.append(CachedLink(id: "\(entry.id)|link|\(target)",
                                    kind: .link,
                                    target: target,
                                    name: host,
                                    messageID: entry.id,
                                    at: entry.at?.timeIntervalSince1970))
        }
        return items
    }

    /// Plain `http(s)` scanning rather than `NSDataDetector`: the detector is not available
    /// everywhere this module builds, and the app only needs to know a URL is there.
    static func urls(in text: String) -> [String] {
        var found: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            // Both schemes are searched for, and the earlier one wins: a message that links to
            // `https://…` before any `http://…` must not index the second link first.
            let rest = text[index...]
            let plain = rest.range(of: "http://")?.lowerBound
            let secure = rest.range(of: "https://")?.lowerBound
            let start: String.Index
            if let plain, let secure {
                start = min(plain, secure)
            } else if let plain {
                start = plain
            } else if let secure {
                start = secure
            } else {
                break
            }
            var end = start
            while end < text.endIndex {
                let character = text[end]
                if character.isWhitespace || ")]}>\"'<|*".contains(character) { break }
                end = text.index(after: end)
            }
            let candidate = String(text[start..<end])
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            if !candidate.isEmpty { found.append(candidate) }
            index = end > start ? end : text.index(after: start)
        }
        return found
    }
}
