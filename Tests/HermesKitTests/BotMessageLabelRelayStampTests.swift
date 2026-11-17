import XCTest
@testable import HermesKit

/// The host's relay stamp is a header, not part of the message. Parsing it is what lets both apps draw
/// the attribution above the bubble instead of carrying it inside the text.
final class BotMessageLabelRelayStampTests: XCTestCase {
    func testTheLiveSenderStampIsRecognised() {
        let text = "Message from 🤖 atlas (@atlas): [no reply needed] Standing change for every bot."
        let label = BotMessageLabel.parse(text)
        XCTAssertNotNil(label)
        XCTAssertEqual(label?.senderLabel, "atlas")
        XCTAssertEqual(label?.senderProfile, "atlas")
        XCTAssertEqual(label?.body, "[no reply needed] Standing change for every bot.")
        XCTAssertEqual(label?.headerTitle, "Message from Atlas")
        XCTAssertFalse(label?.isOutgoing ?? true)
    }

    func testAMessageToStampKeepsItsDirection() {
        let label = BotMessageLabel.parse("Message to 🤖 atlas (@atlas): please verify the link")
        XCTAssertNotNil(label)
        XCTAssertEqual(label?.body, "please verify the link")
        XCTAssertEqual(label?.headerTitle, "Message to atlas")
        XCTAssertTrue(label?.isOutgoing ?? false)
    }

    func testAFriendlyDisplayNameIsKeptAndTheHandleIsTheProfile() {
        let label = BotMessageLabel.parse("Message from 🤖 Atlas Ops (@atlas): hello")
        XCTAssertEqual(label?.senderLabel, "Atlas Ops")
        XCTAssertEqual(label?.senderProfile, "atlas")
        XCTAssertEqual(label?.headerTitle, "Message from Atlas")
    }

    func testTheLegacyArrowStampStillParses() {
        let label = BotMessageLabel.parse("Assistant (cody) → Ops: do the thing")
        XCTAssertEqual(label?.senderProfile, "cody")
        XCTAssertEqual(label?.body, "do the thing")
        XCTAssertEqual(label?.headerTitle, "Message from Cody")
    }

    func testAnOrdinaryMessageIsNotMisread() {
        XCTAssertNil(BotMessageLabel.parse("Message from my boss: see you at nine"))
    }
}
