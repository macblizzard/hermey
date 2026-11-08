import Foundation
import XCTest
@testable import HermesKit

/// The host stores an upload as a `@image:`/`@file:` line inside the user's message. That line is
/// bookkeeping: printing it puts an absolute path where a picture belongs, and comparing it raw
/// breaks attachment matching on every reload.
final class MessageRefsTests: XCTestCase {

    func testReferenceLinesAreNotPartOfTheSentence() {
        let stored = "What do you see?\n@image:/home/agent/.hermes/profiles/assistant/images/upload_ab.png"
        XCTAssertEqual(MessageRefs.display(stored), "What do you see?")
        XCTAssertEqual(MessageRefs.split(stored).refs, ["/home/agent/.hermes/profiles/assistant/images/upload_ab.png"])
    }

    func testSeveralReferencesAreAllTakenOut() {
        let stored = """
        look
        @image:/a/one.png
        @file:/a/report.pdf
        """
        let split = MessageRefs.split(stored)
        XCTAssertEqual(split.body, "look")
        XCTAssertEqual(split.refs.count, 2)
        XCTAssertEqual(MessageRefs.names(split.refs), ["one.png", "report.pdf"])
    }

    func testAnAttachmentOnlySendHasNoBodyLeft() {
        XCTAssertEqual(MessageRefs.display("@image:/a/one.png"), "")
    }

    func testOrdinaryTextIsUntouched() {
        let text = "ship it\n\nsecond paragraph"
        XCTAssertEqual(MessageRefs.display(text), text)
        XCTAssertTrue(MessageRefs.split(text).refs.isEmpty)
    }

    func testAnAtSignInProseIsNotAReference() {
        // `@file:` has to start the line; a mention mid-sentence is the user's own words.
        let text = "ping me at @file: later"
        XCTAssertEqual(MessageRefs.display(text), text)
        XCTAssertTrue(MessageRefs.split(text).refs.isEmpty)
    }
}
