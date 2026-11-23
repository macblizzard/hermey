import XCTest
@testable import HermesCards

/// A live draft: four fields the owner can type into, and two answers.
///
/// The view itself is drawn by `test_cards_client.py`'s source guards (there is no SwiftUI
/// snapshot harness in this package); what is pinned here is every decision the view only *reads*:
/// which card can be typed into, what the composed turn says, and which of the file's actions
/// supplies the token that leads it.
final class DraftEditingTests: XCTestCase {

    private func card(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> Card {
        guard case .available(let card) = CardModel.decode(Data(json.utf8)) else {
            XCTFail("expected an available card", file: file, line: line)
            throw XCTSkip("decoding failed")
        }
        return card
    }

    private func draft(file: StaticString = #filePath, line: UInt = #line) throws -> Card {
        try card(CardFixtures.draftEmail, file: file, line: line)
    }

    /// The resolved copy of the draft fixture: exactly the document a bot writes after a send.
    /// The action is encoded as JSON — a composed block is many lines, and a raw newline is not a
    /// JSON string.
    private func resolvedDraft(_ chosen: String) throws -> Card {
        let literal = String(decoding: try JSONEncoder().encode(chosen), as: UTF8.self)
        return try card(CardFixtures.draftEmail.replacingOccurrences(
            of: #""actions": ["#,
            with: #""resolved": { "action": \#(literal) }, "actions": ["#
        ))
    }

    // MARK: - Which cards can be typed into

    func testALiveDraftOpensReadyToTypeItsOwnValues() throws {
        let card = try draft()

        // No mode, no tap: the editor the view uses is available the moment the card is.
        let editor = try XCTUnwrap(DraftEditor.editor(for: card))
        XCTAssertEqual(editor.to, "landlord@example.com")
        XCTAssertEqual(editor.cc, "agent@example.com")
        XCTAssertEqual(editor.subject, "The boiler, again")
        XCTAssertEqual(editor.body, "Hi Anna,\n\nThe boiler is out for the third time this month.\n\nCould we get someone on Tuesday?\n\nThanks,\nMo")
    }

    func testAResolvedDraftCannotBeTypedInto() throws {
        let card = try resolvedDraft("SEND c-7e")

        XCTAssertTrue(card.isResolved)
        XCTAssertNil(DraftEditor.editor(for: card), "an answered card is a receipt, not a form")
    }

    func testADraftWithNoEmailBlockCannotBeTypedInto() throws {
        let card = try card(CardFixtures.draftEmailBrokenEmail)

        XCTAssertNil(card.email)
        XCTAssertNil(DraftEditor.editor(for: card), "there is nothing to edit; the card draws as before")
    }

    func testOtherKindsAreNeverTypedInto() throws {
        XCTAssertNil(DraftEditor.editor(for: try card(CardFixtures.approval)))
        XCTAssertNil(DraftEditor.editor(for: try card(CardFixtures.task)))
    }

    // MARK: - What Send posts

    func testTheEditsAreWhatTheSendCarries() throws {
        let card = try draft()
        var editor = try XCTUnwrap(DraftEditor.editor(for: card))
        editor.to = "anna@example.com"
        editor.cc = ""
        editor.subject = "The boiler, Tuesday?"
        editor.body = "Hi Anna,\n\nTuesday works.\n\nMo"

        let action = try XCTUnwrap(card.draftSendAction)
        XCTAssertEqual(action.send, "SEND c-7e")
        XCTAssertEqual(editor.composedSend(lead: action.send), """
            SEND c-7e
            send this email exactly as written:
            To: anna@example.com
            Subject: The boiler, Tuesday?
            ---
            Hi Anna,

            Tuesday works.

            Mo
            """)
        // Nothing of the file's original text survives a field the owner rewrote.
        XCTAssertFalse(editor.composedSend(lead: action.send).contains("third time this month"))
    }

    func testTheCardsOwnSendIsTheFirstLine() throws {
        let card = try draft()
        let editor = try XCTUnwrap(DraftEditor.editor(for: card))
        let action = try XCTUnwrap(card.draftSendAction)

        let lines = editor.composedSend(lead: action.send).components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "SEND c-7e", "the agent still sees the card's own intent")
        XCTAssertEqual(lines.dropFirst().first, DraftEditor.instruction)
        XCTAssertEqual(lines.first(where: { $0.hasPrefix("Cc: ") }), "Cc: agent@example.com")
        XCTAssertTrue(lines.contains("Subject: The boiler, again"))
        XCTAssertTrue(lines.contains("---"))
    }

    func testTheCcLineIsOmittedWhenEmpty() throws {
        let card = try card(CardFixtures.draftEmailBare)
        var editor = try XCTUnwrap(DraftEditor.editor(for: card))
        editor.body = "Hi."

        let block = editor.composedSend(lead: "SEND c-7e")
        XCTAssertFalse(block.contains("Cc:"))
        XCTAssertEqual(block, "SEND c-7e\nsend this email exactly as written:\n"
                       + "To: one@example.com\nSubject: \n---\nHi.")
    }

    func testADraftWithNoUsableActionStillComposesAWholeBlock() throws {
        let card = try card(CardFixtures.draftEmailBare)
        XCTAssertTrue(card.actions.isEmpty)
        XCTAssertNil(card.draftSendAction)

        let editor = try XCTUnwrap(DraftEditor.editor(for: card))
        XCTAssertTrue(editor.composedSend(lead: nil).hasPrefix(DraftEditor.instruction + "\n"),
                      "no token to lead with, so the instruction is the whole first line")
    }

