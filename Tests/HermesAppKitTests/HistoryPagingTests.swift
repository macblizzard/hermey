#if canImport(Combine)
import Foundation
import XCTest
@testable import HermesAppKit
import HermesKit

/// A long conversation must open, and then be readable backwards.
///
/// The host ships only its newest page (one 3.4 MB `session.resume` frame is a message iOS refuses
/// to deliver — "Message too long"), so `loadEarlierHistory` is the only way to read the rest. It
/// must extend the transcript, never duplicate or skip a row, and never lose the reader's place.
@MainActor
final class HistoryPagingTests: XCTestCase {

    private func entry(_ id: String, _ text: String, role: TranscriptEntry.Role = .user) -> TranscriptEntry {
        TranscriptEntry(id: id, role: role, text: text)
    }

    private func hostName(_ label: String) -> String { "paging-\(label)-\(UUID().uuidString)" }

    private func opened(_ label: String, entries: [TranscriptEntry],
                        earlierCursor: Int?, total: Int,
                        pages: [Int: HistoryPage] = [:]) async -> (AppModel, ScriptedHost) {
        let host = ScriptedHost(session: "stored-1", entries: entries)
        host.earlierCursor = earlierCursor
        host.historyTotal = total
        host.pages = pages
        let model = AppModel(client: host, hostName: hostName(label))
        await model.start()
        await model.select("stored-1")
        return (model, host)
    }

    func testResumeCarriesThePagingCursor() async {
        let (model, _) = await opened("cursor", entries: [entry("1", "newest")],
                                      earlierCursor: 7, total: 8)
        XCTAssertTrue(model.hasEarlierHistory, "seven rows behind the page means there is more to read")
        XCTAssertEqual(model.historyTotal, 8)
        await model.stop()
    }

    func testWholeTranscriptOffersNothingOlder() async {
        let (model, _) = await opened("whole", entries: [entry("1", "only")],
                                      earlierCursor: nil, total: 1)
        XCTAssertFalse(model.hasEarlierHistory)
        await model.loadEarlierHistory()
        XCTAssertEqual(model.transcript.count, 1, "no cursor means no request, not an empty page request")
        await model.stop()
    }

    func testLoadingEarlierPrependsThePageAndMovesTheCursorBack() async {
        let newest = entry("10", "newest")
        let older = [entry("8", "older"), entry("9", "middle")]
        let (model, host) = await opened("prepend", entries: [newest], earlierCursor: 8, total: 10,
                                        pages: [8: HistoryPage(entries: older, cursor: 0, total: 10)])

        await model.loadEarlierHistory()

        XCTAssertEqual(host.pageRequests.map(\.cursor), [8])
        XCTAssertEqual(model.transcript.map(\.id), ["8", "9", "10"])
        XCTAssertFalse(model.hasEarlierHistory, "the page reached the start of the conversation")
        XCTAssertEqual(model.earlierLoads, 1, "the views need to know a prepend happened")
        XCTAssertEqual(model.earlierAnchor, "10", "the fold is remembered for re-anchoring")
        await model.stop()
    }

    func testAPageThatOverlapsTheTranscriptIsNeverDoubled() async {
        let (model, _) = await opened("overlap", entries: [entry("9", "middle"), entry("10", "newest")],
                                      earlierCursor: 8, total: 10,
                                      pages: [8: HistoryPage(entries: [entry("9", "middle"), entry("10", "newest")],
                                                             cursor: nil, total: 10)])
        await model.loadEarlierHistory()
        XCTAssertEqual(model.transcript.map(\.id), ["9", "10"], "a row on screen is never inserted again")
        XCTAssertEqual(model.earlierLoads, 0)
        await model.stop()
    }

    func testAnOlderPageInsertsAboveTheLiveTurnBoundary() async {
        // `turnRowStart` scopes the duplicate-reply gate to the current turn; prepending rows above
        // it must move it, or the next turn's reply is compared against older history.
        let (model, _) = await opened("boundary", entries: [entry("10", "newest")], earlierCursor: 1, total: 2,
                                      pages: [1: HistoryPage(entries: [entry("0", "first")], cursor: nil, total: 2)])
        await model.loadEarlierHistory()
        XCTAssertEqual(model.transcript.count, 2)
        XCTAssertEqual(model.transcript.first?.id, "0")
        await model.stop()
    }

    func testAFailedPageIsReportedAndLeavesTheTranscriptAlone() async {
        let host = ScriptedHost(session: "stored-1", entries: [entry("10", "newest")])
        host.earlierCursor = 4
        host.historyTotal = 5
        let model = AppModel(client: host, hostName: hostName("fail"))
        await model.start()
        await model.select("stored-1")
        // No page scripted for cursor 4: the host answers `.none`, which keeps everything as it was.
        await model.loadEarlierHistory()
        XCTAssertEqual(model.transcript.map(\.id), ["10"])
        XCTAssertNil(model.lastSendError, "an empty page is not an error")
        await model.stop()
    }
}
#endif
