#if canImport(Combine)
import XCTest
@testable import HermesAppKit
import HermesKit

/// The decoration pass is a rewrite in place, and the model must say so.
///
/// A picture sent from one device failed to appear on the other after a paged resume: the adopt
/// landed the page undecorated, `SentAttachmentVault.decorate` filled the attachments on the user
/// rows a moment later — same count, same first id, same last id — and the change was classified
/// `.unchanged`, so both caches went on serving the undecorated rows. These tests drive the real
/// adopt → decoration pass through the model and hold the two facts the fix rests on: the
/// generation moved, and the decorated rows are what the caches serve.
@MainActor
final class TranscriptDecorationAdoptTests: XCTestCase {

    private func waitUntil(_ condition: @escaping () -> Bool,
                           timeout: TimeInterval = 3,
                           file: StaticString = #filePath,
                           line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition not met within \(timeout)s", file: file, line: line)
    }

    func test_a_resume_that_redecorates_rows_in_place_moves_the_generation() async {
        // The session must have vault records, or the adopt skips the decoration pass entirely.
        let session = "deco-\(UUID().uuidString)"
        SentAttachmentVault.record(sessionID: session, text: "send me a picture",
                                   attachments: [SentAttachment(name: "one.png", isImage: true,
                                                                imageData: Data([9, 9, 9]))])
        let host = ScriptedHost(session: session, entries: [
            TranscriptEntry(id: "u1", role: .user, text: "send me a picture"),
            TranscriptEntry(id: "a1", role: .assistant, text: "here it is"),
        ])
        let model = AppModel(client: host)
        await model.start()
        await model.select(session)

        // The undecorated page first: the adopt is the first replacement.
        XCTAssertEqual(model.transcript.map(\.id), ["u1", "a1"])
        XCTAssertEqual(model.transcript.first?.attachments.isEmpty, true)
        let adoptedGeneration = model.transcriptGeneration
        XCTAssertGreaterThanOrEqual(adoptedGeneration, 1)
        // Then the pass lands: rows rewritten, ids untouched, generation bumped.
        await waitUntil { model.transcript.first?.attachments.isEmpty == false }
        XCTAssertEqual(model.transcript.map(\.id), ["u1", "a1"],
                       "a decoration must not touch the ids")
        XCTAssertEqual(model.transcript.first?.attachments.first?.name, "one.png")
        XCTAssertEqual(model.transcriptGeneration, adoptedGeneration + 1,
                       "the decoration pass must bump the generation")
        // And the classification the caches saw for it is not `.unchanged`.
        XCTAssertNotEqual(model.transcriptSplice, .unchanged)
        XCTAssertEqual(model.transcriptSplice, .replaced)

        // What a body pass reads: the decorated row, not the cache's old copy.
        XCTAssertEqual(model.visibleTranscript.first?.attachments.first?.name, "one.png")
    }

    func test_a_delete_in_the_paged_half_leaves_the_screen_with_it() async {
        let host = ScriptedHost(session: "s1", entries: [
            TranscriptEntry(id: "c", rowID: 31, role: .user, text: "newest ask"),
            TranscriptEntry(id: "d", rowID: 32, role: .assistant, text: "newest answer"),
        ])
        // The conversation is paged: rows a, b are older history the host did not resume with.
        host.earlierCursor = 2
        host.historyTotal = 4
        host.bridge = true
        host.pages[2] = HistoryPage(entries: [
            TranscriptEntry(id: "a", rowID: 11, role: .user, text: "older ask"),
            TranscriptEntry(id: "b", rowID: 12, role: .assistant, text: "older answer"),
        ], cursor: 0, total: 4)
        let model = AppModel(client: host)
        await model.start()
        await model.select("s1")

        // The paged half fills — by the silent backfill that opens a conversation or by the
        // explicit load; whichever lands first, wait for all four rows.
        await model.loadEarlierHistory()
        await waitUntil { Set(model.transcript.map(\.id)) == Set(["a", "b", "c", "d"]) }
        XCTAssertEqual(model.transcript.map(\.id), ["a", "b", "c", "d"])

        // Delete `b` — a row of the older, already-paged half. The host's database has moved it;
        // its resume carries only the newest page, whose join keeps everything above it.
        await model.deleteMessage(rowID: 12)
        XCTAssertEqual(host.deleteCalls, [[12]])
        XCTAssertEqual(model.transcript.map(\.id), ["a", "c", "d"],
                       "the retired row must leave both halves of the screen")
    }
}
#endif
