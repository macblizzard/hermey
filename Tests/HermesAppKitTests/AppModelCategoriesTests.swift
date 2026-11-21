#if canImport(Combine)
import Foundation
import XCTest
@testable import HermesAppKit
import HermesKit

/// Categories are host state: both apps read the same document, write through to it, and keep only
/// a read cache so a launch with no wire still draws the groups.
///
/// The regression these pin: the group was created on the phone and never appeared on the Mac,
/// because nothing on the Mac ever asked the host for the document.
@MainActor
final class AppModelCategoriesTests: XCTestCase {

    private func hostName(_ label: String) -> String {
        "categories-\(label)-\(UUID().uuidString)"
    }

    private func cacheKey(_ host: String) -> String { "hermes.botCategories.\(host)" }

    private func document(_ names: [String], assignments: [String: String] = [:]) -> BotCategoryState {
        BotCategoryState(
            categories: names.enumerated().map { index, name in
                BotCategory(id: "cat-\(index + 1)", name: name)
            },
            assignments: assignments)
    }

    /// The Mac's connect path is `AppModel.start()`; before this, it read the roster and stopped.
    func testConnectReadsTheGroupsTheOtherDeviceMade() async {
        let host = hostName("connect")
        defer { UserDefaults.standard.removeObject(forKey: cacheKey(host)) }
        let scripted = ScriptedHost(session: "s1")
        scripted.categoryState = document(["Work"], assignments: ["cody": "cat-1"])
        let model = AppModel(client: scripted, hostName: host)

        await model.start()
        XCTAssertEqual(model.botCategories.map(\.name), ["Work"])
        XCTAssertEqual(model.categoryID(for: "cody"), "cat-1")
        XCTAssertGreaterThanOrEqual(scripted.categoryReads, 1)
        await model.stop()
    }

    func testAWriteGoesToTheHostAndIsConfirmedByARead() async throws {
        let host = hostName("write")
        defer { UserDefaults.standard.removeObject(forKey: cacheKey(host)) }
        let scripted = ScriptedHost(session: "s1")
        let model = AppModel(client: scripted, hostName: host)
        await model.start()
        let readsBefore = scripted.categoryReads

        try await model.addBotCategory(name: "Work")

        XCTAssertEqual(scripted.categoryWrites, ["create:Work"],
                       "the create crossed the client boundary; a local-only list is the bug")
        XCTAssertEqual(model.botCategories.map(\.name), ["Work"])
        XCTAssertGreaterThan(scripted.categoryReads, readsBefore,
                             "a write is settled against the host, not trusted from its own answer")
        await model.stop()
    }

    func testFilingABotGoesThroughAndClearingItPutsTheBotBack() async throws {
        let host = hostName("assign")
        defer { UserDefaults.standard.removeObject(forKey: cacheKey(host)) }
        let scripted = ScriptedHost(session: "s1")
        scripted.categoryState = document(["Work"])
        let model = AppModel(client: scripted, hostName: host)
        await model.start()

        try await model.setBotCategory("cody", to: "cat-1")
        XCTAssertEqual(scripted.categoryWrites, ["assign:cody:cat-1"])
        XCTAssertEqual(model.categoryID(for: "cody"), "cat-1")

        try await model.setBotCategory("cody", to: nil)
        XCTAssertEqual(scripted.categoryWrites, ["assign:cody:cat-1", "assign:cody:-"])
        XCTAssertNil(model.categoryID(for: "cody"))
        await model.stop()
    }

    /// A change made on the phone while this app is open: the next refresh has to see it, and the
    /// refresh is exactly what the Mac does after a write.
    func testARefreshSeesWhatTheOtherDeviceDid() async {
        let host = hostName("refresh")
        defer { UserDefaults.standard.removeObject(forKey: cacheKey(host)) }
        let scripted = ScriptedHost(session: "s1")
        let model = AppModel(client: scripted, hostName: host)
        await model.start()
        XCTAssertTrue(model.botCategories.isEmpty)

        scripted.categoryState = document(["Home"], assignments: ["aria": "cat-1"])
        await model.loadBotCategories()

        XCTAssertEqual(model.botCategories.map(\.name), ["Home"])
        XCTAssertEqual(model.categoryID(for: "aria"), "cat-1")
        await model.stop()
    }

