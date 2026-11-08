import Foundation
import XCTest
@testable import HermesKit

/// After a relaunch the chat has no live attachments — only the host's `@image:` references. The
/// picture has to come back from the cache by the name those references quote, not by guessing
/// which bubble it belonged to from the message's text.
final class AttachmentReferenceTests: XCTestCase {

    private let hostPath = "/home/agent/.hermes/profiles/assistant/images/upload_zqoimu1p.png"

    override func setUp() {
        super.setUp()
        AttachmentImageStore.save(Data([7, 7, 7]), as: hostPath)
    }

    func testAStoredRowFindsItsPictureByReferenceName() {
        let entry = TranscriptEntry(id: "1", role: .user,
                                    text: "great it works now.\n@image:\(hostPath)")
        let attachments = entry.referenceAttachments

        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?.name, "upload_zqoimu1p.png")
        XCTAssertEqual(attachments.first?.isImage, true)
        XCTAssertEqual(attachments.first?.imageData, Data([7, 7, 7]),
                       "the bytes must come back from the store, keyed by the name the host quotes")
    }

    func testTheSentenceIsNotPartOfTheName() {
        let entry = TranscriptEntry(id: "1", role: .user, text: "@image:\(hostPath)")
        XCTAssertEqual(entry.displayText, "")
        XCTAssertEqual(entry.referenceAttachments.first?.name, "upload_zqoimu1p.png")
    }

    func testAnUnknownReferenceStillNamesTheFile() {
        let entry = TranscriptEntry(id: "1", role: .user,
                                    text: "@image:/home/agent/.hermes/profiles/assistant/images/upload_never.png")
        let attachment = entry.referenceAttachments.first
        XCTAssertEqual(attachment?.name, "upload_never.png")
        XCTAssertNil(attachment?.imageData, "no cache entry means a named chip, not a picture")
    }

    func testANonImageReferenceIsAFile() {
        let entry = TranscriptEntry(id: "1", role: .user, text: "@file:/home/agent/x/report.pdf")
        XCTAssertEqual(entry.referenceAttachments.first?.isImage, false)
    }

    func testAssistantRowsHaveNoReferenceAttachments() {
        let entry = TranscriptEntry(id: "1", role: .assistant,
                                    text: "here\n@image:\(hostPath)")
        XCTAssertTrue(entry.referenceAttachments.isEmpty)
    }

    func testTheStoreKeepsNamesInsideItsDirectory() {
        // A path collapses to its last component, so nothing lands outside the cache directory.
        AttachmentImageStore.save(Data([1]), as: "../../escape.png")
        XCTAssertEqual(AttachmentImageStore.data(named: "escape.png"), Data([1]))
    }
}
