import XCTest
@testable import HermesKit

/// The device cache has one job and several ways to get it wrong.
///
/// These tests pin the promises the Caching screen makes to the user: the limit is honoured and
/// drops the least recently used chat first, a switch that is off leaves no files behind, the Usage
/// numbers are the real sizes and counts, and a half-written or hand-damaged cache is a miss rather
/// than a crash or a palace of lies.
final class CacheStoreTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func store(host: String = "casa", limit: Int? = nil) async -> HermesCacheStore {
        let store = HermesCacheStore(host: host, root: root)
        if let limit { _ = await store.setChatLimit(limit) }
        return store
    }

    private func message(_ id: String, _ text: String,
                         role: TranscriptEntry.Role = .user) -> TranscriptEntry {
        TranscriptEntry(id: id, role: role, text: text)
    }

    private func bot(_ id: String) -> Bot {
        Bot(id: id, name: id, displayName: id.capitalized)
    }

    private func files(in url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    }

    private func directorySize(_ url: URL) -> Int {
        files(in: url).reduce(0) { total, file in
            total + ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    // MARK: - Eviction

    func testTheLeastRecentlyUsedChatIsDroppedFirst() async throws {
        let cache = await store(limit: 2)
        _ = await cache.storeMessages([message("a1", "alpha one")], for: "chat-a")
        _ = await cache.storeMessages([message("b1", "beta one")], for: "chat-b")

        // Reading A makes it the most recently used of the two, so B is the one the limit drops.
        let readBack = await cache.messages(for: "chat-a")
        XCTAssertEqual(readBack?.entries.count, 1)
        _ = await cache.storeMessages([message("c1", "gamma one")], for: "chat-c")

        let kept = await cache.cachedChatIDs()
        XCTAssertEqual(kept, ["chat-a", "chat-c"])
        let evicted = await cache.messages(for: "chat-b")
        XCTAssertNil(evicted, "the coldest chat is the one evicted")
        let survivor = await cache.messages(for: "chat-a")
        XCTAssertNotNil(survivor)
    }

    func testEvictionTakesTheChatsFilesAndLinksWithIt() async throws {
        let cache = await store(limit: 1)
        let rows = [message("a1", "see @image:/tmp/photo.png and https://example.com/doc")]
        _ = await cache.storeMessages(rows, for: "chat-a")
        let indexBefore = await cache.links(for: "chat-a")
        XCTAssertNotNil(indexBefore)

        _ = await cache.storeMessages([message("b1", "hello")], for: "chat-b")

        let messagesLeft = await cache.messages(for: "chat-a")
        let linksLeft = await cache.links(for: "chat-a")
        XCTAssertNil(messagesLeft)
        XCTAssertNil(linksLeft, "the index dies with its transcript")
        XCTAssertEqual(files(in: cache.directory.appendingPathComponent("messages")).count, 1)
        XCTAssertEqual(files(in: cache.directory.appendingPathComponent("files-and-links")).count, 1)
    }

    func testLoweringTheLimitEvictsImmediately() async throws {
        let cache = await store()
        for index in 0 ..< 6 {
            _ = await cache.storeMessages([message("m\(index)", "row \(index)")], for: "chat-\(index)")
        }
        let before = await cache.cachedChatIDs()
        XCTAssertEqual(before.count, 6)

        _ = await cache.setChatLimit(3)
        let kept = await cache.cachedChatIDs()
        XCTAssertEqual(kept, ["chat-3", "chat-4", "chat-5"], "the newest three survive")
        let usage = await cache.usage()
        XCTAssertEqual(usage.chatCount, 3)
    }

    func testTheLimitIsClampedToTheSteppersRange() async throws {
        let cache = await store()
        let low = await cache.setChatLimit(0)
        XCTAssertEqual(low.chatLimit, HermesCacheStore.chatLimitRange.lowerBound)
        let high = await cache.setChatLimit(10_000)
        XCTAssertEqual(high.chatLimit, HermesCacheStore.chatLimitRange.upperBound)
    }

    // MARK: - Switches

    func testTurningMessagesOffDeletesThemAndLeavesTheOtherSections() async throws {
        let cache = await store()
        _ = await cache.storeBots([bot("cody"), bot("aria")])
        _ = await cache.storeMessages([message("a1", "hi @file:/tmp/report.pdf")], for: "chat-a")

        let preferences = await cache.setSection(.messages, enabled: false)

        XCTAssertFalse(preferences.messagesEnabled)
        XCTAssertTrue(preferences.chatListEnabled, "one switch does not move the others")
        let rows = await cache.messages(for: "chat-a")
        XCTAssertNil(rows, "off means gone, not hidden")
        XCTAssertEqual(files(in: cache.directory.appendingPathComponent("messages")).count, 0)
        let list = await cache.chatList()
        XCTAssertNotNil(list)
        let index = await cache.links(for: "chat-a")
        XCTAssertNotNil(index)
    }

    func testTurningChatListOffDeletesOnlyThatDocument() async throws {
        let cache = await store()
        _ = await cache.storeBots([bot("cody")])
        _ = await cache.storeMessages([message("a1", "hello")], for: "chat-a")

        _ = await cache.setSection(.chatList, enabled: false)

        let list = await cache.chatList()
        XCTAssertNil(list)
        XCTAssertEqual(files(in: cache.directory.appendingPathComponent("chat-list")).count, 0)
        let rows = await cache.messages(for: "chat-a")
        XCTAssertNotNil(rows)
    }

    func testATurnedOffSectionWritesNothingNew() async throws {
        let cache = await store()
        _ = await cache.setSection(.filesAndLinks, enabled: false)
        _ = await cache.storeMessages([message("a1", "hi @image:/tmp/p.png")], for: "chat-a")

        let rows = await cache.messages(for: "chat-a")
        let index = await cache.links(for: "chat-a")
        XCTAssertNotNil(rows)
        XCTAssertNil(index)
        XCTAssertEqual(files(in: cache.directory.appendingPathComponent("files-and-links")).count, 0)
    }

    func testSwitchesSurviveARelaunchAndResetKeepsThem() async throws {
        let first = await store()
        _ = await first.setSection(.messages, enabled: false)
        _ = await first.setChatLimit(42)
        _ = await first.storeBots([bot("cody")])

        let second = HermesCacheStore(host: "casa", root: root)
        let preferences = await second.preferences()
        XCTAssertFalse(preferences.messagesEnabled)
        XCTAssertEqual(preferences.chatLimit, 42)
        let list = await second.chatList()
        XCTAssertNotNil(list, "the document written before the relaunch is there")

        await second.reset()
        let afterReset = await second.preferences()
        XCTAssertFalse(afterReset.messagesEnabled, "Reset frees storage; it does not re-enable a switch")
        XCTAssertEqual(afterReset.chatLimit, 42)
        let listAfterReset = await second.chatList()
        XCTAssertNil(listAfterReset)
    }

    // MARK: - Integrity

    func testACorruptDocumentIsAMissAndIsDeleted() async throws {
        let cache = await store()
        _ = await cache.storeMessages([message("a1", "hello")], for: "chat-a")
        let file = cache.directory
            .appendingPathComponent("messages")
            .appendingPathComponent(CacheKey.fileName(for: "chat-a") + ".json")
        try Data("{ not json".utf8).write(to: file)

        let rows = await cache.messages(for: "chat-a")
        XCTAssertNil(rows)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "a corrupt file is deleted so the next launch is not failed by it")
    }

    func testAnEmptyOrMissingCacheIsAnEmptyUsageNotAnError() async throws {
        let cache = await store()
        let usage = await cache.usage()
        XCTAssertEqual(usage, .empty)
        let list = await cache.chatList()
        let rows = await cache.messages(for: "nothing")
        let chats = await cache.cachedChatIDs()
        XCTAssertNil(list)
        XCTAssertNil(rows)
        XCTAssertEqual(chats, [])
    }

    func testACorruptIndexIsRebuiltFromTheFiles() async throws {
        let cache = await store()
        _ = await cache.storeMessages([message("a1", "alpha")], for: "chat-a")
        _ = await cache.storeMessages([message("b1", "beta")], for: "chat-b")
        try Data("garbage".utf8).write(to: cache.directory.appendingPathComponent("index.json"))

        // A fresh instance is what a relaunch is; it must still find both chats and still evict.
        let reopened = HermesCacheStore(host: "casa", root: root)
        let chats = await reopened.cachedChatIDs()
        XCTAssertEqual(chats.count, 2)
        let rows = await reopened.messages(for: "chat-a")
        XCTAssertNotNil(rows)
        _ = await reopened.setChatLimit(1)
        let remaining = await reopened.cachedChatIDs()
        XCTAssertEqual(remaining.count, 1)
    }

    func testAnEmptyTranscriptRemovesAStaleCopy() async throws {
        let cache = await store()
        _ = await cache.storeMessages([message("a1", "hello")], for: "chat-a")
        _ = await cache.storeMessages([], for: "chat-a")
        let rows = await cache.messages(for: "chat-a")
        XCTAssertNil(rows)
    }

    func testDiscardForgetsOneChatAndLeavesTheRest() async throws {
        let cache = await store()
        _ = await cache.storeMessages([message("a1", "alpha")], for: "chat-a")
        _ = await cache.storeMessages([message("b1", "beta")], for: "chat-b")

        await cache.discard("chat-a")

        let discarded = await cache.messages(for: "chat-a")
        let kept = await cache.messages(for: "chat-b")
        XCTAssertNil(discarded)
        XCTAssertNotNil(kept)
        let chats = await cache.cachedChatIDs()
        XCTAssertEqual(chats, ["chat-b"])
    }

    func testADocumentFromAnotherSchemaIsAMissAndIsDeleted() async throws {
        let cache = await store()
        _ = await cache.storeMessages([message("a1", "hello")], for: "chat-a")
        let file = cache.directory
            .appendingPathComponent("messages")
            .appendingPathComponent(CacheKey.fileName(for: "chat-a") + ".json")
        try Data(#"{"schema":0,"chatID":"chat-a","savedAt":0,"cursor":null,"total":1,"entries":[]}"#.utf8)
            .write(to: file)

        let rows = await cache.messages(for: "chat-a")
        XCTAssertNil(rows, "a shape this build cannot read is a miss, not a guess")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let usage = await cache.usage()
        XCTAssertEqual(usage.bytes(.messages), 0, "a file nothing can read must not count as cache")
    }

    func testOnlyTheNewestRowsAreKeptAndTheCursorGoesWithThem() async throws {
        let cache = await store()
        let rows = (0 ..< (HermesCacheStore.maxMessagesPerChat + 40)).map {
            message("m\($0)", "row \($0)")
        }
        _ = await cache.storeMessages(rows, for: "long-chat", cursor: 900, total: 1_200)

        let cached = await cache.messages(for: "long-chat")
        let transcript = try XCTUnwrap(cached)
        XCTAssertEqual(transcript.entries.count, HermesCacheStore.maxMessagesPerChat)
        XCTAssertEqual(transcript.entries.first?.id, "m40", "the oldest rows are the ones dropped")
        XCTAssertNil(transcript.cursor, "the host cursor names a row we no longer hold")
    }

    // MARK: - Usage

    func testUsageCountsAndSizesAreTheFilesOnDisk() async throws {
        let cache = await store()
        _ = await cache.storeBots([bot("cody"), bot("aria"), bot("ops")])
        _ = await cache.storePreviews(["cody": CachedPreview(text: "the brief is ready", timestamp: 1_760_000_000)])
        _ = await cache.storeMessages([
            message("a1", """
            look at this
            @image:/tmp/shot.png
            https://example.com/a
            """),
            message("a2", "done", role: .assistant),
        ], for: "chat-a")
        _ = await cache.storeMessages([
            message("b1", """
            one note
            @file:/tmp/notes.md
            """),
        ], for: "chat-b")

        let usage = await cache.usage()
        XCTAssertEqual(usage.count(.chatList), 3)
        XCTAssertEqual(usage.count(.messages), 3)
        XCTAssertEqual(usage.count(.filesAndLinks), 3, "one image, one link, one file")
        XCTAssertEqual(usage.chatCount, 2)

        let chatListBytes = ((try? cache.directory
            .appendingPathComponent("chat-list/chat-list.json")
            .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let messagesBytes = directorySize(cache.directory.appendingPathComponent("messages"))
        let linkBytes = directorySize(cache.directory.appendingPathComponent("files-and-links"))
        XCTAssertEqual(usage.bytes(.chatList), chatListBytes)
        XCTAssertEqual(usage.bytes(.messages), messagesBytes)
        XCTAssertEqual(usage.bytes(.filesAndLinks), linkBytes)
        XCTAssertEqual(usage.totalBytes, chatListBytes + messagesBytes + linkBytes)
        XCTAssertGreaterThan(usage.totalBytes, 0)
    }

    func testUsageDropsToZeroAfterAReset() async throws {
        let cache = await store()
        _ = await cache.storeBots([bot("cody")])
        _ = await cache.storeMessages([message("a1", "hello")], for: "chat-a")
        await cache.reset()

        let usage = await cache.usage()
        XCTAssertEqual(usage.totalBytes, 0)
        XCTAssertEqual(usage.count(.messages), 0)
        XCTAssertEqual(usage.chatCount, 0)
    }

    // MARK: - Per-host and on-disk shape

    func testTwoHostsNeverSeeEachOthersCache() async throws {
        let first = await store(host: "first")
        let second = await store(host: "second")
        XCTAssertNotEqual(first.directory, second.directory)

        _ = await first.storeMessages([message("a1", "first host only")], for: "chat-a")
        let other = await second.messages(for: "chat-a")
        let own = await first.messages(for: "chat-a")
        XCTAssertNil(other)
        XCTAssertNotNil(own)
    }

    func testAHostileChatIdCannotWalkOutOfTheCacheDirectory() async throws {
        let cache = await store()
        _ = await cache.storeMessages([message("a1", "hello")], for: "../../etc/passwd")

        let rows = await cache.messages(for: "../../etc/passwd")
        XCTAssertNotNil(rows)
        let escaped = root.appendingPathComponent("etc/passwd.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path))
        let names = files(in: cache.directory.appendingPathComponent("messages")).map(\.lastPathComponent)
        XCTAssertEqual(names.count, 1)
        XCTAssertFalse(names[0].contains("/") || names[0].contains(".."))
    }

    func testTheStoredTranscriptRoundTripsRolesTextAndToolRows() async throws {
        let cache = await store()
        let tool = TranscriptEntry(id: "t1", role: .tool, text: "terminal · uptime",
                                   at: Date(timeIntervalSince1970: 1_760_000_123),
                                   tool: TranscriptEntry.ToolDetail(name: "terminal",
                                                                    context: "uptime",
                                                                    args: "{\"cmd\":\"uptime\"}",
                                                                    labels: ["uptime"]))
        _ = await cache.storeMessages([message("u1", "check it"), tool], for: "chat-a")

        let cached = await cache.messages(for: "chat-a")
        let transcript = try XCTUnwrap(cached)
        XCTAssertEqual(transcript.entries.map(\.role), ["user", "tool"])
        XCTAssertEqual(transcript.entries[1].tool?.name, "terminal")
        XCTAssertEqual(transcript.entries[1].tool?.args, "{\"cmd\":\"uptime\"}")
        XCTAssertEqual(transcript.entries[1].at, 1_760_000_123)
    }

    func testTheChatListKeepsBotsAndPreviewsWhenEitherArrivesAlone() async throws {
        let cache = await store()
        _ = await cache.storeBots([bot("cody")])
        _ = await cache.storePreviews(["cody": CachedPreview(text: "morning brief", timestamp: 1_760_000_000)])

        let cached = await cache.chatList()
        let document = try XCTUnwrap(cached)
        XCTAssertEqual(document.bots.map(\.id), ["cody"])
        XCTAssertEqual(document.previews["cody"]?.text, "morning brief")
        XCTAssertEqual(document.bots.first?.bot.displayName, "Cody")
    }

    func testTheFilesAndLinksIndexFindsImagesFilesAndURLs() async throws {
        let cache = await store()
        let rows = [
            message("u1", """
            here are two things
            @image:/home/agent/images/upload_ab12.png
            @file:/tmp/notes/report.pdf
            """, role: .user),
            message("a1", "read https://example.com/docs and http://example.org/x).", role: .assistant),
        ]
        _ = await cache.storeMessages(rows, for: "chat-a")

        let cached = await cache.links(for: "chat-a")
        let index = try XCTUnwrap(cached)
        XCTAssertEqual(index.items.filter { $0.kind == .image }.map(\.name), ["upload_ab12.png"])
        XCTAssertEqual(index.items.filter { $0.kind == .file }.map(\.name), ["report.pdf"])
        XCTAssertEqual(index.items.filter { $0.kind == .link }.map(\.name),
                       ["example.com", "example.org"])

        // The index is what re-attaches a chip to a cached row when the vault has no bytes.
        let attached = index.attachMissing(to: rows)
        XCTAssertEqual(attached[0].attachments.map(\.name), ["upload_ab12.png", "report.pdf"])
        XCTAssertTrue(attached[1].attachments.isEmpty, "links are not attachments")
    }

    func testFormattingIsDecimalAndReadsNaturally() {
        XCTAssertEqual(CacheFormat.size(0), "0 B")
        XCTAssertEqual(CacheFormat.size(999), "999 B")
        XCTAssertEqual(CacheFormat.size(1_500), "2 KB")
        XCTAssertEqual(CacheFormat.size(2_400_000), "2.4 MB")
        XCTAssertEqual(CacheFormat.count(1, .messages), "1 message")
        XCTAssertEqual(CacheFormat.count(2, .messages), "2 messages")
    }
}
