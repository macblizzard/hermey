import XCTest
@testable import HermesKit

/// Turning tool calls off must remove the cards from the chat — that was the bug: the switch used to
/// hide only a card's body, so the cards stayed and the setting looked broken.
final class TranscriptVisibilityTests: XCTestCase {

    private func entry(_ id: String, _ role: TranscriptEntry.Role, _ text: String = "") -> TranscriptEntry {
        TranscriptEntry(id: id, role: role, text: text,
                        tool: role == .tool ? .init(name: "terminal", context: "ls") : nil)
    }

    private var conversation: [TranscriptEntry] {
        [entry("u1", .user, "book me a flight"),
         entry("t1", .tool),
         entry("a1", .assistant, "checking"),
         entry("t2", .tool),
         entry("r1", .reasoning, "the bot thought"),
         entry("a2", .assistant, "done")]
    }

    func testToolRowsAreHiddenWhenToolCallsAreOff() {
        let visible = TranscriptVisibility.rows(conversation, showToolCalls: false)
        XCTAssertEqual(visible.map(\.id), ["u1", "a1", "r1", "a2"])
        XCTAssertFalse(visible.contains { $0.role == .tool })
    }

    func testEveryRowSurvivesWhenToolCallsAreOn() {
        let visible = TranscriptVisibility.rows(conversation, showToolCalls: true)
        XCTAssertEqual(visible.map(\.id), conversation.map(\.id))
    }

    func testHidingCardsNeverDisturbsTheRowsAroundThem() {
        // The user's own message, the commentary and the answer keep their order and content; only
        // the cards leave. A filter that dropped or reordered a neighbour would be a worse bug than
        // the one being fixed.
        let visible = TranscriptVisibility.rows(conversation, showToolCalls: false)
        XCTAssertEqual(visible.first?.role, .user)
        XCTAssertEqual(visible.last?.role, .assistant)
        XCTAssertEqual(visible.first(where: { $0.id == "a1" })?.text, "checking")
    }

    func testTheRunningTurnsCardsFollowTheSameSwitch() {
        XCTAssertTrue(TranscriptVisibility.showsLiveCards(showToolCalls: true, hasLiveTools: true))
        XCTAssertFalse(TranscriptVisibility.showsLiveCards(showToolCalls: false, hasLiveTools: true))
        // Nothing running: no card either way, and no empty gap where one would be.
        XCTAssertFalse(TranscriptVisibility.showsLiveCards(showToolCalls: true, hasLiveTools: false))
    }

    func testAConversationOfNothingButCardsBecomesEmpty() {
        let onlyCards = [entry("t1", .tool), entry("t2", .tool)]
        XCTAssertTrue(TranscriptVisibility.rows(onlyCards, showToolCalls: false).isEmpty)
    }
}
