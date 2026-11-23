import XCTest
@testable import HermesCards

/// One valid document per kind, plus the shapes a bot actually writes by mistake.
///
/// The fixtures live here rather than inline in each test so a kind's document is written once:
/// when the skill's wire form changes, the change is one string.
enum CardFixtures {
    /// `approval`: a question with buttons and no status chip.
    static let approval = #"""
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
      ]
    }
    """#

    /// `task`: a job that runs, with a status chip and a Stop button.
    static let task = #"""
    {
      "schema": "card.v1",
      "kind": "task",
      "title": "Fetching the invoices",
      "status": { "state": "running" },
      "body": [
        { "type": "text", "text": "Reading each month and building one CSV." },
        { "type": "kv", "rows": [["Months", "12"], ["Done", "7"]] }
      ],
      "actions": [
        { "label": "Stop", "send": "STOP c-4d", "style": "danger" }
      ]
    }
    """#

    /// `draft-email`: the subject is the heading, `To`/`Cc` are rows, `bodyText` is the message.
    static let draftEmail = #"""
    {
      "schema": "card.v1",
      "kind": "draft-email",
      "title": "Draft to the landlord",
      "status": { "state": "awaiting-approval" },
      "email": {
        "to": "landlord@example.com",
        "cc": "agent@example.com",
        "subject": "The boiler, again",
        "bodyText": "Hi Anna,\n\nThe boiler is out for the third time this month.\n\nCould we get someone on Tuesday?\n\nThanks,\nMo"
      },
      "actions": [
        { "label": "Send", "send": "SEND c-7e", "style": "primary" },
        { "label": "Discard", "send": "DISCARD c-7e", "style": "danger" }
      ]
    }
    """#

    /// A draft with no `cc` and no subject: both are optional, and neither costs the card.
    static let draftEmailBare = #"""
    {
      "schema": "card.v1",
      "kind": "draft-email",
      "title": "Untitled draft",
      "status": { "state": "pending" },
      "email": { "to": "one@example.com" }
    }
    """#

    /// A draft whose `email` is not an object at all: the block is dropped, the card is not.
    static let draftEmailBrokenEmail = #"""
    {
      "schema": "card.v1",
      "kind": "draft-email",
      "title": "Still a draft",
      "status": { "state": "pending" },
      "email": "to: one@example.com"
    }
    """#

    /// A finished task, already resolved to its only action.
    static let resolvedTask = #"""
    {
      "schema": "card.v1",
      "kind": "task",
      "title": "Fetched the invoices",
      "status": { "state": "done" },
      "body": [{ "type": "text", "text": "12 months, one CSV." }],
      "actions": [
        { "label": "Open", "send": "OPEN c-4d" },
        { "label": "Stop", "send": "STOP c-4d", "style": "danger" }
      ],
      "resolved": { "action": "Open", "at": "2026-11-22T10:00:00Z" }
    }
    """#

    /// A card with no actions at all — a task that reports and asks nothing.
    static let taskWithoutActions = #"""
    {
      "schema": "card.v1",
      "kind": "task",
      "title": "Nothing to answer",
      "status": { "state": "done" },
      "actions": []
    }
    """#

    /// A one-line body under 200 characters: it reads as the question under the title.
    static let oneLineBody = #"""
    {
      "schema": "card.v1",
      "kind": "approval",
      "title": "Book the cabin?",
      "status": { "state": "awaiting-approval" },
      "body": [{ "type": "text", "text": "  The cabin is 840 for three nights.  " }],
      "actions": [{ "label": "Approve", "send": "APPROVE c-9b" }]
    }
    """#

    /// The same, but past the rule: a paragraph is a body block, not a question.
    static let longBody = #"""
    {
      "schema": "card.v1",
      "kind": "approval",
      "title": "Long",
      "status": { "state": "awaiting-approval" },
      "body": [{ "type": "text", "text": "REPLACED" }]
    }
    """#
}

/// The three layouts' documents: what each kind decodes into, and the states the view draws them
/// with. The rendering itself is checked by `test_cards_client.py` and by the app's snapshots;
/// here the guarantees are the ones a compiler can prove — every kind decodes, every status reads
/// in words, and a resolved card names its action and locks the rest.
final class CardKindsTests: XCTestCase {

    private func card(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> Card {
        guard case .available(let card) = CardModel.decode(Data(json.utf8)) else {
            XCTFail("expected an available card", file: file, line: line)
            throw XCTSkip("decoding failed")
        }
        return card
    }

    // MARK: - The kinds

    func testTheThreeKindsAreTheOnesTheSpecNames() {
        XCTAssertEqual(Card.Kind.allCases, [.approval, .task, .draftEmail])
        XCTAssertEqual(Card.Kind(wire: "draft-email"), .draftEmail)
        XCTAssertEqual(Card.Kind(wire: "task"), .task)
        for wire in ["draft_email", "Task", "quiz", ""] {
            XCTAssertNil(Card.Kind(wire: wire), wire)
        }
    }

    func testATaskCardDecodesItsStatusChipAndBody() throws {
        let card = try card(CardFixtures.task)

        XCTAssertEqual(card.kind, .task)
        XCTAssertEqual(card.status.state, .running)
        XCTAssertEqual(card.status.chipText, "Running")
        XCTAssertEqual(card.body.count, 2)
        XCTAssertEqual(card.actions.map(\.label), ["Stop"])
        XCTAssertEqual(card.actions.first?.style, .danger)
        XCTAssertNil(card.email)
        XCTAssertNil(card.resolved)
    }

    func testTheStatusChipPrefersTheBotsOwnLabel() throws {
        let json = CardFixtures.task.replacingOccurrences(
            of: #""status": { "state": "running" }"#,
            with: #""status": { "state": "running", "label": "Reading month 8 of 12" }"#
        )
        let card = try card(json)

        XCTAssertEqual(card.status.state, .running)
        XCTAssertEqual(card.status.chipText, "Reading month 8 of 12")
    }

    func testEveryStatusStateReadsInWords() {
        XCTAssertEqual(Card.StatusState.pending.chipText, "Pending")
        XCTAssertEqual(Card.StatusState.running.chipText, "Running")
        XCTAssertEqual(Card.StatusState.done.chipText, "Done")
        XCTAssertEqual(Card.StatusState.error.chipText, "Error")
        XCTAssertEqual(Card.StatusState.awaitingApproval.chipText, "Awaiting approval")
    }

    func testABlankLabelFallsBackToTheStateWord() {
        let status = Card.Status(state: .done, label: "   ")
        XCTAssertEqual(status.chipText, "Done")
    }

    // MARK: - Draft email

    func testADraftEmailCardDecodesToCcSubjectAndBody() throws {
        let card = try card(CardFixtures.draftEmail)

        XCTAssertEqual(card.kind, .draftEmail)
        XCTAssertEqual(card.email?.to, "landlord@example.com")
        XCTAssertEqual(card.email?.cc, "agent@example.com")
        XCTAssertEqual(card.email?.subject, "The boiler, again")
        XCTAssertEqual(card.heading, "The boiler, again")
        // The paragraph breaks are the message: they survive decoding untouched.
        XCTAssertEqual(card.email?.bodyText?.contains("\n\n"), true)
        XCTAssertEqual(card.actions.map(\.label), ["Send", "Discard"])
    }

    func testADraftWithoutASubjectIsHeadedByItsTitle() throws {
        let card = try card(CardFixtures.draftEmailBare)

        XCTAssertEqual(card.email?.to, "one@example.com")
        XCTAssertNil(card.email?.cc)
        XCTAssertNil(card.email?.subject)
        XCTAssertEqual(card.heading, "Untitled draft")
        XCTAssertTrue(card.actions.isEmpty)
    }

    func testADraftWhoseEmailBlockIsBrokenStillDraws() throws {
        let card = try card(CardFixtures.draftEmailBrokenEmail)

        XCTAssertEqual(card.kind, .draftEmail)
        XCTAssertNil(card.email, "a non-object email is dropped, not fatal")
        XCTAssertEqual(card.heading, "Still a draft")
    }

    func testABlankBodyTextIsNoBodyAtAll() throws {
        let json = CardFixtures.draftEmailBare.replacingOccurrences(
            of: #""email": { "to": "one@example.com" }"#,
            with: #""email": { "to": "one@example.com", "bodyText": "   \n  " }"#
        )
        let card = try card(json)
        XCTAssertNil(card.email?.bodyText)
    }

    func testAResolvedDraftEmailLocksSendAndDiscard() throws {
        let json = CardFixtures.draftEmail.replacingOccurrences(
            of: #""actions": ["#,
            with: #""resolved": { "action": "SEND c-7e" }, "actions": ["#
        )
        let card = try card(json)

        XCTAssertTrue(card.isResolved)
        XCTAssertEqual(card.resolvedLabel, "Send", "the send text resolves to the button's label")
        XCTAssertEqual(card.state(of: card.actions[0]), .chosen)
        XCTAssertEqual(card.state(of: card.actions[1]), .locked)
    }

    // MARK: - Resolved and empty

    func testAResolvedTaskNamesTheActionItTook() throws {
        let card = try card(CardFixtures.resolvedTask)

        XCTAssertEqual(card.status.state, .done)
        XCTAssertEqual(card.resolvedLabel, "Open")
        XCTAssertEqual(card.state(of: card.actions[0]), .chosen)
        XCTAssertEqual(card.state(of: card.actions[1]), .locked)
    }

    func testAResolutionThatNamesNoButtonIsStillShown() throws {
        let json = CardFixtures.resolvedTask.replacingOccurrences(
            of: #""action": "Open""#,
            with: #""action": "opened it myself""#
        )
        let card = try card(json)

        XCTAssertEqual(card.resolvedLabel, "opened it myself")
        XCTAssertEqual(card.state(of: card.actions[0]), .locked)
        XCTAssertEqual(card.state(of: card.actions[1]), .locked)
    }

    func testACardWithNoActionsIsStillACard() throws {
        let card = try card(CardFixtures.taskWithoutActions)

        XCTAssertTrue(card.actions.isEmpty)
        XCTAssertNil(card.resolvedLabel)
        XCTAssertEqual(card.status.chipText, "Done")
    }

    func testAnUnresolvedCardHasNoResolvedLabel() throws {
        let unresolved = try card(CardFixtures.approval)
        XCTAssertNil(unresolved.resolvedLabel)
    }

    // MARK: - The one-line rule

    func testASingleShortLineIsTheLeadLine() throws {
        let card = try card(CardFixtures.oneLineBody)

        XCTAssertEqual(card.leadText, "The cabin is 840 for three nights.",
                       "trimmed, and read as the question under the title")
    }

    func testAMultiLineOrLongBodyIsNotALeadLine() throws {
        let twoLines = CardFixtures.oneLineBody.replacingOccurrences(
            of: "The cabin is 840 for three nights.",
            with: "The cabin is 840.\\nDo you want it?"
        )
        let wrapped = try card(twoLines)
        XCTAssertNil(wrapped.leadText, "a line break is a paragraph, not a question")

        let long = String(repeating: "a", count: 200)
        let longBody = try card(CardFixtures.longBody.replacingOccurrences(of: "REPLACED", with: long))
        XCTAssertNil(longBody.leadText, "200 characters is no longer one line")

        // A body of two blocks is a layout, whatever the first block says.
        let twoBlocks = try card(
            CardFixtures.oneLineBody.replacingOccurrences(
                of: #""body": [{ "type": "text", "text": "  The cabin is 840 for three nights.  " }]"#,
                with: #""body": [{ "type": "text", "text": "Short." }, { "type": "kv", "rows": [["a", "b"]] }]"#
            )
        )
        XCTAssertNil(twoBlocks.leadText)
    }

    func testAnEmptyBodyDrawsNothingAtAll() throws {
        let card = try card(CardFixtures.taskWithoutActions)
        XCTAssertTrue(card.body.isEmpty)
        XCTAssertNil(card.leadText)
    }
}
