import Foundation

/// The device's copy of what the host already told it.
///
/// Three promises, and each one is why this is a real store rather than a dictionary:
///
/// * **The host is the authority.** Nothing here is ever presented as newer than the host's own
///   answer. Writes happen *after* a successful host reply; reads happen when the host could not
///   answer, or to fill a row the host has not covered yet. A cache that outlived its usefulness
///   is a bug report, not a feature.
/// * **Per host.** Two paired hosts mean two directories. A transcript cached from one host must
///   never be painted under the other's bot with the same name.
/// * **Bounded by chats.** The Limit stepper governs how many conversations are kept: the least
///   recently used chat (read or written) is dropped when a new one would exceed the limit, taking
///   its messages and its files/links index with it. Nothing is left behind for a switch that is
///   off.
///
/// Storage layout, under `Application Support/Hermey/Cache/hosts/<host-key>/`:
///
/// ```
/// settings.json                 switches + chat limit (survives a Reset Cache)
/// index.json                    chat id -> {lru tick, file key}
/// chat-list/chat-list.json      bots, previews, the last known unread counts
/// messages/<chat-key>.json      CachedTranscript
/// files-and-links/<chat-key>.json CachedLinkIndex
/// ```
///
/// `<host-key>` and `<chat-key>` are a readable slug plus a 64-bit FNV-1a suffix, so a profile name
/// or session id can never walk out of the directory and two ids that slug the same still land in
/// different files. Every write is `Data.write(options: .atomic)`: a half-written transcript is a
/// corrupt cache, and a corrupt cache is treated as a miss (the file is deleted, never trusted).
public actor HermesCacheStore {

    /// The stepper's default and range. 100 chats is what the official screen calls a good balance;
    /// the floor is one chat rather than ten so a test — or a hand-edited settings file — can prove
    /// eviction with a handful of rows instead of a hundred.
    public static let defaultChatLimit = 100
    public static let chatLimitRange = 1 ... 1_000
    /// Rows kept per chat. A chat is the eviction unit (that is what the Limit counts), so one very
    /// long conversation still needs a ceiling of its own — otherwise the cache is bounded by the
    /// longest thread the user ever opened.
    public static let maxMessagesPerChat = 500

    public nonisolated let host: String
    /// The host's own directory. Public for diagnostics and for tests that assert what landed on disk.
    public nonisolated let directory: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private var preferencesStore: CachePreferences?
    private var index = CacheIndexDocument()
    private var prepared = false
    private let clock: @Sendable () -> Date

    /// - Parameters:
    ///   - host: the paired host's display name; the cache is namespaced by it.
    ///   - root: the folder that holds one directory per host. Defaults to Application Support.
    public init(host: String,
                root: URL? = nil,
                fileManager: FileManager = .default,
                clock: @escaping @Sendable () -> Date = Date.init) {
        self.host = host
        self.fileManager = fileManager
        self.clock = clock
        let base = (root ?? HermesCacheStore.defaultRoot())
            .appendingPathComponent(CacheKey.fileName(for: host), isDirectory: true)
        self.directory = base
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    /// `Application Support/Hermey/Cache/hosts` — beside the client log, inside the app container on
    /// iOS and under `~/Library/Application Support` on the Mac.
    ///
    /// Application Support, not Caches, on purpose: the system may purge `Caches` whenever it likes,
    /// and a screen that offers a Reset button is promising the user control over this data.
    public static func defaultRoot(fileManager: FileManager = .default) -> URL {
        let support = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("Hermey", isDirectory: true)
            .appendingPathComponent("Cache", isDirectory: true)
            .appendingPathComponent("hosts", isDirectory: true)
    }

    // MARK: - Preferences

    public func preferences() -> CachePreferences {
        prepare()
        return storedPreferences()
    }

    /// Flip one section. Turning it off deletes exactly what it kept, in the same call: a switch that
    /// says "off" while the files are still there is the bug this screen exists to avoid.
    @discardableResult
    public func setSection(_ section: CacheSection, enabled: Bool) -> CachePreferences {
        prepare()
        var preferences = storedPreferences()
        preferences.set(section, enabled: enabled)
        savePreferences(preferences)
        if !enabled { removeSection(section) }
        return preferences
    }

    /// Change the chat limit. Lowering it evicts immediately rather than at the next write, so the
    /// Usage numbers under the stepper are true the moment the user lets go.
    @discardableResult
    public func setChatLimit(_ limit: Int) -> CachePreferences {
        prepare()
        var preferences = storedPreferences()
        preferences.chatLimit = min(max(limit, Self.chatLimitRange.lowerBound),
                                    Self.chatLimitRange.upperBound)
        savePreferences(preferences)
        enforceChatLimit(preferences.chatLimit)
        return preferences
    }

    // MARK: - Chat list

    /// Store the bot directory as the host just answered it, keeping whatever previews are already
    /// cached for bots the preview feed has not covered yet.
    @discardableResult
    public func storeBots(_ bots: [Bot]) -> Bool {
        prepare()
        guard storedPreferences().chatListEnabled else { return false }
        var document = chatList() ?? CachedChatList()
        let rows = bots.map(CachedBot.init)
        // The preview sweep runs every 25 s on a live app; rewriting an identical document would be
        // a disk write per tick for nothing.
        guard document.bots != rows else { return false }
        document.schema = CachedChatList.currentSchema
        document.savedAt = clock().timeIntervalSince1970
        document.bots = rows
        return write(document, to: chatListURL)
    }

    /// Store the preview/unread snapshot — the rows the bridge reads off the host's message table.
    @discardableResult
    public func storePreviews(_ previews: [String: CachedPreview],
                              unread: [String: Int] = [:]) -> Bool {
        prepare()
        guard storedPreferences().chatListEnabled, !previews.isEmpty else { return false }
        var document = chatList() ?? CachedChatList()
        let merged = document.previews.merging(previews) { _, new in new }
        guard merged != document.previews || document.unread != unread else { return false }
        document.schema = CachedChatList.currentSchema
        document.savedAt = clock().timeIntervalSince1970
        document.previews = merged
        document.unread = unread
        return write(document, to: chatListURL)
    }

    public func chatList() -> CachedChatList? {
        prepare()
        guard let document: CachedChatList = decode(at: chatListURL) else { return nil }
        guard document.schema == CachedChatList.currentSchema else {
            // A document from a build that wrote a different shape is a miss, not something to
            // guess at — and keeping it would make the Usage number include bytes nothing can read.
            try? fileManager.removeItem(at: chatListURL)
            return nil
        }
        return document
    }

    // MARK: - Transcripts

    /// Store a chat's rows and rebuild its files/links index from them.
    ///
    /// Called after a resume, a pager fetch or a finished turn — always with the host's own copy,
    /// never with the streaming bubble in flight.
    @discardableResult
    public func storeMessages(_ entries: [TranscriptEntry],
                              for chatID: String,
                              cursor: Int? = nil,
                              total: Int = 0) -> Bool {
        prepare()
        guard !chatID.isEmpty else { return false }
        let preferences = storedPreferences()
        guard preferences.messagesEnabled || preferences.filesAndLinksEnabled else { return false }
        guard !entries.isEmpty else {
            // The host says this conversation has no rows. Keeping yesterday's copy would paint a
            // transcript the host no longer has, which is exactly the stale cache this must not be.
            removeChatFiles(chatID)
            index.chats[chatID] = nil
            saveIndex()
            return false
        }

        var wrote = false
        let kept = Array(entries.suffix(Self.maxMessagesPerChat))
        if preferences.messagesEnabled {
            // A transcript shortened from the front has lost the row the host's cursor names, so the
            // cursor goes with it: offering "load earlier" from an offset we no longer hold would
            // fetch the wrong page.
            let truncated = kept.count < entries.count
            let document = CachedTranscript(chatID: chatID,
                                            savedAt: clock().timeIntervalSince1970,
                                            cursor: truncated ? nil : cursor,
                                            total: max(total, kept.count),
                                            entries: kept.map(CachedMessage.init))
            wrote = write(document, to: messagesURL(chatID)) || wrote
        }

        if preferences.filesAndLinksEnabled {
            let indexDocument = CachedLinkIndex.build(chatID: chatID, entries: kept, at: clock())
            wrote = write(indexDocument, to: linksURL(chatID)) || wrote
        }

        guard wrote else { return false }
        touch(chatID)
        enforceChatLimit(preferences.chatLimit)
        return true
    }

    /// The cached rows for a chat, if there are any. Reading them counts as using the chat, which is
    /// what LRU eviction needs to know.
    public func messages(for chatID: String) -> CachedTranscript? {
        prepare()
        let url = messagesURL(chatID)
        guard let document: CachedTranscript = decode(at: url) else { return nil }
        guard document.schema == CachedTranscript.currentSchema, document.chatID == chatID else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        touch(chatID)
        return document
    }

    /// The cached files/links index for a chat.
    public func links(for chatID: String) -> CachedLinkIndex? {
        prepare()
        let url = linksURL(chatID)
        guard let document: CachedLinkIndex = decode(at: url) else { return nil }
        guard document.schema == CachedLinkIndex.currentSchema, document.chatID == chatID else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        touch(chatID)
        return document
    }

    /// Chat ids the cache holds, least recently used first — the order the Limit drops them in.
    public func cachedChatIDs() -> [String] {
        prepare()
        return index.chats
            .filter { chatExists($0.key) }
            .sorted { $0.value.touch < $1.value.touch }
            .map(\.key)
    }

    // MARK: - Usage

    /// Measure what is on disk right now.
    public func usage() -> CacheUsage {
        prepare()
        // Every section reports a row, even at zero: the Usage list must not lose a line (and its
        // explanation) just because nothing has been cached into it yet.
        var sections: [CacheSection: CacheUsage.SectionUse] =
            Dictionary(uniqueKeysWithValues: CacheSection.allCases.map { ($0, .zero) })

        if let list = chatList() {
            sections[.chatList] = CacheUsage.SectionUse(bytes: fileSize(chatListURL),
                                                        count: list.bots.count)
        }

        var messageBytes = 0, messageCount = 0
        for url in files(in: sectionDirectory(.messages)) {
            guard let document: CachedTranscript = decode(at: url) else { continue }
            guard document.schema == CachedTranscript.currentSchema else {
                try? fileManager.removeItem(at: url)
                continue
            }
            messageBytes += fileSize(url)
            messageCount += document.entries.count
        }
        sections[.messages] = CacheUsage.SectionUse(bytes: messageBytes, count: messageCount)

        var linkBytes = 0, linkCount = 0
        for url in files(in: sectionDirectory(.filesAndLinks)) {
            guard let document: CachedLinkIndex = decode(at: url) else { continue }
            guard document.schema == CachedLinkIndex.currentSchema else {
                try? fileManager.removeItem(at: url)
                continue
            }
            linkBytes += fileSize(url)
            linkCount += document.items.count
        }
        sections[.filesAndLinks] = CacheUsage.SectionUse(bytes: linkBytes, count: linkCount)

        return CacheUsage(sections: sections, chatCount: cachedChatIDs().count)
    }

    // MARK: - Deleting

    /// Empty the cache but keep the switches and the limit: Reset frees storage, it does not
    /// silently re-enable something the user turned off.
    public func reset() {
        prepare()
        for section in CacheSection.allCases { removeSection(section) }
        index = CacheIndexDocument()
        writeIndex()
    }

    public func remove(_ section: CacheSection) {
        prepare()
        removeSection(section)
    }

    /// Forget one conversation — the host says it no longer exists, or the user reset it.
    public func discard(_ chatID: String) {
        prepare()
        removeChatFiles(chatID)
        index.chats[chatID] = nil
        saveIndex()
    }

    // MARK: - Storage plumbing

    private struct CacheIndexEntry: Codable, Equatable {
        var touch: Int
        var file: String
    }

    private struct CacheIndexDocument: Codable {
        var schema = 1
        var sequence = 0
        var chats: [String: CacheIndexEntry] = [:]
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS) || os(macOS)
        // A cache is rebuildable; it should not be what fills a backup.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = directory
        try? folder.setResourceValues(values)
        #endif
        loadPreferences()
        loadIndex()
    }

    private func sectionDirectory(_ section: CacheSection) -> URL {
        directory.appendingPathComponent(section.rawValue, isDirectory: true)
    }

    private var settingsURL: URL { directory.appendingPathComponent("settings.json") }
    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private var chatListURL: URL {
        sectionDirectory(.chatList).appendingPathComponent("chat-list.json")
    }

    private func messagesURL(_ chatID: String) -> URL {
        sectionDirectory(.messages)
            .appendingPathComponent("\(CacheKey.fileName(for: chatID)).json")
    }

    private func linksURL(_ chatID: String) -> URL {
        sectionDirectory(.filesAndLinks)
            .appendingPathComponent("\(CacheKey.fileName(for: chatID)).json")
    }

    private struct SettingsDocument: Codable {
        var schema = 1
        var preferences = CachePreferences.standard
    }

    private func storedPreferences() -> CachePreferences {
        if let preferencesStore { return preferencesStore }
        loadPreferences()
        return preferencesStore ?? .standard
    }

    private func loadPreferences() {
        guard preferencesStore == nil else { return }
        guard let document: SettingsDocument = decode(at: settingsURL) else {
            preferencesStore = .standard
            return
        }
        var preferences = document.preferences
        preferences.clampLimit()
        preferencesStore = preferences
    }

    private func savePreferences(_ preferences: CachePreferences) {
        preferencesStore = preferences
        var document = SettingsDocument()
        document.preferences = preferences
        write(document, to: settingsURL)
    }

    private func loadIndex() {
        if let document: CacheIndexDocument = decode(at: indexURL),
           document.schema == 1 {
            index = document
            return
        }
        rebuildIndex()
    }

    /// Recover the LRU order from the files themselves when `index.json` is missing or corrupt.
    ///
    /// The chat id lives inside each document, so nothing is lost but the exact order; file
    /// modification times are the next best evidence of what was used when.
    private func rebuildIndex() {
        var recovered: [(chatID: String, modified: Date, file: String)] = []
        for url in files(in: sectionDirectory(.messages)) {
            guard let document: CachedTranscript = decode(at: url) else { continue }
            recovered.append((document.chatID, modificationDate(url), CacheKey.fileName(for: document.chatID)))
        }
        for url in files(in: sectionDirectory(.filesAndLinks)) {
            guard let document: CachedLinkIndex = decode(at: url) else { continue }
            if !recovered.contains(where: { $0.chatID == document.chatID }) {
                recovered.append((document.chatID, modificationDate(url), CacheKey.fileName(for: document.chatID)))
            }
        }
        recovered.sort { $0.modified < $1.modified }
        index = CacheIndexDocument()
        index.sequence = recovered.count
        for (offset, row) in recovered.enumerated() {
            index.chats[row.chatID] = CacheIndexEntry(touch: offset + 1, file: row.file)
        }
        writeIndex()
    }

    private func saveIndex() {
        writeIndex()
    }

    private func writeIndex() {
        write(index, to: indexURL)
    }

    private func chatExists(_ chatID: String) -> Bool {
        fileManager.fileExists(atPath: messagesURL(chatID).path)
            || fileManager.fileExists(atPath: linksURL(chatID).path)
    }

    /// Mark a chat as used now. The index write is small and lands after the payload, so a crash in
    /// between costs at most an eviction order, never a lost transcript.
    private func touch(_ chatID: String) {
        index.sequence += 1
        index.chats[chatID] = CacheIndexEntry(touch: index.sequence,
                                              file: CacheKey.fileName(for: chatID))
        saveIndex()
    }

    private func enforceChatLimit(_ limit: Int) {
        var known = index.chats.filter { chatExists($0.key) }.map(\.key)
        if index.chats.count != known.count {
            index.chats = index.chats.filter { chatExists($0.key) }
        }
        while known.count > limit {
            guard let victim = known.min(by: { left, right in
                (index.chats[left]?.touch ?? Int.min) < (index.chats[right]?.touch ?? Int.min)
            }) else { break }
            removeChatFiles(victim)
            index.chats[victim] = nil
            known.removeAll { $0 == victim }
        }
        saveIndex()
    }

    private func removeChatFiles(_ chatID: String) {
        try? fileManager.removeItem(at: messagesURL(chatID))
        try? fileManager.removeItem(at: linksURL(chatID))
    }

    private func removeSection(_ section: CacheSection) {
        try? fileManager.removeItem(at: sectionDirectory(section))
        if section != .chatList {
            // Chats with no files left are not chats in this cache any more.
            index.chats = index.chats.filter { chatExists($0.key) }
            saveIndex()
        }
    }

    private func files(in directory: URL) -> [URL] {
        guard let rows = try? fileManager.contentsOfDirectory(at: directory,
                                                              includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else {
            return []
        }
        return rows.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func fileSize(_ url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    /// Read and decode, deleting a document that no longer parses.
    ///
    /// A corrupt cache is a cache miss, not an error the user hears about. Deleting it is what stops
    /// the same bad file from failing every launch.
    private func decode<T: Decodable>(at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let value = try? decoder.decode(T.self, from: data) else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        return value
    }

    @discardableResult
    private func write<T: Encodable>(_ value: T, to url: URL) -> Bool {
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let data = try encoder.encode(value)
            // Atomic: a reader (or a crash) sees the old document or the new one, never half of one.
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

/// File names that cannot escape their directory.
///
/// A session id or profile name comes from the host, and the host is not trusted to hand us
/// something path-shaped. The readable slug makes the folder browsable by a person; the hash suffix
/// keeps `a/b` and `a_b` apart after slugging, and makes the name stable across relaunches.
enum CacheKey {
    static func fileName(for value: String) -> String {
        var slug = ""
        for scalar in value.unicodeScalars {
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
        if slug.isEmpty { slug = "item" }
        if slug.count > 48 { slug = String(slug.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
        return "\(slug)-\(fingerprint(value))"
    }

    /// FNV-1a, 64-bit. Not a security hash: it only has to be stable and to separate two ids that
    /// slug to the same readable name.
    static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
