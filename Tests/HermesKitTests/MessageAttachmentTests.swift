import Foundation
import XCTest
@testable import HermesKit

/// A message carries a *path*, not bytes: the host stores an upload on its own disk and puts
/// `@image:<path>` (or a `📎 … — Attached Context —` block) into the stored prompt, because the
/// agent needs something to open. A second device holds only that string, so the parse is the whole
/// feature: it has to name the file, keep it apart from the words, and survive the block the engine
/// appends.
///
/// Both fixtures below are real rows read from this host's `state.db` before the parser was
/// written, not shapes invented to fit it.
final class MessageAttachmentTests: XCTestCase {

    /// A photo uploaded from the phone.
    private let photoMessage = """
    why does the hermeyd update not work and rolled back?
    @image:/root/.hermes/profiles/cody/images/upload_1v5jm9lm.jpg
    """

    /// A workbook attached on the Mac, with the engine's block after it.
    private let workbookMessage = """
    @file:.hermes/profiles/cody/attachments/MICs.xlsx

    cipher bot is saying session not found

    --- Attached Context ---

    📎 @file:.hermes/profiles/cody/attachments/MICs.xlsx (application/vnd.openxmlformats-officedocument.spreadsheetml.sheet, 20.8 KB) — binary file, not inlined as text. It is available on disk at `/root/.hermes/profiles/cody/attachments/MICs.xlsx`. Use your tools to work with it (read or convert it, extract its text, or view/render it as needed); do not tell the user the file type is unsupported.
    """

    override func setUp() {
        super.setUp()
        AttachmentByteCache.removeAll()
    }

    // MARK: Both shapes, one struct

    func testAPhotoFromThePhoneIsAnImageAttachment() {
        let scan = MessageRefs.attachments(in: photoMessage)
        XCTAssertEqual(scan.attachments.count, 1)
        let photo = scan.attachments.first
        XCTAssertEqual(photo?.kind, .image)
        XCTAssertEqual(photo?.name, "upload_1v5jm9lm.jpg")
        XCTAssertEqual(photo?.path, "/root/.hermes/profiles/cody/images/upload_1v5jm9lm.jpg")
        XCTAssertEqual(scan.body, "why does the hermeyd update not work and rolled back?")
    }

