import XCTest
@testable import HermesKit

final class LastOpenedBotTests: XCTestCase {
    func testLastOpenedMovesFirstWithoutReorderingOthers() {
        let bots = [Bot(id: "a"), Bot(id: "b"), Bot(id: "c")]
        XCTAssertEqual(LastOpenedBot.order(bots, lastOpenedID: "c").map(\.id), ["c", "a", "b"])
    }

    func testMissingOrUnknownLastOpenedPreservesHostOrder() {
        let bots = [Bot(id: "a"), Bot(id: "b"), Bot(id: "c")]
        XCTAssertEqual(LastOpenedBot.order(bots, lastOpenedID: nil).map(\.id), ["a", "b", "c"])
        XCTAssertEqual(LastOpenedBot.order(bots, lastOpenedID: "gone").map(\.id), ["a", "b", "c"])
    }

    func testFilteringOrderedListPreservesOrderWhenLastOpenedDoesNotMatch() {
        let bots = [Bot(id: "a"), Bot(id: "b"), Bot(id: "c")]
        let filtered = LastOpenedBot.order(bots, lastOpenedID: "c").filter { $0.id != "c" }
        XCTAssertEqual(filtered.map(\.id), ["a", "b"])
    }
}
