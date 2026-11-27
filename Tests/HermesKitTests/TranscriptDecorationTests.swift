import XCTest
@testable import HermesKit

/// A rewrite the ids cannot see must not read as "nothing changed".
///
/// The attachment-decoration pass rewrites rows in place: it fills `attachments` on the user rows
/// and touches nothing else — the count, the first id and the last id all stay where they were. A
/// classification that looks at ids alone therefore calls it `.unchanged`, and both caches
/// (`TranscriptVisibilityCache`, and the shells' `TranscriptRowCache`) keep serving the
/// undecorated rows they already hold — which is why a picture sent from one device could fail to
/// appear on the other after a paged resume. The model's transcript generation is the fact ids
/// cannot carry, and these tests pin what it does.
final class TranscriptDecorationTests: XCTestCase {

    private func row(_ id: String, _ role: TranscriptEntry.Role = .assistant,
                     attachments: [SentAttachment] = []) -> TranscriptEntry {
        TranscriptEntry(id: id, role: role, text: id, attachments: attachments)
    }

    /// The pass `SentAttachmentVault.decorate` performs: same shape, different rows.
    private func decorated(_ entries: [TranscriptEntry]) -> [TranscriptEntry] {
        entries.map { entry in
            entry.role == .user
                ? TranscriptEntry(id: entry.id, role: entry.role, text: entry.text,
                                  attachments: [SentAttachment(name: "shot.png", isImage: true,
                                                               imageData: Data([1, 2, 3]))])
                : entry
        }
    }

    func testADecorationOnlyChangeIsNotUnchanged() {
        let undecorated = [row("u1", .user), row("a1")]
        let decorated = self.decorated(undecorated)
        XCTAssertEqual(decorated.count, undecorated.count)
        XCTAssertEqual(decorated.first?.id, undecorated.first?.id)
        XCTAssertEqual(decorated.last?.id, undecorated.last?.id)

        // Stated, not assumed: ids alone cannot see the decoration. That classification is the
        // bug — it is what sent the caches to sleep over rows that had just been re-drawn.
        XCTAssertEqual(TranscriptSplices.detect(previous: undecorated, entries: decorated),
                       .unchanged)

        // The model bumps the generation for a rewrite in place, and that is what the caches are
        // told: the same comparison with a moved generation is a replacement, every time.
        XCTAssertEqual(TranscriptSplices.detect(previous: undecorated, entries: decorated,
                                                sameGeneration: false),
                       .replaced)
        // And a generation that did not move still gets the cheap answer.
        XCTAssertEqual(TranscriptSplices.detect(previous: undecorated, entries: decorated,
                                                sameGeneration: true),
                       .unchanged)
    }

    func testTheVisibilityCacheRedecoratesWhenTheGenerationMoves() {
        let undecorated = [row("u1", .user), row("a1")]
        let decorated = self.decorated(undecorated)
        let cache = TranscriptVisibilityCache()
        _ = cache.rows(undecorated, generation: 7, showToolCalls: true, showReasoning: true)

        // Same generation: a body pass costs nothing, exactly as before.
        XCTAssertEqual(cache.rows(decorated, generation: 7, showToolCalls: true, showReasoning: true),
                       undecorated)
        // One generation later: the rows are rebuilt, and the picture is on them.
        let after = cache.rows(decorated, generation: 8, showToolCalls: true, showReasoning: true)
        XCTAssertEqual(after.first?.attachments.map(\.name), ["shot.png"])
        XCTAssertEqual(after.first?.attachments.first?.imageData, Data([1, 2, 3]))
    }

    func testTheRowCacheRedecoratesWhenTheGenerationMoves() {
        let undecorated = [row("u1", .user), row("a1")]
        let decorated = self.decorated(undecorated)
        let cache = TranscriptRowCache()
        _ = cache.rows(undecorated, generation: 3)
        // Same generation: the folded rows are served again untouched.
        let kept = cache.rows(decorated, generation: 3)
        let entriesKept = kept.flatMap { row -> [TranscriptEntry] in
            if case .entry(let entry) = row { return [entry] }
            return []
        }
        XCTAssertTrue(entriesKept.contains { $0.attachments.isEmpty && $0.role == .user })

        let after = cache.rows(decorated, generation: 4)
        let entriesAfter = after.flatMap { row -> [TranscriptEntry] in
            if case .entry(let entry) = row { return [entry] }
            return []
        }
        // The rebuilt rows carry the decoration: a user row with no attachments in them means the
        // cache kept its undecorated copy.
        XCTAssertTrue(entriesAfter.contains { $0.role == .user && !$0.attachments.isEmpty })
    }
}
