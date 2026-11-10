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

    func testWordlessAssistantRowsAreNotRows() {
        // The host writes an assistant row with no text as a banner for the commands that follow.
        // With the cards hidden it survives as an empty bubble and a lone timestamp — the "blank
        // lines with timestamps" from the report — and with them shown it is an empty bubble above
        // its own cards. It is not a message either way.
        let entries = [entry("u1", .user, "book me a flight"),
                       entry("banner", .assistant, "   \n "),
                       entry("t1", .tool),
                       entry("a1", .assistant, "on it")]
        let hidden = TranscriptVisibility.rows(entries, showToolCalls: false)
        XCTAssertEqual(hidden.map(\.id), ["u1", "a1"])
        let shown = TranscriptVisibility.rows(entries, showToolCalls: true)
        XCTAssertEqual(shown.map(\.id), ["u1", "t1", "a1"])
        XCTAssertFalse(TranscriptVisibility.hasContent(entries[1]))
    }

    func testAMessageWithOnlyAPictureStillHasContent() {
        let picture = TranscriptEntry(id: "img", role: .assistant, text: "  ",
                                      attachments: [SentAttachment(id: "a", name: "shot.png", isImage: true)])
        XCTAssertTrue(TranscriptVisibility.hasContent(picture))
        XCTAssertEqual(TranscriptVisibility.rows([picture], showToolCalls: false).map(\.id), ["img"])
    }

    func testAConversationOfNothingButCardsBecomesEmpty() {
        let onlyCards = [entry("t1", .tool), entry("t2", .tool)]
        XCTAssertTrue(TranscriptVisibility.rows(onlyCards, showToolCalls: false).isEmpty)
    }
}