    /// Offline is a read-only cache: the list still draws the groups, and nothing claims a write
    /// landed that the host never saw.
    func testTheCacheDrawsTheGroupsWithNoHost() async {
        let host = hostName("cache")
        defer { UserDefaults.standard.removeObject(forKey: cacheKey(host)) }

        let online = ScriptedHost(session: "s1")
        online.categoryState = document(["Work", "Home"], assignments: ["cody": "cat-2"])
        let first = AppModel(client: online, hostName: host)
        await first.start()
        await first.stop()

        let offline = ScriptedHost(session: "s1")
        offline.categoryError = URLError(.notConnectedToInternet)
        let reopened = AppModel(client: offline, hostName: host)

        XCTAssertEqual(reopened.botCategories.map(\.name), ["Work", "Home"],
                       "the last document the host answered with is drawn before any wire")
        XCTAssertEqual(reopened.categoryID(for: "cody"), "cat-2")

        await reopened.start()   // the host refuses; the cache is what stands
        XCTAssertEqual(reopened.botCategories.map(\.name), ["Work", "Home"],
                       "a failed read is not an empty document")
        await reopened.stop()
    }

    func testAFailedWriteLeavesTheScreenAsItWas() async {
        let host = hostName("refused")
        defer { UserDefaults.standard.removeObject(forKey: cacheKey(host)) }
        let scripted = ScriptedHost(session: "s1")
        scripted.categoryState = document(["Work"])
        let model = AppModel(client: scripted, hostName: host)
        await model.start()

        scripted.categoryError = URLError(.cannotConnectToHost)
        do {
            try await model.addBotCategory(name: "Home")
            XCTFail("a refused write must throw, so the app can say so")
        } catch {
            XCTAssertEqual(model.botCategories.map(\.name), ["Work"],
                           "a write the host never took must not appear on screen")
        }
        await model.stop()
    }

    /// Two category writes in a row: the earlier read's answer must not publish over the later
    /// write, or the list would flick back to the document the person just changed.
    func testASlowReadDoesNotOverwriteANewerWrite() async throws {
        let host = hostName("overtake")
        defer { UserDefaults.standard.removeObject(forKey: cacheKey(host)) }
        let scripted = ScriptedHost(session: "s1")
        let model = AppModel(client: scripted, hostName: host)
        await model.start()

        scripted.categoryReadDelay = .milliseconds(300)
        let slowRead = Task { await model.loadBotCategories() }
        try? await Task.sleep(for: .milliseconds(50))   // the read is in flight, answering "empty"
        scripted.categoryReadDelay = nil

        try await model.addBotCategory(name: "Work")
        await slowRead.value

        XCTAssertEqual(model.botCategories.map(\.name), ["Work"],
                       "the late answer for the older document was dropped")
        await model.stop()
    }

    func testOneHostsGroupsNeverAppearOnAnother() async {
        let firstHost = hostName("one")
        let secondHost = hostName("two")
        defer {
            UserDefaults.standard.removeObject(forKey: cacheKey(firstHost))
            UserDefaults.standard.removeObject(forKey: cacheKey(secondHost))
        }

        let firstScripted = ScriptedHost(session: "s1")
        firstScripted.categoryState = document(["Work"])
        let first = AppModel(client: firstScripted, hostName: firstHost)
        await first.start()
        await first.stop()

        let second = AppModel(client: ScriptedHost(session: "s1"), hostName: secondHost)
        XCTAssertTrue(second.botCategories.isEmpty, "the cache is per host, like the file it mirrors")
        await second.stop()
    }
}
#endif

/// Arranging the groups from the Mac's context menu: the order is the host's, and "up" means the
/// group drawn above the one you right-clicked.
@MainActor
final class BotCategoryOrderTests: XCTestCase {

    private func hostName(_ label: String) -> String {
        "category-order-\(label)-\(UUID().uuidString)"
    }

    private func cacheKey(_ host: String) -> String { "hermes.botCategories.\(host)" }

    private func state(_ names: [String], order: [String] = []) -> BotCategoryState {
        BotCategoryState(
            categories: names.enumerated().map { index, name in
                BotCategory(id: "cat-\(index + 1)", name: name)
            },
            assignments: [:],
            order: order)
    }

    private func categoryNames(_ model: AppModel) -> [String] {
        model.botGroups.filter { !$0.isPinned && !$0.isUncategorized }.map(\.name)
    }

    func testAnUnarrangedListIsStillAlphabetical() {
        let state = state(["Zebra", "Apple", "Mango"])
        let groups = BotGrouping.groups(bots: [], state: state, pinned: [])
        XCTAssertEqual(groups.map(\.name), ["Apple", "Mango", "Zebra", "Uncategorized"])
    }

    func testTheArrangementWinsOverTheAlphabet() {
        let state = state(["Zebra", "Apple", "Mango"], order: ["cat-1", "cat-3", "cat-2"])
        let groups = BotGrouping.groups(bots: [], state: state, pinned: [])
        XCTAssertEqual(groups.map(\.name), ["Zebra", "Mango", "Apple", "Uncategorized"])
    }

    func testAGroupTheArrangementHasNotSeenKeepsItsAlphabeticalPlace() {
        // A category created on the phone since this Mac last read the document: it must not jump
        // to the end, and it must not be dropped.
        let state = state(["Zebra", "Apple", "Mango"], order: ["cat-1"])
        let groups = BotGrouping.groups(bots: [], state: state, pinned: [])
        XCTAssertEqual(groups.map(\.name), ["Zebra", "Apple", "Mango", "Uncategorized"])
    }

