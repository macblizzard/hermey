import XCTest
@testable import HermesKit

/// The bot list reads one response for two things — the row's third line and its badge — so the
/// decoder has to survive every shape the bridge may legitimately send.
final class BotPreviewFeedTests: XCTestCase {
    private func feed(_ json: String) -> BotPreviewFeed {
        BotPreviewFeed.decode(Data(json.utf8))
    }

    func testReadsRowsAndCountsFromOneAnswer() {
        let value = feed("""
        {"previews": {"atlas": {"text": "Brief received", "role": "assistant", "at": 1794e9}},
         "unread": {"atlas": 2}}
        """)

        XCTAssertEqual(value.previews["atlas"]?.text, "Brief received")
        XCTAssertEqual(value.previews["atlas"]?.role, "assistant")
        XCTAssertEqual(value.unread["atlas"], 2)
    }

    func testAnOlderBridgeAnswersRowsWithoutCounts() {
        // GET /v1/bots/previews: no `unread` key at all. The list must still draw.
        let value = feed("""
        {"previews": {"cody": {"text": "Done", "role": "assistant", "at": 1}}}
        """)

        XCTAssertEqual(value.previews.count, 1)
        XCTAssertTrue(value.unread.isEmpty)
    }

    func testBlankRowsAreDroppedAndZeroCountsAreNotCarried() {
        let value = feed("""
        {"previews": {"a": {"text": "   "}, "b": {"text": "real", "role": "user"}},
         "unread": {"a": 0, "b": 1}}
        """)

        XCTAssertNil(value.previews["a"], "a whitespace-only line is no line")
        XCTAssertEqual(value.previews["b"]?.text, "real")
        XCTAssertNil(value.unread["a"], "zero is the absence of a badge, not a badge saying 0")
        XCTAssertEqual(value.unread["b"], 1)
    }

    func testGarbageIsAnEmptyFeedNotACrash() {
        XCTAssertTrue(feed("not json").previews.isEmpty)
        XCTAssertTrue(feed("{}").unread.isEmpty)
        XCTAssertTrue(feed("[]").previews.isEmpty)
    }

    func testCountsArriveAsNumbersRatherThanStrings() {
        // JSON has one number type; a bridge that serialised from sqlite could send a float.
        let value = feed("""
        {"unread": {"a": 3, "b": 4.0}}
        """)

        XCTAssertEqual(value.unread["a"], 3)
        XCTAssertEqual(value.unread["b"], 4)
    }
}
