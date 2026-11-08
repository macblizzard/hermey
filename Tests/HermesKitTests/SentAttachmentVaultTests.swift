import Foundation
import XCTest
@testable import HermesKit

/// The vault is what puts a picture back in the chat after the app has been relaunched, and its
/// matching is a heuristic — so the heuristic is what these pin down.
final class SentAttachmentVaultTests: XCTestCase {

    private var sessionID: String!

    override func setUp() {
        super.setUp()
        // A fresh id per test: the vault is process-global on disk.
        sessionID = "test-\(UUID().uuidString)"
    }

    func testPicturesComeBackOnTheRowsThatSentThem() {
        let first = SentAttachment(name: "one.png", isImage: true, imageData: Data([1, 2, 3]))
        let second = SentAttachment(name: "two.png", isImage: true, imageData: Data([4, 5]))
        SentAttachmentVault.record(sessionID: sessionID, text: "look", attachments: [first])
        SentAttachmentVault.record(sessionID: sessionID, text: "and this", attachments: [second])

        let entries = [
            TranscriptEntry(id: "1", role: .user, text: "look"),
            TranscriptEntry(id: "2", role: .assistant, text: "nice"),
            TranscriptEntry(id: "3", role: .user, text: "and this"),
        ]
        let decorated = SentAttachmentVault.decorate(entries, sessionID: sessionID)

        XCTAssertEqual(decorated[0].attachments.map(\.name), ["one.png"])
        XCTAssertEqual(decorated[0].attachments.first?.imageData, Data([1, 2, 3]))
        XCTAssertTrue(decorated[1].attachments.isEmpty)
        XCTAssertEqual(decorated[2].attachments.map(\.name), ["two.png"])
    }

    func testIdenticalTextIsConsumedOncePerRow() {
        let attachment = SentAttachment(name: "same.png", isImage: true, imageData: Data([9]))
        SentAttachmentVault.record(sessionID: sessionID, text: "re", attachments: [attachment])

        let twice = [
            TranscriptEntry(id: "1", role: .user, text: "re"),
            TranscriptEntry(id: "2", role: .user, text: "re"),
        ]
        let decorated = SentAttachmentVault.decorate(twice, sessionID: sessionID)

        XCTAssertEqual(decorated[0].attachments.count, 1)
        // The record belongs to the first row that claimed it; the second must not steal it.
        XCTAssertTrue(decorated[1].attachments.isEmpty)
    }

    func testARowThatAlreadyHasAttachmentsIsLeftAlone() {
        let stored = SentAttachment(name: "disk.png", isImage: true, imageData: Data([7]))
        SentAttachmentVault.record(sessionID: sessionID, text: "hello", attachments: [stored])

        let live = SentAttachment(name: "live.png", isImage: true, imageData: Data([8]))
        let entry = TranscriptEntry(id: "1", role: .user, text: "hello", attachments: [live])
        let decorated = SentAttachmentVault.decorate([entry], sessionID: sessionID)

        XCTAssertEqual(decorated[0].attachments.map(\.name), ["live.png"])
    }

    func testFilesWithoutPictureDataStillRecordTheirName() {
        let file = SentAttachment(name: "report.pdf", isImage: false)
        SentAttachmentVault.record(sessionID: sessionID, text: "see attached", attachments: [file])

        let decorated = SentAttachmentVault.decorate(
            [TranscriptEntry(id: "1", role: .user, text: "see attached")],
            sessionID: sessionID
        )
        XCTAssertEqual(decorated[0].attachments.map(\.name), ["report.pdf"])
        XCTAssertNil(decorated[0].attachments.first?.imageData)
    }

    func testAnUnknownSessionDecoratesNothing() {
        let entries = [TranscriptEntry(id: "1", role: .user, text: "anything")]
        XCTAssertTrue(SentAttachmentVault.decorate(entries, sessionID: "never-written").isEmpty == false)
        XCTAssertTrue(SentAttachmentVault.decorate(entries, sessionID: "never-written")[0].attachments.isEmpty)
    }
}
