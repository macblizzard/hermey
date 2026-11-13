import XCTest
@testable import HermesAppKit

/// The `::blocks{id="…"}` directive: finding it, and taking it out of the text.
///
/// This is the one piece of the genui cards that is pure logic, and the one that fails silently: a
/// tag that is not found means no card at all, and a tag that is not removed means the user reads
/// `::blocks{id="7f3a09bc"}` under a drawn board.
final class GenUITagTests: XCTestCase {
    func testFindsTheBoardInAReply() {
        let text = """
        Here is the board you asked for.

        ::blocks{id="7f3a09bc"}
        """
        XCTAssertEqual(GenUITag.boardID(in: text), "7f3a09bc")
    }

    func testAcceptsSingleQuotesAndOtherAttributes() {
        XCTAssertEqual(GenUITag.boardID(in: #"::blocks{id='00b7610f'}"#), "00b7610f")
        XCTAssertEqual(GenUITag.boardID(in: #"::blocks{ id="deadbeef" }"#), "deadbeef")
        XCTAssertEqual(GenUITag.boardID(in: #"::blocks{name="board" id="00b7610f"}"#), "00b7610f")
    }

    func testIgnoresAnythingThatIsNotAnId() {
        // The plugin's ids are eight lowercase hex characters (`core/store.py`); a prose mention of
        // the directive is not a card, and an uppercase or short id is not an id.
        XCTAssertNil(GenUITag.boardID(in: "no tag here"))
        XCTAssertNil(GenUITag.boardID(in: #"::blocks{id="NOTHEX!!"}"#))
        XCTAssertNil(GenUITag.boardID(in: #"::blocks{id="00B7610F"}"#))
        XCTAssertNil(GenUITag.boardID(in: #"::blocks{id="00b7610"}"#))
        XCTAssertNil(GenUITag.boardID(in: #"::blocks{id="00b7610fa"}"#))
    }

    func testStripsTheDirectiveAndLeavesTheProse() {
        let text = "Two things:\n\n::blocks{id=\"7f3a09bc\"}\n\nThat is all."
        let stripped = GenUITag.textWithoutTags(text)
        XCTAssertFalse(stripped.contains("::blocks"))
        XCTAssertTrue(stripped.contains("Two things:"))
        XCTAssertTrue(stripped.contains("That is all."))
        // The directive's own line is gone, not left as a gap of three newlines.
        XCTAssertFalse(stripped.contains("\n\n\n"))
    }

    func testAReplyThatIsOnlyATagBecomesEmptyText() {
        XCTAssertEqual(GenUITag.textWithoutTags(#"::blocks{id="7f3a09bc"}"#), "")
    }

    func testThePaletteTravelsWithTheCardURL() {
        let cards = GenUICards(origin: URL(string: "https://hermes.example.ts.net")!,
                               deviceID: "dev", refreshToken: "refresh")
        let palette = GenUIPalette(ink: "#F5F5F5", background: "#0A0A0A", accent: "#4D9BFF",
                                   muted: "#A5A5A5", good: "#00BA69")
        let url = cards.cardURL(bot: "fino", block: "7f3a09bc", session: "abc123", palette: palette)
        let items = URLComponents(url: try! XCTUnwrap(url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        XCTAssertEqual(value("block"), "7f3a09bc")
        XCTAssertEqual(value("bot"), "fino")
        XCTAssertEqual(value("session"), "abc123")
        XCTAssertEqual(value("ink"), "#F5F5F5")
        XCTAssertEqual(value("accent"), "#4D9BFF")
        // The host's origin, not a hardcoded one: a paired host is the only one that can mint.
        XCTAssertEqual(URLComponents(url: try! XCTUnwrap(url), resolvingAgainstBaseURL: false)?.host,
                       "hermes.example.ts.net")
        XCTAssertEqual(URLComponents(url: try! XCTUnwrap(url), resolvingAgainstBaseURL: false)?.path,
                       "/v1/genui/host")
    }
}
