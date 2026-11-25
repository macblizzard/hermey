import XCTest
@testable import HermesKit

/// The clamp, held to the two shapes that froze the app on 0.1.670.
///
/// Both were reported with a screenshot: a bot's reply whose every identifier is inline code, and
/// the `[ASYNC DELEGATION BATCH COMPLETE …]` system row of the same size. Neither was a 20,000-line
/// log, which is why the old 4,000-character / 60-line threshold missed them: they were long enough
/// to be styled one `AttributedString` run per identifier, and the styling — not the length — is
/// what the main thread could not do while scrolling.
final class TranscriptClampTests: XCTestCase {

    /// The reply from the screenshot: dense inline code, about six thousand characters.
    ///
    /// Written the way the real one read — an identifier, then another, then a command in backticks —
    /// because the count that matters is *spans*, not words.
    private func denseText(spans: Int = 200, prefix: String = "") -> String {
        var text = prefix
        var index = 0
        while index < spans {
            text += "The `display_order` of `live_message_count` in `messages` is raised by "
            text += "`cargo test --bin hermeyd` and read by `test_the_per_chat_cap_is_raised` at "
            text += "`Sources/HermesKit/GatewayClient.swift:\(index)`, as before.\n"
            index += 4
        }
        return text
    }

    private func lines(_ text: String) -> Int {
        text.components(separatedBy: "\n").count
    }

    // MARK: The two reported shapes

    func testTheDenseAssistantReplyCollapses() {
        let reply = denseText()
        XCTAssertGreaterThan(reply.count, 5_000, "the fixture has to be the size of the report")

        guard case .preview(let preview) = TranscriptClamp.plan(.init(text: reply)) else {
            return XCTFail("a 200-span reply must collapse")
        }
        XCTAssertEqual(preview.reason, .inlineCode, "spans are what this body trips on")
        XCTAssertEqual(preview.spansStyled, 0, "the collapsed row styles nothing")
        XCTAssertLessThanOrEqual(preview.characters, TranscriptClamp.maxBodyCharacters)
        XCTAssertGreaterThan(preview.hiddenLines, 0, "the button has work to offer")
        XCTAssertEqual(preview.totalLines, lines(reply), "the count comes from the body")
    }

    func testTheDelegationSystemRowCollapses() {
        let header = "[ASYNC DELEGATION BATCH COMPLETE — deleg_9f2c1a]\n"
        let row = denseText(prefix: header)
        guard case .preview(let preview) = TranscriptClamp.plan(.init(text: row)) else {
            return XCTFail("a delegation row is a body and must collapse")
        }
        XCTAssertLessThanOrEqual(preview.characters, TranscriptClamp.maxBodyCharacters)
        XCTAssertGreaterThan(preview.hiddenLines, 0)
        XCTAssertTrue(preview.text.hasPrefix("[ASYNC DELEGATION BATCH COMPLETE"))
    }

    // MARK: The thresholds

    func testFiftyLinesIsNotLongAndFiftyOneIs() {
        let fifty = (1...50).map { "line \($0)" }.joined(separator: "\n")
        let fiftyOne = (1...51).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(TranscriptClamp.maxBodyLines, 50)
        XCTAssertFalse(TranscriptClamp.isLong(fifty))
        XCTAssertTrue(TranscriptClamp.isLong(fiftyOne))
    }

    func testAPathologicalSingleLineIsCutByTheCharacterBudget() {
        // One paragraph, six thousand characters, no newline to count: the line rule cannot see it.
        let oneLine = String(repeating: "the run said something it had already said. ", count: 140)
        XCTAssertGreaterThan(oneLine.count, 6_000)
        XCTAssertEqual(lines(oneLine), 1)

        guard let preview = TranscriptClamp.preview(oneLine) else { return XCTFail("must clamp") }
        XCTAssertEqual(preview.reason, .characters)
        XCTAssertLessThanOrEqual(preview.characters, TranscriptClamp.maxBodyCharacters)
        XCTAssertEqual(preview.hiddenLines, 1, "its tail is hidden, so the line is")
        XCTAssertTrue(preview.text.hasSuffix("…"), "a cut line says it was cut")
    }

