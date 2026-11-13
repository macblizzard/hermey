import XCTest
@testable import HermesKit

/// Keeping earlier pages across a resume.
///
/// A resume carries only the newest page, so a plain replacement dropped every page the reader had
/// walked back to — and "load earlier" looked broken, because the page it fetched was wiped by the
/// next reconnect seconds later.
final class TranscriptPagingTests: XCTestCase {
    private func row(_ id: String, _ role: TranscriptEntry.Role = .assistant) -> TranscriptEntry {
        TranscriptEntry(id: id, role: role, text: id)
    }

    func testOlderRowsAreKeptInFrontOfTheNewestPage() {
        // On screen: two earlier pages (a, b) then the newest page (c, d). The host re-sends c, d.
        let old = [row("a"), row("b"), row("c"), row("d")]
        let incoming = [row("c"), row("d")]
        let merged = TranscriptPaging.merge(keeping: old, incoming: incoming,
                                           incomingCursor: 2, oldCursor: 0)
        XCTAssertEqual(merged.entries.map(\.id), ["a", "b", "c", "d"])
        // The oldest row on screen is still `a`, so its cursor is the one to page from.
        XCTAssertEqual(merged.cursor, 0)
    }

    func testTheHostsCopyWinsFromTheJoinOnwards() {
        // A row edited on the host must not stay stale just because the app had a copy of it.
        let old = [row("a"), TranscriptEntry(id: "b", role: .assistant, text: "old text"), row("c")]
        let incoming = [TranscriptEntry(id: "b", role: .assistant, text: "new text"), row("c")]
        let merged = TranscriptPaging.merge(keeping: old, incoming: incoming,
                                            incomingCursor: 1, oldCursor: 0)
        XCTAssertEqual(merged.entries.map(\.text), ["a", "new text", "c"])
        XCTAssertEqual(merged.entries.count, 3)
    }

    func testNoRowAppearsTwice() {
        let old = [row("a"), row("b"), row("c")]
        let incoming = [row("b"), row("c")]
        let merged = TranscriptPaging.merge(keeping: old, incoming: incoming,
                                            incomingCursor: 1, oldCursor: 0)
        XCTAssertEqual(merged.entries.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(Set(merged.entries.map(\.id)).count, merged.entries.count)
    }

    func testADisjointPageReplacesRatherThanGuessing() {
        // A different conversation, or the same one after a rewind: no join, so the host wins.
        let old = [row("a"), row("b")]
        let incoming = [row("x"), row("y")]
        let merged = TranscriptPaging.merge(keeping: old, incoming: incoming,
                                            incomingCursor: 40, oldCursor: 0)
        XCTAssertEqual(merged.entries.map(\.id), ["x", "y"])
        XCTAssertEqual(merged.cursor, 40)
    }

    func testAnEmptyScreenTakesThePageAsItIs() {
        let merged = TranscriptPaging.merge(keeping: [], incoming: [row("a")],
                                            incomingCursor: 7, oldCursor: nil)
        XCTAssertEqual(merged.entries.map(\.id), ["a"])
        XCTAssertEqual(merged.cursor, 7)
    }

    func testTheNewestPageAloneKeepsItsOwnCursor() {
        // Nothing older was loaded, so the page's cursor is the offset to continue from.
        let merged = TranscriptPaging.merge(keeping: [row("c"), row("d")],
                                            incoming: [row("c"), row("d")],
                                            incomingCursor: 12, oldCursor: 12)
        XCTAssertEqual(merged.entries.map(\.id), ["c", "d"])
        XCTAssertEqual(merged.cursor, 12)
    }
}
