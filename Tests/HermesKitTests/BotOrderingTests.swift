import XCTest
@testable import HermesKit

final class BotOrderingTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let bots = [Bot(id: "a"), Bot(id: "b"), Bot(id: "c"), Bot(id: "d")]

    func testMostRecentMessageFirst() {
        let order = BotOrdering.order(bots, activity: [
            "a": base, "b": base.addingTimeInterval(60), "d": base.addingTimeInterval(120),
        ])
        XCTAssertEqual(order.map(\.id), ["d", "b", "a", "c"])
    }

    func testPinnedOutranksRecencyAndKeepsActivityInsideTheGroup() {
        let order = BotOrdering.order(bots,
                                      activity: ["d": base.addingTimeInterval(500),
                                                 "a": base, "b": base.addingTimeInterval(10)],
                                      pinned: ["a", "b"])
        XCTAssertEqual(order.map(\.id), ["b", "a", "d", "c"])
    }

    func testHiddenBotsAreRemovedEntirely() {
        let order = BotOrdering.order(bots, activity: ["c": base], hidden: ["c"])
        XCTAssertEqual(order.map(\.id), ["a", "b", "d"])
    }

    func testHiddenPinnedBotStaysHidden() {
        let order = BotOrdering.order(bots, activity: [:], pinned: ["c"], hidden: ["c"])
        XCTAssertEqual(order.map(\.id), ["a", "b", "d"])
    }

    func testUnusedBotsKeepHostOrderAtTheBottom() {
        let order = BotOrdering.order(bots, activity: ["b": base])
        XCTAssertEqual(order.map(\.id), ["b", "a", "c", "d"])
    }

    func testEqualActivityFallsBackToHostOrder() {
        let order = BotOrdering.order(bots, activity: ["a": base, "b": base, "c": base, "d": base])
        XCTAssertEqual(order.map(\.id), ["a", "b", "c", "d"])
    }
}
