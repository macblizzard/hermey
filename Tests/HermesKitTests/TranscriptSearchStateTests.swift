import XCTest
@testable import HermesKit

/// The Mac transcript's search state: the doors, the cursor and the scroll it owns.
///
/// `ConversationSearchTests` already holds the matcher's contract. These cases hold the glue the
/// desktop put around it, which is where the three doors (⌘F, the bot panel row, the Conversation
/// menu) can disagree with each other, and where auto-follow used to scroll the transcript away
/// from the row the reader had just jumped to.
final class TranscriptSearchStateTests: XCTestCase {

    /// The transcript the Mac hands the matcher: ids in reading order.
    private let conversation = ["u1", "a1", "t1", "u2", "a2"]

    private func opened(_ query: String = "") -> TranscriptSearchState {
        var state = TranscriptSearchState()
        state.open()
        state.query = query
        state.reconcile(count: query.isEmpty ? 0 : 3)
        return state
    }

    // MARK: - The doors

    func testItStartsClosedAndSilent() {
        let state = TranscriptSearchState()
        XCTAssertFalse(state.isOpen)
        XCTAssertFalse(state.isActive)
        XCTAssertFalse(state.ownsScrollPosition)
        XCTAssertEqual(state.status(matched: 0), "", "a closed bar says nothing")
        XCTAssertNil(state.selected(in: conversation), "a closed bar highlights nothing")
    }

    func testTheSecondDoorDoesNotWipeTheQuery() {
        // ⌘F, then the bot panel row, then the menu: three doors, one bar. A second press has to
        // re-focus the field, not throw away the half-typed query.
        var state = opened("vault")
        state.step(by: 1, count: 3)
        state.open()
        XCTAssertEqual(state.query, "vault")
        XCTAssertEqual(state.index, 1, "re-opening must not move the cursor off the reader's result")
    }

    func testClosingClearsTheFieldTheAnswerAndTheCursor() {
        var state = opened("vault")
        state.step(by: 1, count: 3)
        state.close()

        XCTAssertFalse(state.isOpen)
        XCTAssertEqual(state.query, "")
        XCTAssertEqual(state.index, 0)
        XCTAssertEqual(state.status(matched: 3), "", "the count must not survive the bar")
        XCTAssertNil(state.selected(in: conversation))
    }

    func testAConversationChangeClosesTheBar() {
        // The query described rows that are no longer on screen. Reopening must not answer it for
        // the new bot's transcript.
        var state = opened("vault")
        state.resetForConversationChange()
        XCTAssertFalse(state.isOpen)
        XCTAssertEqual(state.query, "")
    }

    // MARK: - Owning the scroll

    func testAnOpenBarOwnsTheScrollEvenWithAnEmptyField() {
        // The window between ⌘F and the first keystroke: a streaming token landing then used to
        // pull the transcript to the bottom, under the field the reader had just opened.
        var state = TranscriptSearchState()
        state.open()
        XCTAssertTrue(state.ownsScrollPosition)
        XCTAssertFalse(state.isActive, "an empty field is not a query")
    }

    func testClosingGivesTheScrollBack() {
        var state = opened("vault")
        XCTAssertTrue(state.ownsScrollPosition)
        state.close()
        XCTAssertFalse(state.ownsScrollPosition)
    }

    // MARK: - The cursor

    func testTypingPutsTheCursorBackOnTheFirstResult() {
        var state = opened("vault")
        state.step(by: 1, count: 3)
        XCTAssertEqual(state.index, 1)
        state.query = "vault holds"
        XCTAssertEqual(state.index, 0, "a new answer is a new list; the old position in it means nothing")
    }

    func testRetypingTheSameTextDoesNotJump() {
        // `didSet` fires on assignment, not on change: an idempotent binding write from SwiftUI must
        // not keep the reader from ever reaching the second result.
        var state = opened("vault")
        state.step(by: 1, count: 3)
        state.query = "vault"
        XCTAssertEqual(state.index, 1)
    }

    func testANarrowerAnswerClampsTheCursorOntoAMatch() {
        // `1 of 3`, then the third keystroke leaves one row: the count must read `1 of 1`, not
        // `3 of 1`, and the highlight must land on the row that still matches.
        var state = opened("vault")
        state.step(by: 1, count: 3)
        state.step(by: 1, count: 3)
        XCTAssertEqual(state.index, 2)
        XCTAssertEqual(state.status(matched: 3), "3 of 3")

        state.reconcile(count: 1)
        XCTAssertEqual(state.index, 0)
        XCTAssertEqual(state.status(matched: 1), "1 of 1")
        XCTAssertEqual(state.selected(in: ["a2"]), "a2")
    }

