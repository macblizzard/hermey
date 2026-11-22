import XCTest
@testable import HermesCards

/// The marker parser: where a card is named, and what a bubble keeps.
final class CardMarkerTests: XCTestCase {

    private func marker(id: String = "c-9b",
                        kind: String = "approval",
                        file: String = "cards/c-9b.json") -> String {
        "::card{id=\"\(id)\" kind=\"\(kind)\" file=\"\(file)\"}"
    }

    func testMarkerAloneOnItsLineIsFound() {
        let reply = "Booked.\n\(marker())\nAnything else?"
        let scan = CardMarker.scan(reply)

        XCTAssertEqual(scan.refs, [CardRef(id: "c-9b", kind: "approval", file: "cards/c-9b.json")])
        XCTAssertEqual(scan.prose, "Booked.\nAnything else?")
    }

    func testAttributeOrderDoesNotMatter() {
        let reply = #"::card{file="cards/c-9b.json" kind="approval" id="c-9b"}"#
        XCTAssertEqual(CardMarker.references(in: reply).map(\.id), ["c-9b"])
    }

    func testSingleQuotedAttributesAreAccepted() {
        let reply = "::card{id='c-9b' kind='approval' file='cards/c-9b.json'}"
        XCTAssertEqual(CardMarker.references(in: reply).map(\.file), ["cards/c-9b.json"])
    }

    /// A marker inside a fence is an example the reply is teaching, not a card to draw.
    func testMarkerInsideAFenceIsProse() {
        let reply = """
        Here is the shape:

        ```
        \(marker(id: "c-fence", file: "cards/c-fence.json"))
        ```

        That is all.
        """

        XCTAssertTrue(CardMarker.references(in: reply).isEmpty)
        XCTAssertEqual(CardMarker.textWithoutMarkers(reply), reply)
    }

    func testFenceWithAnInfoStringHidesItsContentsToo() {
        let reply = "```swift\n\(marker())\n```"
        XCTAssertTrue(CardMarker.references(in: reply).isEmpty)
        XCTAssertTrue(CardMarker.textWithoutMarkers(reply).contains(marker()))
    }

    func testAMarkerAfterAFenceStillDraws() {
        let reply = "```\n\(marker(id: "c-fence", file: "cards/c-fence.json"))\n```\n\(marker())"
        let scan = CardMarker.scan(reply)

        XCTAssertEqual(scan.refs.map(\.id), ["c-9b"])
        XCTAssertTrue(scan.prose.contains("cards/c-fence.json"))
        XCTAssertFalse(scan.prose.contains(#"id="c-9b""#))
    }

    func testTwoMarkersComeBackInOrder() {
        let second = marker(id: "c-9c", file: "cards/c-9c.json")
        let reply = "\(marker())\nMiddle paragraph.\n\(second)"
        let scan = CardMarker.scan(reply)

        XCTAssertEqual(scan.refs.map(\.id), ["c-9b", "c-9c"])
        XCTAssertEqual(scan.prose, "Middle paragraph.")
    }

    /// The contract says one directive per line, alone. Anything else is a sentence and must not
    /// lose its text to a half-matched marker.
    func testAMarkerMustBeAloneOnItsLine() {
        let inline = "Use \(marker()) inline."
        XCTAssertTrue(CardMarker.references(in: inline).isEmpty)
        XCTAssertEqual(CardMarker.textWithoutMarkers(inline), inline)

        let trailing = "\(marker()) and more"
        XCTAssertTrue(CardMarker.references(in: trailing).isEmpty)
        XCTAssertEqual(CardMarker.textWithoutMarkers(trailing), trailing)

        let twoOnOneLine = "\(marker(id: "c-1a", file: "cards/c-1a.json")) \(marker(id: "c-1b", file: "cards/c-1b.json"))"
        XCTAssertTrue(CardMarker.references(in: twoOnOneLine).isEmpty)
    }

    /// The parser reports the kind it was given; whether the card may draw is the model's call.
    /// That is what turns an unknown kind into "Card not available" instead of a lost line.
    func testAnUnknownKindStillParses() {
        let reply = "::card{id=\"c-9b\" kind=\"quiz\" file=\"cards/c-9b.json\"}"
        XCTAssertEqual(CardMarker.references(in: reply).map(\.kind), ["quiz"])
    }

    func testMissingOrUnfetchableFieldsLeaveTheLineAsText() {
        let missingFile = #"::card{id="c-9b" kind="approval"}"#
        XCTAssertTrue(CardMarker.references(in: missingFile).isEmpty)
        XCTAssertEqual(CardMarker.textWithoutMarkers(missingFile), missingFile)

        let pathLikeID = #"::card{id="../secret" kind="approval" file="cards/x.json"}"#
        XCTAssertTrue(CardMarker.references(in: pathLikeID).isEmpty)

        let tooLong = String(repeating: "a", count: 41)
        let longID = "::card{id=\"\(tooLong)\" kind=\"approval\" file=\"cards/x.json\"}"
        XCTAssertTrue(CardMarker.references(in: longID).isEmpty)
    }

    func testProseOnlyReplyIsUntouched() {
        let reply = "Nothing was drawn today, so this is just prose with a { brace }."
        XCTAssertTrue(CardMarker.references(in: reply).isEmpty)
        XCTAssertEqual(CardMarker.textWithoutMarkers(reply), reply)
    }

    /// CRLF messages exist in transcripts imported from other clients; splitting on `.newlines`
    /// would double every break.
    func testCRLFKeepsItsLineEndings() {
        let reply = "before\r\n\(marker())\r\nafter"
        let scan = CardMarker.scan(reply)

        XCTAssertEqual(scan.refs.map(\.id), ["c-9b"])
        XCTAssertEqual(scan.prose, "before\r\nafter")
    }
}
