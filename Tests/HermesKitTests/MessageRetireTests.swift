import Foundation
import XCTest
@testable import HermesKit

/// The sentence a person reads before a message is retired.
///
/// It is not decoration: the host's routes take one tap and are irreversible on screen (the rows stay
/// recoverable in the database, but they are gone from the conversation everywhere). So the count and
/// the consequence are stated *before* the tap, in the same words on both platforms — and the wording
/// lives in one type for exactly that reason.
final class MessageRetireTests: XCTestCase {

    func testDeleteSaysWhatItTakesAndWhatItKeeps() {
        let action = PendingMessageAction(kind: .delete, rowID: 41, text: "back up the vault", trailing: 0)
        XCTAssertEqual(action.title, "Delete this message?")
        XCTAssertEqual(action.confirmTitle, "Delete")
        XCTAssertEqual(action.message,
                       "“back up the vault” will be retired from this conversation on both devices. "
                       + "Nothing else is touched, and the text stays in the host's database.")
    }

    func testTruncateStatesTheCountItWasGiven() {
        let action = PendingMessageAction(kind: .editAndResend, rowID: 41,
                                          text: "back up the vault", trailing: 12)
        XCTAssertEqual(action.title, "Edit and resend?")
        XCTAssertEqual(action.confirmTitle, "Edit")
        XCTAssertEqual(action.message,
                       "“back up the vault” and the 12 messages after it will be retired when you send "
                       + "the edited text, which then runs as a new turn. Retired messages stay in the "
                       + "host's database.")
    }

    func testOneMessageAfterItIsSaidInTheSingular() {
        let action = PendingMessageAction(kind: .editAndResend, rowID: 1, text: "again", trailing: 1)
        XCTAssertTrue(action.message.contains("and the 1 message after it"), action.message)
        XCTAssertFalse(action.message.contains("messages after it"), action.message)
    }

    /// The last message has nothing after it, and a sentence about "the 0 messages after it" would
    /// read as a bug in the app.
    func testNothingAfterItDropsTheClause() {
        let action = PendingMessageAction(kind: .editAndResend, rowID: 9, text: "the only ask", trailing: 0)
        XCTAssertEqual(action.message,
                       "“the only ask” will be retired when you send the edited text, which then runs "
                       + "as a new turn. Retired messages stay in the host's database.")
    }

    /// A bubble can be 30 000 characters; the confirmation quotes one line of it.
    func testTheQuotationIsOneBoundedLine() {
        let long = String(repeating: "word ", count: 100) + "\n\nsecond paragraph"
        let action = PendingMessageAction(kind: .delete, rowID: 2, text: long, trailing: 0)
        XCTAssertLessThanOrEqual(action.snippet.count, 81)
        XCTAssertTrue(action.snippet.hasSuffix("…"), action.snippet)
        XCTAssertFalse(action.snippet.contains("\n"), "a quotation is one line")

        let empty = PendingMessageAction(kind: .delete, rowID: 3, text: "  \n ", trailing: 0)
        XCTAssertEqual(empty.snippet, "(no text)", "an empty message still has a sentence")
    }

    /// The host's answer, decoded. `retired` is what this call changed — never rows that were already
    /// retired — and `display_count` is the number a resume will report.
    func testTheAnswerIsDecoded() {
        let data = Data(#"{"bot":"cody","session":"20261123_101500_ab12cd","retired":2,"display_count":104}"#
            .utf8)
        let result = MessageRetireResult.decode(data)
        XCTAssertEqual(result, MessageRetireResult(bot: "cody", session: "20261123_101500_ab12cd",
                                                   retired: 2, displayCount: 104))
        XCTAssertNil(MessageRetireResult.decode(Data("{}".utf8)), "an answer with no conversation is not one")
    }

    /// A refusal shows the host's own sentence, because "wait for the turn to finish" and "no such
    /// message" ask the owner for different things.
    func testARefusalKeepsTheHostsOwnWords() {
        let refusal = MessageRetireError.refused(
            status: 409,
            detail: "That conversation is still answering (working) — wait for the turn to finish, "
                + "then try again. Nothing was changed.")
        XCTAssertEqual(refusal.errorDescription,
                       "That conversation is still answering (working) — wait for the turn to finish, "
                       + "then try again. Nothing was changed.")
        XCTAssertEqual(MessageRetireError.refused(status: 500, detail: nil).errorDescription,
                       "The host refused the change (500). Nothing was changed.")
        XCTAssertEqual(MessageRetireError.unreadable.errorDescription,
                       "The host's answer could not be read, so nothing was changed.")
    }
}