    func testAnEmptiedAnswerLeavesNoCursorAndNoHighlight() {
        var state = opened("leak")
        state.reconcile(count: 0)
        XCTAssertEqual(state.index, 0)
        XCTAssertNil(state.selected(in: []))
        XCTAssertEqual(state.status(matched: 0), "No matches for “leak”",
                       "the empty answer names the query, so a mistyped word is not a silent field")
    }

    func testSteppingWrapsInBothDirections() {
        var state = opened("vault")
        state.step(by: -1, count: 3)
        XCTAssertEqual(state.index, 2, "previous from the first result wraps to the last")
        state.step(by: 1, count: 3)
        XCTAssertEqual(state.index, 0, "next from the last wraps to the first")
    }

    func testSteppingWithNoMatchesIsDefinedRatherThanFatal() {
        var state = opened("nothing here at all")
        state.reconcile(count: 0)
        state.step(by: 1, count: 0)
        state.step(by: -1, count: 0)
        XCTAssertEqual(state.index, 0)
        XCTAssertNil(state.selected(in: []))
    }

    func testTheSelectionFollowsTheCursorThroughTheAnswer() {
        var state = opened("vault")
        let ids = ["u1", "a1", "a2"]
        XCTAssertEqual(state.selected(in: ids), "u1")
        state.step(by: 1, count: ids.count)
        XCTAssertEqual(state.selected(in: ids), "a1")
        state.step(by: 1, count: ids.count)
        XCTAssertEqual(state.selected(in: ids), "a2")
    }

    // MARK: - The count beside the field

    func testTheCountIsTheMatchersOwnSentence() {
        var state = opened("vault")
        XCTAssertEqual(state.status(matched: 3), ConversationSearch.status(query: "vault",
                                                                          matched: 3,
                                                                          index: 0))
        state.step(by: 1, count: 3)
        XCTAssertEqual(state.status(matched: 3), "2 of 3")
    }

    func testAnInactiveQuerySaysNothingEvenIfAStaleCountArrives() {
        var state = TranscriptSearchState()
        state.open()
        XCTAssertEqual(state.status(matched: 4), "", "an empty field must not read `1 of 4`")
    }

    // MARK: - End to end with the one matcher

    func testTheStateNeverPointsPastTheMatchersAnswer() {
        // The Mac's real sequence: matches come from `ConversationSearch.ids`, and every change is
        // reconciled through the state. Walk a query one keystroke at a time and assert the cursor
        // is always on a row the current answer contains.
        let rows = [
            (id: "u1", text: "open the CrowdSec panel and check the bans"),
            (id: "a1", text: "The CrowdSec rules are loaded; two bans are active."),
            (id: "t1", text: "terminal · docker logs crowdsec"),
            (id: "a3", text: "unrelated: the café on the corner résumé"),
        ]

        var state = TranscriptSearchState()
        state.open()
        var previousCount = Int.max
        var lastIDs: [String] = []
        for prefix in ["c", "cr", "cro", "crow", "crowd", "crowdsec"] {
            state.query = prefix
            let ids = ConversationSearch.ids(matching: state.query,
                                             in: rows,
                                             id: \.id,
                                             text: \.text,
                                             extra: (id: "streaming", text: "CrowdSec is watching"))
            state.reconcile(count: ids.count)
            lastIDs = ids
            XCTAssertFalse(ids.isEmpty, "\(prefix.debugDescription) lost every match")
            if let selected = state.selected(in: ids) {
                XCTAssertTrue(ids.contains(selected))
            } else {
                XCTFail("\(prefix.debugDescription) left no row selected")
            }
            XCTAssertLessThanOrEqual(ids.count, previousCount,
                                     "\(prefix.debugDescription) grew the answer on a keystroke")
            previousCount = ids.count
        }

        // The live turn is part of the answer, so the reader can land on what they are watching.
        XCTAssertEqual(lastIDs.last, "streaming")
        XCTAssertEqual(state.status(matched: lastIDs.count), "1 of \(lastIDs.count)")
    }
}