    func testAHeaderFieldIsOneLine() throws {
        var editor = DraftEditor()
        editor.to = "  one@example.com\nBcc: two@example.com  "
        editor.subject = "Two\nlines"
        editor.body = "Body."

        let block = editor.composedSend(lead: nil)
        XCTAssertTrue(block.contains("To: one@example.com Bcc: two@example.com\n"))
        XCTAssertTrue(block.contains("Subject: Two lines\n"))
    }

    func testAnEmptyBodyStillEndsTheBlockAfterTheRule() throws {
        let editor = DraftEditor(to: "one@example.com", subject: "Hi", body: "   \n ")
        XCTAssertEqual(editor.composedSend(lead: nil), """
            send this email exactly as written:
            To: one@example.com
            Subject: Hi
            ---
            """)
    }

    // MARK: - Which action supplies the token

    func testThePrimaryActionIsTheSend() throws {
        let card = try draft()
        XCTAssertEqual(card.draftSendAction?.label, "Send")
        XCTAssertEqual(card.draftSendAction?.send, "SEND c-7e")
    }

    func testAnEditActionIsNeverTheSend() throws {
        let json = CardFixtures.draftEmail.replacingOccurrences(
            of: #""actions": ["#,
            with: #""actions": [{ "label": "Edit", "send": "EDIT c-7e" }, "#
        )
        let card = try card(json)

        XCTAssertEqual(card.draftSendAction?.label, "Send", "Edit carries no token worth posting")
        XCTAssertEqual(card.draftSendAction?.send, "SEND c-7e")
    }

    func testThePositionDecidesWhenTheFilesWordsDoNot() throws {
        // "Approve" and "Decline" on a draft: the primary is the send, whatever it is called.
        let json = CardFixtures.draftEmail
            .replacingOccurrences(of: "SEND c-7e", with: "APPROVE c-7e")
            .replacingOccurrences(of: "DISCARD c-7e", with: "DROP c-7e")
        // `card` cannot be both the value and the helper that makes it: the local shadows the function,
        // and the second call in this method reads as a call on the value.
        let renamed = try card(json)
        XCTAssertEqual(renamed.draftSendAction?.send, "APPROVE c-7e")

        // One action, no style: it is the send.
        let single = try card(CardFixtures.draftEmailBare.replacingOccurrences(
            of: #""email": { "to": "one@example.com" }"#,
            with: #""email": { "to": "one@example.com" }, "actions": [{ "label": "Send it", "send": "GO c-1" }]"#
        ))
        XCTAssertEqual(single.draftSendAction?.send, "GO c-1")

        // Only a destructive action: it is still the only intent there is.
        let dangerOnly = try card(CardFixtures.draftEmailBare.replacingOccurrences(
            of: #""email": { "to": "one@example.com" }"#,
            with: #""email": { "to": "one@example.com" }, "actions": [{ "label": "Stop", "send": "STOP c-1", "style": "danger" }]"#
        ))
        XCTAssertEqual(dangerOnly.draftSendAction?.send, "STOP c-1")
    }

    func testTheRolesReadTheCardsOwnLabels() {
        XCTAssertEqual(Card.Action(label: "Edit", send: "x").draftRole, .edit)
        XCTAssertEqual(Card.Action(label: "EDIT", send: "x").draftRole, .edit)
        XCTAssertEqual(Card.Action(label: " edit draft ", send: "x").draftRole, .edit)
        XCTAssertEqual(Card.Action(label: "Send", send: "x").draftRole, .send)
        XCTAssertEqual(Card.Action(label: "Send email", send: "x").draftRole, .send)
        XCTAssertEqual(Card.Action(label: "Discard", send: "x").draftRole, .other)
        XCTAssertEqual(Card.Action(label: "Approve", send: "x").draftRole, .other)
    }

    // MARK: - Typing never touches the card

    func testTypingLeavesTheCardsDocumentAlone() throws {
        let card = try draft()
        var editor = try XCTUnwrap(DraftEditor.editor(for: card))
        editor.subject = "Something else"
        editor.body = "Rewritten."

        // Dropping the value is the whole undo: the card is still exactly what the bot wrote.
        XCTAssertEqual(DraftEditor.editor(for: card)?.subject, "The boiler, again")
        XCTAssertEqual(DraftEditor.editor(for: card)?.body, card.email?.bodyText)
    }

    // MARK: - The note under a sent draft

    func testASentEditedDraftStillNamesTheButtonThatSentIt() throws {
        let source = try draft()
        let editor = try XCTUnwrap(DraftEditor.editor(for: source))
        let action = try XCTUnwrap(source.draftSendAction)
        let posted = Card.Action(label: "Send",
                                 send: editor.composedSend(lead: action.send),
                                 style: .primary)
        let answered = try resolvedDraft(posted.send)

        XCTAssertTrue(answered.isResolved)
        XCTAssertEqual(answered.resolvedLabel, "Send",
                       "the composed block leads with `SEND c-7e`, so the note is the button, not the email")
        XCTAssertEqual(answered.state(of: answered.actions[0]), .chosen)
        XCTAssertEqual(answered.state(of: answered.actions[1]), .locked)
    }
}
