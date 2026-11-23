import XCTest
@testable import HermesCards

/// `card.v1` decoding: what draws, what degrades, and that nothing ever throws.
final class CardModelTests: XCTestCase {

    private let approval = #"""
    {
      "schema": "card.v1",
      "kind": "approval",
      "title": "Book the cabin?",
      "status": { "state": "awaiting-approval" },
      "body": [
        { "type": "text", "text": "The cabin is 840 for three nights." },
        { "type": "kv", "rows": [["Dates", "12-15 Dec"], ["Guests", "2"]] },
        { "type": "fields", "items": [{ "label": "Total", "value": "840" }] }
      ],
      "actions": [
        { "label": "Approve", "send": "APPROVE c-9b book the cabin", "style": "primary" },
        { "label": "Decline", "send": "DECLINE c-9b", "style": "danger" }
      ],
      "resolved": null
    }
    """#

    private func decode(_ json: String) -> CardModel {
        CardModel.decode(Data(json.utf8))
    }

    private func card(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> Card {
        guard case .available(let card) = decode(json) else {
            XCTFail("expected an available card", file: file, line: line)
            throw XCTSkip("decoding failed")
        }
        return card
    }

    private func assertUnavailable(_ json: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(decode(json), CardModel.unavailable(CardModel.unavailableMessage), file: file, line: line)
    }

    // MARK: - The valid document

    func testAValidApprovalDecodesEverythingItDraws() throws {
        let card = try card(approval)

        XCTAssertEqual(card.schema, "card.v1")
        XCTAssertEqual(card.kind, .approval)
        XCTAssertEqual(card.title, "Book the cabin?")
        XCTAssertEqual(card.status.state, .awaitingApproval)
        XCTAssertNil(card.status.label)
        XCTAssertNil(card.resolved)

        XCTAssertEqual(card.body.count, 3)
        guard case .text(let text) = card.body[0] else { return XCTFail("first block is text") }
        XCTAssertEqual(text, "The cabin is 840 for three nights.")
        guard case .kv(let rows) = card.body[1] else { return XCTFail("second block is kv") }
        XCTAssertEqual(rows.map(\.label), ["Dates", "Guests"])
        XCTAssertEqual(rows.map(\.value), ["12-15 Dec", "2"])
        guard case .fields(let fields) = card.body[2] else { return XCTFail("third block is fields") }
        XCTAssertEqual(fields, [Card.Row(label: "Total", value: "840")])

        XCTAssertEqual(card.actions.count, 2)
        XCTAssertEqual(card.actions[0].label, "Approve")
        XCTAssertEqual(card.actions[0].send, "APPROVE c-9b book the cabin")
        XCTAssertEqual(card.actions[0].style, .primary)
        XCTAssertEqual(card.actions[1].style, .danger)
    }

    func testAResolvedCardTicksOnlyTheChosenAction() throws {
        let resolved = approval.replacingOccurrences(
            of: #""resolved": null"#,
            with: #""resolved": { "action": "Approve", "at": "2026-11-22T10:00:00Z" }"#
        )
        let card = try card(resolved)

        XCTAssertTrue(card.isResolved)
        XCTAssertEqual(card.resolved?.action, "Approve")
        XCTAssertEqual(card.state(of: card.actions[0]), .chosen)
        XCTAssertEqual(card.state(of: card.actions[1]), .locked)
    }

    func testAResolutionMayNameTheSendTextInsteadOfTheLabel() throws {
        let resolved = approval.replacingOccurrences(
            of: #""resolved": null"#,
            with: #""resolved": { "action": "DECLINE c-9b" }"#
        )
        let card = try card(resolved)

        XCTAssertEqual(card.state(of: card.actions[1]), .chosen)
        XCTAssertEqual(card.state(of: card.actions[0]), .locked)
    }

    func testEveryActionIsAvailableBeforeResolution() throws {
        let card = try card(approval)
        XCTAssertEqual(card.state(of: card.actions[0]), .available)
        XCTAssertEqual(card.state(of: card.actions[1]), .available)
    }
}

// MARK: - Leniency

extension CardModelTests {
    func testUnknownFieldsAndBlocksAreIgnored() throws {
        let json = #"""
        {
          "schema": "card.v1",
          "kind": "approval",
          "title": "Ship it?",
          "status": { "state": "pending" },
          "colour": "red",
          "body": [
            { "type": "gallery", "urls": ["https://example.com/x.png"] },
            { "type": "text", "text": "Only this block draws." }
          ],
          "actions": [{ "label": "Go", "send": "GO", "icon": "rocket" }],
          "future": { "nested": [1, 2, 3] }
        }
        """#
        let card = try card(json)

        XCTAssertEqual(card.body.count, 1)
        guard case .text(let text) = card.body[0] else { return XCTFail("the text block survives") }
        XCTAssertEqual(text, "Only this block draws.")
        XCTAssertEqual(card.actions.first?.label, "Go")
        XCTAssertNil(card.actions.first?.style)
    }

    func testABodyBlockWithTheWrongShapeIsDroppedNotFatal() throws {
        let json = #"""
        {
          "schema": "card.v1",
          "kind": "approval",
          "title": "Mixed body",
          "status": { "state": "pending" },
          "body": [
            { "type": "kv", "rows": [["Only a label"]] },
            { "type": "kv", "rows": [["Dates", "Today"]] },
            { "type": "text" }
          ]
        }
        """#
        let card = try card(json)

        XCTAssertEqual(card.body.count, 1)
        guard case .kv(let rows) = card.body[0] else { return XCTFail("the good kv row survives") }
        XCTAssertEqual(rows, [Card.Row(label: "Dates", value: "Today")])
    }

    func testAnActionWithoutASendIsDroppedAndTheOthersStay() throws {
        let json = #"""
        {
          "schema": "card.v1",
          "kind": "approval",
          "title": "Two answers, one broken",
          "status": { "state": "pending" },
          "actions": [
            { "label": "Approve", "send": "APPROVE c-1" },
            { "label": "Half a button" }
          ]
        }
        """#
        let card = try card(json)

        XCTAssertEqual(card.actions.map(\.label), ["Approve"])
    }

    func testMissingOptionalFieldsAreSimplyAbsent() throws {
        let json = #"{"schema":"card.v1","kind":"approval","title":"Bare","status":{"state":"pending"}}"#
        let card = try card(json)

        XCTAssertTrue(card.body.isEmpty)
        XCTAssertTrue(card.actions.isEmpty)
        XCTAssertNil(card.resolved)
        XCTAssertNil(card.status.label)
    }

    func testAnUnknownActionStyleIsANeutralButton() throws {
        let json = #"""
        {
          "schema": "card.v1",
          "kind": "approval",
          "title": "Neutral",
          "status": { "state": "pending" },
          "actions": [{ "label": "OK", "send": "OK", "style": "sparkle" }]
        }
        """#
        let card = try card(json)
        XCTAssertNil(card.actions.first?.style)
    }

    func testAFortyKilobyteBodyDegradesToADrawingCardNotACrash() throws {
        let huge = String(repeating: "x", count: 40 * 1024)
        let json = #"{"schema":"card.v1","kind":"approval","title":"Big","status":{"state":"pending"},"body":[{"type":"text","text":"\#(huge)"}]}"#
        let card = try card(json)

        guard case .text(let text) = card.body[0] else { return XCTFail("the text block survives") }
        XCTAssertEqual(text.count, 40 * 1024)
    }
}

// MARK: - Every named violation

extension CardModelTests {
    func testABadSchemaIsUnavailable() {
        assertUnavailable(#"{"schema":"card.v2","kind":"approval","title":"x","status":{"state":"pending"}}"#)
        assertUnavailable(#"{"kind":"approval","title":"x","status":{"state":"pending"}}"#)
    }

    func testAMissingOrEmptyTitleIsUnavailable() {
        assertUnavailable(#"{"schema":"card.v1","kind":"approval","status":{"state":"pending"}}"#)
        assertUnavailable(#"{"schema":"card.v1","kind":"approval","title":"","status":{"state":"pending"}}"#)
        assertUnavailable(#"{"schema":"card.v1","kind":"approval","title":"   ","status":{"state":"pending"}}"#)
    }

    func testAnUnknownKindIsUnavailable() {
        assertUnavailable(#"{"schema":"card.v1","kind":"quiz","title":"x","status":{"state":"pending"}}"#)
    }

    func testAFourthActionIsUnavailable() {
        assertUnavailable(#"""
        {
          "schema": "card.v1",
          "kind": "approval",
          "title": "Too many answers",
          "status": { "state": "pending" },
          "actions": [
            { "label": "One", "send": "1" },
            { "label": "Two", "send": "2" },
            { "label": "Three", "send": "3" },
            { "label": "Four", "send": "4" }
          ]
        }
        """#)
    }

    func testAnUnknownStatusStateIsUnavailable() {
        assertUnavailable(#"{"schema":"card.v1","kind":"approval","title":"x","status":{"state":"paused"}}"#)
        assertUnavailable(#"{"schema":"card.v1","kind":"approval","title":"x"}"#)
    }

    func testMalformedJSONAndNonObjectRootsAreUnavailable() {
        assertUnavailable("{")
        assertUnavailable("[]")
        assertUnavailable("\"a string\"")
        assertUnavailable("")
    }

    /// `JSONDecoder` rejects syntactically invalid JSON before any `Decodable` initialiser runs, so a
    /// type cannot make *that* call throw-free. The guarantee the app relies on is `CardModel.decode`,
    /// which is total; and `init(from:)` is itself total for anything that parses.
    func testDecodeIsTotalAndTheInitialiserDoesNotThrowOnWellFormedInput() {
        for input in ["not json", "{", "[]", "", "\"a string\""] {
            XCTAssertEqual(CardModel.decode(Data(input.utf8)), CardModel.unavailable(CardModel.unavailableMessage),
                           "decode must return unavailable for \(input)")
        }
        let wrongShape = Data(#"{"schema":"card.v1","kind":"approval"}"#.utf8)
        let parsed = try? JSONSerialization.jsonObject(with: wrongShape)
        XCTAssertNotNil(parsed, "this input is valid JSON, so the decoder reaches our initialiser")
        XCTAssertNoThrow(try JSONDecoder().decode(CardModel.self, from: wrongShape))
        XCTAssertEqual(try? JSONDecoder().decode(CardModel.self, from: wrongShape),
                       CardModel.unavailable(CardModel.unavailableMessage))
    }

    func testTheUnavailableMessageIsTheOneTheSpecNames() {
        XCTAssertEqual(CardModel.unavailableMessage, "Card not available")
        XCTAssertNil(decode(approval).unavailableText)
        XCTAssertEqual(decode("{}").unavailableText, "Card not available")
    }
}

private extension CardModel {
    var unavailableText: String? {
        if case .unavailable(let message) = self { return message }
        return nil
    }
}
