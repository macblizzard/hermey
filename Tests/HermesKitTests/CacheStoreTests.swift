import XCTest
@testable import HermesKit

/// The device cache has one job and several ways to get it wrong.
///
/// These tests pin the promises the Caching screen makes to the user: the limit is a choice of
/// three sizes and nothing else, it drops the least recently used chat first, it applies to the
/// chat-list document as well as to the transcripts (so neither Usage count can read higher than
/// the number in the picker), a switch that is off leaves no files behind, the Usage numbers are
/// the real sizes and counts, and a half-written or hand-damaged cache is a miss rather than a
/// crash or a palace of lies.
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

    /// The documents in a section directory, without `.DS_Store` or an atomic write's leftovers.
    private func documents(in url: URL) -> [URL] {
        files(in: url).filter { $0.pathExtension == "json" }
    }

    private func directorySize(_ url: URL) -> Int {
        files(in: url).reduce(0) { total, file in
            total + ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func settings(_ cache: HermesCacheStore) -> URL {
        cache.directory.appendingPathComponent("settings.json")
    }

    /// A settings file as the previous build wrote it — no store, just JSON on disk.
    private func writeSettings(_ json: String, for cache: HermesCacheStore) throws {
        try Data(json.utf8).write(to: settings(cache))
    }

    private struct StoredSettings: Decodable {
        struct Preferences: Decodable {
            var chatListEnabled: Bool
            var messagesEnabled: Bool
            var chatLimit: Int
        }
        var preferences: Preferences
    }

    private func storedSettings(_ cache: HermesCacheStore) throws -> StoredSettings {
        let data = try Data(contentsOf: settings(cache))
        return try JSONDecoder().decode(StoredSettings.self, from: data)
    }

    // MARK: - The limit is a choice of three

    func testTheLimitOffersExactlyThreeSizes() {
        XCTAssertEqual(CacheChatLimit.options, [25, 100, 500])
        XCTAssertEqual(HermesCacheStore.chatLimitOptions, [25, 100, 500])
        XCTAssertEqual(CacheChatLimit.standard, 100)
        for option in CacheChatLimit.options {
            XCTAssertTrue(CacheChatLimit.allows(option))
            XCTAssertEqual(CacheChatLimit.nearest(to: option), option)
        }
        for arbitrary in [0, 1, 24, 42, 196, 999, 10_000] {
            XCTAssertTrue(CacheChatLimit.allows(CacheChatLimit.nearest(to: arbitrary)),
                          "\(arbitrary) must land on an offered size")
        }
        XCTAssertFalse(CacheChatLimit.allows(0))
        XCTAssertFalse(CacheChatLimit.allows(42))
        XCTAssertFalse(CacheChatLimit.allows(1_000))
    }

    func testAnArbitraryValueLandsOnTheNearestOfferedSize() {
        XCTAssertEqual(CacheChatLimit.nearest(to: -5), 25, "the old stepper allowed 1; a 1 is a 25")
        XCTAssertEqual(CacheChatLimit.nearest(to: 0), 25)
        XCTAssertEqual(CacheChatLimit.nearest(to: 12), 25)
        XCTAssertEqual(CacheChatLimit.nearest(to: 62), 25)
        XCTAssertEqual(CacheChatLimit.nearest(to: 63), 100)
        XCTAssertEqual(CacheChatLimit.nearest(to: 196), 100)
        XCTAssertEqual(CacheChatLimit.nearest(to: 300), 100, "exactly between two sizes keeps less")
        XCTAssertEqual(CacheChatLimit.nearest(to: 301), 500)
        XCTAssertEqual(CacheChatLimit.nearest(to: 10_000), 500)
        XCTAssertEqual(CacheChatLimit.label(25), "25 chats")
        XCTAssertEqual(CacheChatLimit.label(1), "1 chat")
    }

    func testAFreshCacheKeepsAHundredChats() async {
        let cache = await store()
        let preferences = await cache.preferences()
        XCTAssertEqual(preferences.chatLimit, 100)
        XCTAssertEqual(preferences.chatLimit, CacheChatLimit.standard)
        XCTAssertTrue(preferences.chatListEnabled)
    }

    func testTheChosenSizeIsStoredAndSurvivesARelaunch() async throws {
        let first = await store(limit: 25)
        _ = await first.setSection(.messages, enabled: false)
        _ = await first.setChatLimit(500)

        let reopened = HermesCacheStore(host: "casa", root: root)
        let preferences = await reopened.preferences()
        XCTAssertEqual(preferences.chatLimit, 500)
        XCTAssertFalse(preferences.messagesEnabled)
        XCTAssertEqual(try storedSettings(reopened).preferences.chatLimit, 500)
    }

    func testAnArbitraryValueIsSnappedWhenSet() async {
        let cache = await store()
        let high = await cache.setChatLimit(400)
        XCTAssertEqual(high.chatLimit, 500)
        let low = await cache.setChatLimit(1)
        XCTAssertEqual(low.chatLimit, 25, "the old stepper's floor is not an offered size")
        let middle = await cache.setChatLimit(137)
        XCTAssertEqual(middle.chatLimit, 100)
    }

    func testAStoredLimitFromTheOldStepperIsMigratedAndRewritten() async throws {
        let cache = await store()
        _ = await cache.storeMessages([message("a1", "hello")], for: "chat-a")
        // What the build with a 1…1000 stepper could leave behind: 196 chats.
        try writeSettings("""
        {"schema":1,"preferences":{"chatListEnabled":true,"messagesEnabled":true,
        "filesAndLinksEnabled":true,"chatLimit":196}}
        """, for: cache)

        let reopened = HermesCacheStore(host: "casa", root: root)
        let preferences = await reopened.preferences()
        XCTAssertEqual(preferences.chatLimit, 100)
        XCTAssertTrue(CacheChatLimit.allows(preferences.chatLimit))
        XCTAssertEqual(try storedSettings(reopened).preferences.chatLimit, 100,
                       "the migrated value is written back, not just displayed")
        let transcript = await reopened.messages(for: "chat-a")
        XCTAssertNotNil(transcript, "migrating the limit does not throw the cache away")
    }

    // MARK: - Eviction

    func testTheLeastRecentlyUsedChatIsDroppedFirst() async throws {
        let cache = await store(limit: 25)
        _ = await cache.storeMessages([message("b1", "beta one")], for: "chat-b")
        _ = await cache.storeMessages([message("a1", "alpha one")], for: "chat-a")
        // Fill the rest so the two chats above are the oldest entries in the index.
        for index in 0 ..< (25 - 2) {
            _ = await cache.storeMessages([message("f\(index)", "filler \(index)")], for: "chat-f\(index)")
        }

        // Reading A makes it the most recently used, so B is the one the limit drops.
        let readBack = await cache.messages(for: "chat-a")
        XCTAssertEqual(readBack?.entries.count, 1)
        _ = await cache.storeMessages([message("c1", "gamma one")], for: "chat-c")

        let kept = await cache.cachedChatIDs()
        XCTAssertEqual(kept.count, 25)
        XCTAssertTrue(kept.contains("chat-a"), "a chat that was just read is not the victim")
        XCTAssertTrue(kept.contains("chat-c"))
        let evicted = await cache.messages(for: "chat-b")
        XCTAssertNil(evicted, "the coldest chat is the one evicted")
        let survivor = await cache.messages(for: "chat-a")
        XCTAssertNotNil(survivor)
    }

    func testEvictionTakesTheChatsFilesAndLinksWithIt() async throws {
        let cache = await store(limit: 25)
        let rows = [message("a1", "see @image:/tmp/photo.png and https://example.com/doc")]
        _ = await cache.storeMessages(rows, for: "chat-a")
        let indexBefore = await cache.links(for: "chat-a")
        XCTAssertNotNil(indexBefore)
        for offset in 0 ..< 24 {
            _ = await cache.storeMessages([message("m\(offset)", "hello")], for: "chat-\(offset)")
        }

        _ = await cache.storeMessages([message("b1", "hello")], for: "chat-b")

        let messagesLeft = await cache.messages(for: "chat-a")
        let linksLeft = await cache.links(for: "chat-a")
        XCTAssertNil(messagesLeft)
        XCTAssertNil(linksLeft, "the index dies with its transcript")
        XCTAssertEqual(documents(in: cache.directory.appendingPathComponent("messages")).count, 25)
        XCTAssertEqual(documents(in: cache.directory.appendingPathComponent("files-and-links")).count, 25)
    }

    func testLoweringTheLimitEvictsImmediately() async throws {
        let cache = await store()
        for index in 0 ..< 30 {
            _ = await cache.storeMessages([message("m\(index)", "row \(index)")], for: "chat-\(index)")
        }
        let before = await cache.cachedChatIDs()
        XCTAssertEqual(before.count, 30, "the default hundred has room for thirty")

        _ = await cache.setChatLimit(25)
        let kept = await cache.cachedChatIDs()
        XCTAssertEqual(kept, Array(5 ..< 30).map { "chat-\($0)" }, "the newest twenty-five survive")
        let usage = await cache.usage()
        XCTAssertEqual(usage.chatCount, 25)
    }

    func testEveryOfferedSizeEvictsDownToIt() async throws {
        for option in CacheChatLimit.options {
            let cache = await store(host: "size-\(option)", limit: option)
            // Files & links off: this test is about chats, not about two files per chat.
            _ = await cache.setSection(.filesAndLinks, enabled: false)
            for index in 0 ..< (option + 3) {
                _ = await cache.storeMessages([message("m\(index)", "row \(index)")], for: "chat-\(index)")
            }
            let kept = await cache.cachedChatIDs()
            XCTAssertEqual(kept.count, option, "\(option) chats are kept")
            XCTAssertEqual(kept.first, "chat-3", "the three oldest went first")
            let usage = await cache.usage()
            XCTAssertEqual(usage.chatCount, option)
            XCTAssertEqual(documents(in: cache.directory.appendingPathComponent("messages")).count, option)
        }
    }

    func testALaunchAppliesTheLimitToACacheWrittenUnderABiggerOne() async throws {
        let cache = await store(limit: 500)
        _ = await cache.setSection(.filesAndLinks, enabled: false)
        for index in 0 ..< 120 {
            _ = await cache.storeMessages([message("m\(index)", "row \(index)")], for: "chat-\(index)")
        }
        _ = await cache.storeBots((0 ..< 120).map { bot("chat-\($0)") })
        // The old stepper's settings file, after the user had dragged it to nearly two hundred.
        try writeSettings("""
        {"schema":1,"preferences":{"chatListEnabled":true,"messagesEnabled":true,
        "filesAndLinksEnabled":false,"chatLimit":196}}
        """, for: cache)

        // A relaunch is a fresh instance: prepare() must bring the cache down to the limit before
        // anything is painted or counted.
        let reopened = HermesCacheStore(host: "casa", root: root)
        let preferences = await reopened.preferences()
        XCTAssertEqual(preferences.chatLimit, 100)

        let cachedList = await reopened.chatList()
        let document = try XCTUnwrap(cachedList)
        XCTAssertEqual(document.bots.count, 100, "the chat-list document itself was trimmed")
        let chats = await reopened.cachedChatIDs()
        XCTAssertEqual(chats.count, 100)
        XCTAssertEqual(documents(in: reopened.directory.appendingPathComponent("messages")).count, 100)
        let usage = await reopened.usage()
        XCTAssertEqual(usage.count(.chatList), 100)
        XCTAssertEqual(usage.chatCount, 100)
    }

    // MARK: - The chat list obeys the same limit

    func testTheChatListIsTrimmedToTheLimit() async throws {
        let cache = await store(limit: 25)
        _ = await cache.storeBots((0 ..< 30).map { bot("bot-\($0)") })

        let cachedList = await cache.chatList()
        let document = try XCTUnwrap(cachedList)
        XCTAssertEqual(document.bots.count, 25, "the row the screen counts is never above the limit")
        XCTAssertEqual(document.bots.first?.id, "bot-0", "without previews the host's order decides")
        XCTAssertEqual(document.bots.last?.id, "bot-24")
        let usage = await cache.usage()
        XCTAssertEqual(usage.count(.chatList), 25)
        XCTAssertEqual(CacheFormat.count(usage.count(.chatList), .chatList), "25 chats")
    }

    func testTheNewestChatsSurviveWhenTheListIsTrimmed() async throws {
        let cache = await store(limit: 500)
        _ = await cache.storeBots((0 ..< 30).map { bot("bot-\($0)") })
        // bot-0's newest message is the oldest of the thirty, bot-29's the newest.
        let previews = (0 ..< 30).reduce(into: [String: CachedPreview]()) { rows, index in
            rows["bot-\(index)"] = CachedPreview(text: "row \(index)",
                                                 timestamp: 1_760_000_000 + Double(index))
        }
        _ = await cache.storePreviews(previews)
        _ = await cache.setChatLimit(25)

        let cachedList = await cache.chatList()
        let document = try XCTUnwrap(cachedList)
        XCTAssertEqual(document.bots.count, 25)
        XCTAssertFalse(document.bots.contains { $0.id == "bot-0" }, "the oldest chat is the victim")
        XCTAssertFalse(document.bots.contains { $0.id == "bot-4" })
        XCTAssertTrue(document.bots.contains { $0.id == "bot-5" })
        XCTAssertTrue(document.bots.contains { $0.id == "bot-29" })
        XCTAssertNil(document.previews["bot-0"], "a preview for a dropped chat is dropped too")
        XCTAssertEqual(document.previews.count, 25)
    }

    func testTheChatListAndTranscriptsNeverExceedTheLimit() async throws {
        let cache = await store(limit: 25)
        for index in 0 ..< 30 {
            _ = await cache.storeMessages([message("m\(index)", "row \(index)")], for: "chat-\(index)")
        }
        _ = await cache.storeBots((0 ..< 30).map { bot("chat-\($0)") })

        let cachedList = await cache.chatList()
        let document = try XCTUnwrap(cachedList)
        XCTAssertEqual(document.bots.count, 25)
        let chats = await cache.cachedChatIDs()
        XCTAssertLessThanOrEqual(chats.count, 25)
        let usage = await cache.usage()
        XCTAssertLessThanOrEqual(usage.count(.chatList), 25)
        XCTAssertLessThanOrEqual(usage.chatCount, 25)
        XCTAssertEqual(usage.count(.chatList), document.bots.count,
                       "the row counts the rows the file holds")
        XCTAssertEqual(documents(in: cache.directory.appendingPathComponent("messages")).count,
                       usage.chatCount, "the chat count is the transcripts on disk")
    }

    func testAChatDroppedFromTheListLosesItsTranscript() async throws {
        let cache = await store(limit: 25)
        _ = await cache.storeBots((0 ..< 25).map { bot("old-\($0)") })
        for index in 0 ..< 25 {
            _ = await cache.storeMessages([message("m\(index)", "row \(index)")], for: "old-\(index)")
        }
        let before = await cache.usage()
        XCTAssertEqual(before.chatCount, 25)

        // A new chat arrives at the top of the host's list, so the roster is one row over the limit
        // and the last row — old-24, whose transcript is cached — is the one it drops.
        _ = await cache.storeBots([bot("fresh")] + (0 ... 24).map { bot("old-\($0)") })

        let cachedList = await cache.chatList()
        let document = try XCTUnwrap(cachedList)
        XCTAssertEqual(document.bots.count, 25)
        XCTAssertEqual(document.bots.first?.id, "fresh")
        XCTAssertFalse(document.bots.contains { $0.id == "old-24" }, "the oldest chat was crowded out")
        let left = await cache.messages(for: "old-24")
        XCTAssertNil(left, "a chat the list no longer keeps keeps nothing")
        let keptRows = await cache.messages(for: "old-23")
        XCTAssertNotNil(keptRows)
        let usage = await cache.usage()
        XCTAssertEqual(usage.count(.chatList), 25)
        XCTAssertEqual(usage.chatCount, 24)
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
        XCTAssertEqual(documents(in: cache.directory.appendingPathComponent("messages")).count, 0)
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
        XCTAssertEqual(documents(in: cache.directory.appendingPathComponent("files-and-links")).count, 0)
    }

    func testSwitchesSurviveARelaunchAndResetKeepsThem() async throws {
        let first = await store()
        _ = await first.setSection(.messages, enabled: false)
        _ = await first.setChatLimit(25)
        _ = await first.storeBots([bot("cody")])

        let second = HermesCacheStore(host: "casa", root: root)
        let preferences = await second.preferences()
        XCTAssertFalse(preferences.messagesEnabled)
        XCTAssertEqual(preferences.chatLimit, 25)
        let list = await second.chatList()
        XCTAssertNotNil(list, "the document written before the relaunch is there")

        await second.reset()
        let afterReset = await second.preferences()
        XCTAssertFalse(afterReset.messagesEnabled, "Reset frees storage; it does not re-enable a switch")
        XCTAssertEqual(afterReset.chatLimit, 25, "Reset keeps the limit the user chose")
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
        _ = await reopened.setChatLimit(25)
        for index in 0 ..< 25 {
            _ = await reopened.storeMessages([message("f\(index)", "row \(index)")], for: "fill-\(index)")
        }
        let remaining = await reopened.cachedChatIDs()
        XCTAssertEqual(remaining.count, 25)
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
        XCTAssertEqual(transcript.cursor, 940,
                       "the cursor moves forward by the rows dropped, so paging back still lines up")
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
        XCTAssertEqual(usage.count(.chatList), 3, "three chats, counted in chats")
        XCTAssertEqual(usage.count(.messages), 3)
        XCTAssertEqual(usage.count(.filesAndLinks), 3, "one image, one link, one file")
        XCTAssertEqual(usage.chatCount, 2)

        // Every count is the number of things actually on disk, not a running total.
        let messageFiles = documents(in: cache.directory.appendingPathComponent("messages"))
        let linkFiles = documents(in: cache.directory.appendingPathComponent("files-and-links"))
        let cachedList = await cache.chatList()
        let document = try XCTUnwrap(cachedList)
        XCTAssertEqual(usage.count(.chatList), document.bots.count)
        XCTAssertEqual(usage.chatCount, messageFiles.count)
        let rowsOnDisk = try messageFiles.reduce(0) { total, url in
            let transcript = try JSONDecoder().decode(CachedTranscript.self, from: Data(contentsOf: url))
            return total + transcript.entries.count
        }
        XCTAssertEqual(usage.count(.messages), rowsOnDisk)
        let itemsOnDisk = try linkFiles.reduce(0) { total, url in
            let index = try JSONDecoder().decode(CachedLinkIndex.self, from: Data(contentsOf: url))
            return total + index.items.count
        }
        XCTAssertEqual(usage.count(.filesAndLinks), itemsOnDisk, "one item per link, not per file")

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

    func testUsageNeverReportsMoreChatsThanTheLimit() async throws {
        let cache = await store(limit: 25)
        for index in 0 ..< 40 {
            _ = await cache.storeMessages([message("m\(index)", "row \(index)")], for: "chat-\(index)")
        }
        _ = await cache.storeBots((0 ..< 60).map { bot("chat-\($0)") })
        _ = await cache.storePreviews((0 ..< 60).reduce(into: [String: CachedPreview]()) { rows, index in
            rows["chat-\(index)"] = CachedPreview(text: "row \(index)",
                                                  timestamp: 1_760_000_000 + Double(index))
        })

        let usage = await cache.usage()
        XCTAssertLessThanOrEqual(usage.count(.chatList), 25)
        XCTAssertLessThanOrEqual(usage.chatCount, 25)
        XCTAssertGreaterThan(usage.count(.chatList), 0)
        let chatListFile = cache.directory.appendingPathComponent("chat-list/chat-list.json")
        let storedDocument = try JSONDecoder().decode(CachedChatList.self,
                                                     from: Data(contentsOf: chatListFile))
        XCTAssertEqual(usage.count(.chatList), storedDocument.bots.count,
                       "the Usage row counts the rows the file holds")
        XCTAssertEqual(documents(in: cache.directory.appendingPathComponent("messages")).count,
                       usage.chatCount)
    }

    func testUsageDropsToZeroAfterAReset() async throws {
        let cache = await store()
        _ = await cache.storeBots([bot("cody")])
        _ = await cache.storeMessages([message("a1", "hello")], for: "chat-a")
        await cache.reset()

        let usage = await cache.usage()
        XCTAssertEqual(usage.totalBytes, 0)
        XCTAssertEqual(usage.count(.messages), 0)
        XCTAssertEqual(usage.count(.chatList), 0)
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
        let names = documents(in: cache.directory.appendingPathComponent("messages")).map(\.lastPathComponent)
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
        XCTAssertEqual(CacheFormat.count(1, .chatList), "1 chat")
        XCTAssertEqual(CacheFormat.count(100, .chatList), "100 chats")

        // The one string both Caching surfaces draw for a Usage row.
        let usage = CacheUsage(sections: [
            .chatList: .init(bytes: 2_400_000, count: 100),
            .messages: .init(bytes: 512, count: 1),
        ], chatCount: 100)
        XCTAssertEqual(CacheFormat.detail(for: .chatList, in: usage), "100 chats · 2.4 MB")
        XCTAssertEqual(CacheFormat.detail(for: .messages, in: usage), "1 message · 512 B")
        XCTAssertEqual(CacheFormat.detail(for: .filesAndLinks, in: usage), "0 items · 0 B")
        XCTAssertEqual(CacheChatLimit.options.map(CacheChatLimit.label),
                       ["25 chats", "100 chats", "500 chats"])
    }
}