    func testOrdinaryWritingIsNotLong() {
        XCTAssertFalse(TranscriptClamp.isLong("Done. The vault is snapshotted."))
        XCTAssertFalse(TranscriptClamp.isLong(String(repeating: "x", count: 4_000)))
        // Thirty-nine code spans is a technical answer; the fortieth is the wall.
        let thirtyNine = (1...39).map { "`id_\($0)`" }.joined(separator: " and ")
        XCTAssertFalse(TranscriptClamp.isLong(thirtyNine))
        XCTAssertEqual(TranscriptClamp.inlineCodeSpanCount(in: thirtyNine), 39)
    }

    func testThePreviewShowsFiftyLinesAndCountsTheRest() {
        let sixty = (1...60).map { "log line \($0): the run said something again" }
            .joined(separator: "\n")
        guard let preview = TranscriptClamp.preview(sixty) else { return XCTFail("must clamp") }
        XCTAssertEqual(preview.shownLines, 50)
        XCTAssertEqual(preview.totalLines, 60)
        XCTAssertEqual(preview.hiddenLines, 10)
        XCTAssertEqual(preview.text.components(separatedBy: "\n").count, 50)
        XCTAssertFalse(preview.text.contains("log line 51"))
    }

    func testTheCountIsStableAcrossRepeats() {
        // The number beside the button is read from the body every time the row is drawn, so two
        // reads of the same text cannot disagree — a resize or a font step cannot strand it.
        let text = denseText()
        let first = TranscriptClamp.preview(text)
        let second = TranscriptClamp.preview(text)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first?.hiddenLines, second?.hiddenLines)
    }

    // MARK: What may skip the clamp

    func testOnlyTheEnumeratedSmallCardsAreExempt() {
        XCTAssertEqual(TranscriptClamp.smallStructuredCards,
                       ["approval", "draft-email", "infographic", "secure-entry"])

        // A card alone, with no prose of its own, keeps its form.
        XCTAssertEqual(TranscriptClamp.plan(.init(text: "\n ", cardKinds: ["approval"])), .whole)
        // Prose as well as a card is prose: it is clamped.
        if case .whole = TranscriptClamp.plan(.init(text: denseText(spans: 44),
                                                    cardKinds: ["approval"])) {
            XCTFail("a message with its own prose is clamped whatever card it names")
        }
        // A board is not on the list, and neither is a kind added tomorrow.
        XCTAssertFalse(TranscriptClamp.isSmallStructuredCard("blocks"))
        XCTAssertFalse(TranscriptClamp.isSmallStructuredCard("a2ui"))
        XCTAssertFalse(TranscriptClamp.isSmallStructuredCard("table"))
    }

    // MARK: The button

    func testTheButtonWording() {
        XCTAssertEqual(TranscriptClamp.showFullTitle(hiddenLines: 312),
                       "Show full message · 312 more lines")
        XCTAssertEqual(TranscriptClamp.showFullTitle(hiddenLines: 1),
                       "Show full message · 1 more line")
        XCTAssertEqual(TranscriptClamp.showFullTitle(hiddenLines: 0), "Show full message")
        XCTAssertEqual(TranscriptClamp.showLessTitle, "Show less")
    }

    // MARK: Remembering an opened row

    func testAnExpansionIsRememberedPerMessageAndBounded() {
        let store = ExpandedLongRows()
        store.insert("live:r3")
        store.insert("row:41")
        XCTAssertTrue(store.contains("live:r3"))
        XCTAssertFalse(store.contains("row:42"), "per message, not per transcript")

        store.remove("live:r3")
        XCTAssertFalse(store.contains("live:r3"))

        for index in 0..<(ExpandedLongRows.limit + 8) {
            store.insert("row:\(index)")
        }
        XCTAssertLessThanOrEqual(ExpandedLongRows.limit, 64)
        XCTAssertTrue(store.contains("row:\(ExpandedLongRows.limit + 7)"),
                      "the newest is kept")
        XCTAssertFalse(store.contains("row:0"), "the oldest is forgotten, which only costs a re-open")
    }

    // MARK: The stored text

    func testTheClampNeverDropsTheMessage() {
        // A display decision: the preview is built *from* the text, and the text is untouched. The
        // row's own copy still holds the whole message, which is what the actions copy.
        let reply = denseText()
        let preview = TranscriptClamp.preview(reply)
        XCTAssertNotNil(preview)
        XCTAssertLessThan(preview?.characters ?? 0, reply.count)
        XCTAssertEqual(reply, denseText(), "no in-place edit, ever")
    }
}