    func testAWorkbookFromTheMacIsAFileAttachmentWithItsTypeAndSize() {
        let scan = MessageRefs.attachments(in: workbookMessage)
        XCTAssertEqual(scan.attachments.count, 1, "the 📎 block repeats the same file, not a second one")
        let workbook = scan.attachments.first
        XCTAssertEqual(workbook?.kind, .file)
        XCTAssertEqual(workbook?.name, "MICs.xlsx")
        XCTAssertEqual(workbook?.path, ".hermes/profiles/cody/attachments/MICs.xlsx")
        // The block is the only place the type and the byte count are written down.
        XCTAssertEqual(workbook?.mimeType,
                       "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        XCTAssertEqual(workbook?.size, 20_800, "20.8 KB, read with the engine's 1000s")
        XCTAssertEqual(scan.body, "cipher bot is saying session not found",
                       "the whole block is host bookkeeping, not prose")
    }

    /// The block can be wrapped, and everything inside it is bookkeeping: none of it may reach the
    /// bubble, however many lines the engine took to say it.
    func testTheBlockIsDroppedHoweverManyLinesItTakes() {
        let wrapped = """
        @file:.hermes/profiles/cody/attachments/MICs.xlsx

        what is in this sheet?

        --- Attached Context ---

        📎 @file:.hermes/profiles/cody/attachments/MICs.xlsx (application/vnd.openxmlformats-officedocument.spreadsheetml.sheet, 20.8 KB)
        — binary file, not inlined as text. It is available on disk at `/root/.hermes/profiles/cody/attachments/MICs.xlsx`.
        Use your tools to work with it; do not tell the user the file type is unsupported.
        """
        let scan = MessageRefs.attachments(in: wrapped)
        XCTAssertEqual(scan.body, "what is in this sheet?")
        XCTAssertEqual(scan.attachments.count, 1)
        XCTAssertEqual(scan.attachments.first?.size, 20_800)
        XCTAssertFalse(scan.body.contains("📎"))
        XCTAssertFalse(scan.body.contains("binary file"))
    }

    /// The one renderer draws whatever the message says, so both directions are covered by the same
    /// parse — this is the fixture the guards and both shells lean on.
    func testABodyCarryingEachShapeYieldsOneOfEach() {
        let body = """
        here are two things
        @image:/home/agent/.hermes/profiles/assistant/images/upload_zqoimu1p.png
        @file:/home/agent/.hermes/profiles/assistant/attachments/budget.xlsx
        """
        let scan = MessageRefs.attachments(in: body)
        XCTAssertEqual(scan.attachments.map(\.name), ["upload_zqoimu1p.png", "budget.xlsx"])
        XCTAssertEqual(scan.attachments.map(\.isImage), [true, false])
        XCTAssertEqual(scan.body, "here are two things")
    }

    func testTheCacheKeyIsTheReferenceSoTwoRowsShareOneFetch() {
        let scan = MessageRefs.attachments(in: photoMessage)
        let again = MessageRefs.attachments(in: photoMessage)
        XCTAssertEqual(scan.attachments.first?.id, again.attachments.first?.id)
        XCTAssertEqual(scan.attachments.first?.id, scan.attachments.first?.path,
                       "the reference is the key: no second name to keep in step")
    }

    // MARK: What is not a reference

    func testAMentionMidSentenceStaysProse() {
        let text = "ping me at @file: later"
        let scan = MessageRefs.attachments(in: text)
        XCTAssertTrue(scan.attachments.isEmpty)
        XCTAssertEqual(scan.body, text)
        XCTAssertEqual(MessageRefs.display(text), text)
    }

    func testATypedPathInProseIsNotAnAttachment() {
        let text = "the file is at /root/.hermes/profiles/cody/attachments/MICs.xlsx"
        XCTAssertTrue(MessageRefs.attachments(in: text).attachments.isEmpty)
    }

    func testOrdinaryTextIsUntouched() {
        let text = "ship it\n\nsecond paragraph"
        let scan = MessageRefs.attachments(in: text)
        XCTAssertEqual(scan.body, text)
        XCTAssertEqual(MessageRefs.display(text), text)
    }

    func testAnAttachmentOnlySendLeavesNoBody() {
        let scan = MessageRefs.attachments(in: "@image:/a/one.png")
        XCTAssertEqual(scan.body, "")
        XCTAssertEqual(scan.attachments.count, 1)
    }

    // MARK: The engine's wrappers and names

    func testABacktickedNameWithASpaceIsOnePath() {
        let scan = MessageRefs.attachments(
            in: "@file:`/home/a/profiles/cody/attachments/my report.pdf`")
        XCTAssertEqual(scan.attachments.first?.name, "my report.pdf",
                       "the wrapping is the engine's, not part of the name")
    }

    func testASentenceFullStopIsNotPartOfTheName() {
        let scan = MessageRefs.attachments(in: "@image:/a/uploads/upload_ab.png.")
        XCTAssertEqual(scan.attachments.first?.name, "upload_ab.png")
    }

    func testAnUnfetchableReferenceStillNamesTheFile() {
        // Nothing is cached and nothing is reachable: the row must still say which file it is.
        let scan = MessageRefs.attachments(
            in: "@image:/home/agent/.hermes/profiles/assistant/images/upload_never.png")
        XCTAssertEqual(scan.attachments.first?.name, "upload_never.png")
        XCTAssertNil(AttachmentByteCache.data(for: "/home/agent/.hermes/profiles/assistant/images/upload_never.png"))
    }

    func testTheDisplayedTextDropsTheBlockAndKeepsTheWords() {
        let row = TranscriptEntry(id: "1", role: .user, text: workbookMessage)
        XCTAssertEqual(row.displayText, "cipher bot is saying session not found")
        XCTAssertEqual(row.referenceAttachments(profile: "cody").map(\.name), ["MICs.xlsx"])
    }

    // MARK: The route

    func testTheReferenceLocationAsksTheHostRouteForTheReference() {
        let path = "/root/.hermes/profiles/cody/images/upload_a.jpg"
        let location = AttachmentLocation.reference(profile: "cody", path: path)
        XCTAssertEqual(location.profile, "cody")
        XCTAssertEqual(location.displayName, "upload_a.jpg")
        XCTAssertEqual(location.kind, .image)
        // Keyed by a fingerprint of the reference plus the extension: the same *name* in two
        // profiles must not become one cache file, and Quick Look picks a viewer from the suffix.
        XCTAssertTrue(location.cacheKey.hasPrefix("ref-"), "a reference key names its own hash")
        XCTAssertTrue(location.cacheKey.hasSuffix(".jpg"), "Quick Look picks a viewer from the suffix")

        let otherProfile = AttachmentLocation.reference(
            profile: "jason", path: "/root/.hermes/profiles/jason/images/upload_a.jpg")
        XCTAssertNotEqual(location.cacheKey, otherProfile.cacheKey)
    }

    // MARK: The cache

    func testTheCacheKeepsSixtyFourAndEvictsTheLeastRecentlyUsed() {
        XCTAssertEqual(AttachmentByteCache.capacity, 64)
        for index in 0..<64 {
            AttachmentByteCache.store(Data([UInt8(index % 256)]), for: "ref-\(index)")
        }
        XCTAssertEqual(AttachmentByteCache.count, 64)
        // Touch the oldest: it must survive the next insert, and the second-oldest must go.
        XCTAssertNotNil(AttachmentByteCache.data(for: "ref-0"))
        AttachmentByteCache.store(Data([9]), for: "ref-64")
        XCTAssertEqual(AttachmentByteCache.count, 64)
        XCTAssertTrue(AttachmentByteCache.contains("ref-0"))
        XCTAssertFalse(AttachmentByteCache.contains("ref-1"), "the least recently used goes first")
        XCTAssertEqual(AttachmentByteCache.recency.last, "ref-64")
        XCTAssertEqual(AttachmentByteCache.recency.first, "ref-2")
    }

    func testTheCacheIsKeyedByTheReference() {
        let key = "/root/.hermes/profiles/cody/images/upload_a.jpg"
        AttachmentByteCache.store(Data([1, 2, 3]), for: key)
        XCTAssertEqual(AttachmentByteCache.data(for: key), Data([1, 2, 3]))
        XCTAssertNil(AttachmentByteCache.data(for: "upload_a.jpg"),
                     "the bare name is not the key")
        // An empty body is not a picture and must not become one.
        AttachmentByteCache.store(Data(), for: "ref-empty")
        XCTAssertFalse(AttachmentByteCache.contains("ref-empty"))
    }

    func testAReaderHitsTheCacheBeforeAskingTheHost() async throws {
        let reference = MessageRefs.attachments(in: photoMessage).attachments[0]
        AttachmentByteCache.store(Data([0xFF, 0xD8]), for: reference.cacheKey(profile: "cody"))
        var asked = false
        let data = try await AttachmentReferenceReader.bytes(for: reference, profile: "cody") { _ in
            asked = true
            throw AttachmentFetchError.notReady
        }
        XCTAssertEqual(data, Data([0xFF, 0xD8]))
        XCTAssertFalse(asked, "a cached reference must not cost a request")
    }

    func testAReaderThatCannotReachTheHostThrowsRatherThanInventsBytes() async {
        let reference = MessageAttachment(id: "ref-x", kind: .image,
                                          path: "/a/images/upload_absent.png",
                                          name: "upload_absent-\(UUID().uuidString).png")
        do {
            _ = try await AttachmentReferenceReader.bytes(for: reference, profile: "cody") { _ in
                throw AttachmentFetchError.notReady
            }
            XCTFail("an unreachable host must throw, not answer empty bytes")
        } catch {
            XCTAssertEqual(error as? AttachmentFetchError, .notReady)
        }
    }

    // MARK: Helpers

    private static func fnv(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
