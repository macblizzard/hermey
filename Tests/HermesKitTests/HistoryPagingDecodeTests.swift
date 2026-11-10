import XCTest
@testable import HermesKit

/// The decoder side of transcript paging.
///
/// The host ships a conversation's newest page and names the offset it starts at; older pages come
/// back with their own offset. Two things must hold or the UI shows the wrong thing: the cursor has
/// to survive decoding, and rows without a durable id must not collide across pages (two pages both
/// starting at "user-0" would fight each other in the list).
final class HistoryPagingDecodeTests: XCTestCase {

    private func row(_ role: String, _ text: String) -> JSONValue {
        .object(["role": .string(role), "text": .string(text)])
    }

    func testResumeReadsThePageCursorAndTotalAndOffsetsFallbackIds() throws {
        let result = JSONValue.object([
            "session_id": .string("rt-1"),
            "stored_session_id": .string("stored-1"),
            "message_count": .int(50),
            "messages": .array([row("user", "older"), row("assistant", "newer")]),
            "history": .object(["total": .int(50), "shown": .int(2), "cursor": .int(48)]),
        ])

        let resume = try GatewayPayloadDecoder.sessionResume(result, requestedID: "stored-1")

        XCTAssertEqual(resume.resume.earlierCursor, 48)
        XCTAssertEqual(resume.resume.historyTotal, 50)
        XCTAssertEqual(resume.resume.entries.map(\.text), ["older", "newer"])
        XCTAssertEqual(resume.resume.entries.map(\.id), ["user-48", "assistant-49"],
                       "a page's positional ids carry its offset, so two pages cannot collide")
    }

    func testShortResumeWithoutHistoryMetadataIsTheWholeTranscript() throws {
        let result = JSONValue.object([
            "session_id": .string("rt-1"),
            "messages": .array([row("user", "only")]),
        ])
        let resume = try GatewayPayloadDecoder.sessionResume(result, requestedID: "stored-1")
        XCTAssertNil(resume.resume.earlierCursor, "no cursor means nothing older to load")
        XCTAssertEqual(resume.resume.entries.first?.id, "user-0")
    }

    func testHistoryPageDecodesRowsAndNextCursor() throws {
        let result = JSONValue.object([
            "messages": .array([row("user", "oldest"), row("assistant", "middle")]),
            "cursor": .int(10),
            "total": .int(12),
        ])
        let page = try GatewayPayloadDecoder.historyPage(result)
        XCTAssertEqual(page.cursor, 10)
        XCTAssertEqual(page.total, 12)
        XCTAssertEqual(page.entries.map(\.id), ["user-10", "assistant-11"])
    }

    func testHistoryPageReachingTheStartHasNoCursor() throws {
        let result = JSONValue.object([
            "messages": .array([row("user", "first")]),
            "cursor": .null,
            "total": .int(1),
        ])
        let page = try GatewayPayloadDecoder.historyPage(result)
        XCTAssertNil(page.cursor)
        XCTAssertEqual(page.entries.first?.id, "user-0")
    }

    func testHistoryPageWithoutMessagesIsAMalformedAnswer() {
        XCTAssertThrowsError(try GatewayPayloadDecoder.historyPage(.object([:])))
    }
}
