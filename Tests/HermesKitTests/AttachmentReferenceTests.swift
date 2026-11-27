import Foundation
import XCTest
@testable import HermesKit

/// After a relaunch the chat has no live attachments — only the host's `@image:` references. The
/// picture has to come back from the cache by the reference those rows quote — keyed by profile +
/// reference (`AttachmentLocation.cacheKey`), never the bare name — not by guessing which bubble it
/// belonged to from the message's text.
final class AttachmentReferenceTests: XCTestCase {

    private let profile = "assistant"
    private let hostPath = "/home/agent/.hermes/profiles/assistant/images/upload_zqoimu1p.png"

    override func setUp() {
        super.setUp()
        let key = AttachmentLocation.reference(profile: profile, path: hostPath).cacheKey
        AttachmentImageStore.save(Data([7, 7, 7]), as: key)
    }

    func testAStoredRowFindsItsPictureByReferenceName() {
        let entry = TranscriptEntry(id: "1", role: .user,
                                    text: "great it works now.\n@image:\(hostPath)")
        let attachments = entry.referenceAttachments(profile: profile)

        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?.name, "upload_zqoimu1p.png")
        XCTAssertEqual(attachments.first?.isImage, true)
        XCTAssertEqual(attachments.first?.imageData, Data([7, 7, 7]),
                       "the bytes must come back from the store, keyed by the reference the host quotes")
    }

    func testTheSameNameInTwoProfilesNeverSharesAnEntry() {
        // The 2026-11 audit: a bare-name key made profile A's cached `notes.pdf` answer profile B's
        // reference. The key is profile + reference now, so two same-named files are two entries.
        let name = "/home/agent/.hermes/profiles/assistant/images/upload_shared.png"
        let otherProfile = AttachmentLocation.reference(profile: "jason", path: name).cacheKey
        AttachmentImageStore.save(Data([9]), as: otherProfile)

        let entry = TranscriptEntry(id: "2", role: .user, text: "@image:\(name)")
        XCTAssertEqual(entry.referenceAttachments(profile: profile).first?.imageData, Data([7, 7, 7]),
                       "assistant's row renders assistant's bytes")
        XCTAssertEqual(entry.referenceAttachments(profile: "jason").first?.imageData, Data([9]),
                       "jason's row renders jason's bytes, never the other profile's")
    }

    func testTheSentenceIsNotPartOfTheName() {
        let entry = TranscriptEntry(id: "1", role: .user, text: "@image:\(hostPath)")
        XCTAssertEqual(entry.displayText, "")
        XCTAssertEqual(entry.referenceAttachments(profile: profile).first?.name, "upload_zqoimu1p.png")
    }

    func testAnUnknownReferenceStillNamesTheFile() {
        let entry = TranscriptEntry(id: "1", role: .user,
                                    text: "@image:/home/agent/.hermes/profiles/assistant/images/upload_never.png")
        let attachment = entry.referenceAttachments(profile: profile).first
        XCTAssertEqual(attachment?.name, "upload_never.png")
        XCTAssertNil(attachment?.imageData, "no cache entry means a named chip, not a picture")
    }

    func testANonImageReferenceIsAFile() {
        let entry = TranscriptEntry(id: "1", role: .user, text: "@file:/home/agent/x/report.pdf")
        XCTAssertEqual(entry.referenceAttachments(profile: profile).first?.isImage, false)
    }

    func testAssistantRowsHaveNoReferenceAttachments() {
        let entry = TranscriptEntry(id: "1", role: .assistant,
                                    text: "here\n@image:\(hostPath)")
        XCTAssertTrue(entry.referenceAttachments(profile: profile).isEmpty)
    }

    func testTheStoreKeepsNamesInsideItsDirectory() {
        // A path collapses to its last component, so nothing lands outside the cache directory.
        AttachmentImageStore.save(Data([1]), as: "../../escape.png")
        XCTAssertEqual(AttachmentImageStore.data(named: "escape.png"), Data([1]))
    }
}