    func testMovingAGroupUpSendsTheWholeArrangementAndTheListFollows() async throws {
        let host = hostName("up")
        defer { UserDefaults.standard.removeObject(forKey: cacheKey(host)) }
        let scripted = ScriptedHost(session: "s1")
        scripted.categoryState = state(["Alpha", "Beta", "Gamma"])
        let model = AppModel(client: scripted, hostName: host)
        await model.start()
        XCTAssertEqual(categoryNames(model), ["Alpha", "Beta", "Gamma"])

        try await model.moveBotCategory(id: "cat-3", by: -1)

        XCTAssertEqual(categoryNames(model), ["Alpha", "Gamma", "Beta"])
        XCTAssertTrue(scripted.categoryWrites.contains("order:cat-1,cat-3,cat-2"),
                      "the arrangement should be sent whole: \(scripted.categoryWrites)")
        await model.stop()
    }

    func testMovingPastEitherEndDoesNothing() async throws {
        let host = hostName("ends")
        defer { UserDefaults.standard.removeObject(forKey: cacheKey(host)) }
        let scripted = ScriptedHost(session: "s1")
        scripted.categoryState = state(["Alpha", "Beta"])
        let model = AppModel(client: scripted, hostName: host)
        await model.start()

        XCTAssertFalse(model.canMoveBotCategory(id: "cat-1", by: -1))
        XCTAssertFalse(model.canMoveBotCategory(id: "cat-2", by: 1))
        XCTAssertTrue(model.canMoveBotCategory(id: "cat-2", by: -1))
        XCTAssertTrue(model.canMoveBotCategory(id: "cat-1", by: 1))

        try await model.moveBotCategory(id: "cat-1", by: -1)
        try await model.moveBotCategory(id: "cat-2", by: 1)
        XCTAssertEqual(categoryNames(model), ["Alpha", "Beta"])
        XCTAssertTrue(scripted.categoryWrites.isEmpty, "nothing should reach the host: \(scripted.categoryWrites)")
        await model.stop()
    }

    /// Pinned and Uncategorized are the app's headings, not the owner's categories: a control that
    /// could move one would send the host an id its document never holds. Both the gate the menu
    /// greys out with and the write itself have to agree about that.
    func testTheAppsOwnHeadingsAreNotInTheArrangement() async throws {
        let host = hostName("reserved")
        defer { UserDefaults.standard.removeObject(forKey: cacheKey(host)) }
        let scripted = ScriptedHost(session: "s1")
        scripted.categoryState = state(["Alpha", "Beta"])
        let model = AppModel(client: scripted, hostName: host)
        await model.start()

        XCTAssertFalse(model.canMoveBotCategory(id: BotGrouping.uncategorizedID, by: -1))
        XCTAssertFalse(model.canMoveBotCategory(id: BotGrouping.pinnedID, by: 1))

        try await model.moveBotCategory(id: BotGrouping.uncategorizedID, by: -1)
        try await model.moveBotCategory(id: BotGrouping.pinnedID, by: 1)

        XCTAssertTrue(scripted.categoryWrites.isEmpty,
                      "the host was asked to arrange a heading it does not own: \(scripted.categoryWrites)")
        await model.stop()
    }

    /// A move is a host write. When it is refused the arrangement must not appear to have changed,
    /// and the error has to reach the view — the Mac's menu used to swallow it with `try?`.
    func testARefusedMoveThrowsAndTheOrderStands() async throws {
        let host = hostName("refused-move")
        defer { UserDefaults.standard.removeObject(forKey: cacheKey(host)) }
        let scripted = ScriptedHost(session: "s1")
        scripted.categoryState = state(["Alpha", "Beta"])
        let model = AppModel(client: scripted, hostName: host)
        await model.start()

        scripted.categoryError = URLError(.cannotConnectToHost)
        do {
            try await model.moveBotCategory(id: "cat-2", by: -1)
            XCTFail("a refused move must throw, so the app can say so")
        } catch {
            XCTAssertEqual(categoryNames(model), ["Alpha", "Beta"],
                           "a move the host never took must not appear on screen")
        }
        XCTAssertTrue(scripted.categoryWrites.isEmpty)
        await model.stop()
    }

    func testCachedDocumentsFromBeforeOrderingStillLoad() throws {
        // The apps cache the document on disk; a cache written before `order` existed has no key.
        let json = #"{"categories":[{"id":"cat-1","name":"Work","createdAt":null}],"assignments":{}}"#
        let decoded = try JSONDecoder().decode(BotCategoryState.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.order, [])
        XCTAssertEqual(decoded.categories.map(\.name), ["Work"])
    }
}
