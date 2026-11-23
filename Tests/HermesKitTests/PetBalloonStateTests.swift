import XCTest
@testable import HermesKit

/// The balloon's transitions: idle → asking → answered / sent-but-silent / failed, one at a time.
///
/// The field being disabled while a question is in flight is a UI detail; the state machine is the
/// rule. These tests hold the two fixed sentences the design chose, because they are what the owner
/// reads when a bot is slow or a host is down.
final class PetBalloonStateTests: XCTestCase {

    func testAFreshBalloonIsIdle() {
        let state = PetBalloonState.idle
        XCTAssertFalse(state.isAsking)
        XCTAssertTrue(state.acceptsInput)
        XCTAssertNil(state.question)
        XCTAssertNil(state.answer)
        XCTAssertNil(state.failure)
        XCTAssertFalse(state.canRetry)
    }

    func testAskingTrimsAndRemembersTheQuestion() {
        var state = PetBalloonState.idle
        XCTAssertTrue(state.ask("  what are you working on?  "))
        XCTAssertEqual(state, .asking(question: "what are you working on?"))
        XCTAssertTrue(state.isAsking)
        XCTAssertFalse(state.acceptsInput)
        XCTAssertEqual(state.question, "what are you working on?")
    }

    func testBlankTextIsNotAQuestion() {
        var state = PetBalloonState.idle
        XCTAssertFalse(state.ask("   \n "))
        XCTAssertEqual(state, .idle, "a stray Return must not clear the field or start a turn")
    }

    func testASecondQuestionIsRefusedWhileOneIsInFlight() {
        var state = PetBalloonState.idle
        XCTAssertTrue(state.ask("first"))
        XCTAssertFalse(state.ask("second"), "one question at a time per pet")
        XCTAssertEqual(state, .asking(question: "first"))
    }

    func testAReplyBecomesTheAnswer() {
        var state = PetBalloonState.idle
        XCTAssertTrue(state.ask("status?"))
        state.receive(reply: "  all green  ")
        XCTAssertEqual(state, .answered(question: "status?", reply: "all green"))
        XCTAssertEqual(state.answer, "all green")
        XCTAssertNil(state.failure)
        XCTAssertFalse(state.canRetry)
        XCTAssertTrue(state.acceptsInput, "the field takes the next question once one has landed")
    }

    func testASilentTurnIsTheTimeoutSentenceNotAnEmptyAnswer() {
        var state = PetBalloonState.idle
        XCTAssertTrue(state.ask("status?"))
        state.receive(reply: nil)
        XCTAssertEqual(state, .unanswered(question: "status?"))
        XCTAssertEqual(state.failure, "Sent — it hasn't answered yet.")
        XCTAssertTrue(state.canRetry)
        XCTAssertNil(state.answer)

        var blank = PetBalloonState.idle
        XCTAssertTrue(blank.ask("status?"))
        blank.receive(reply: "   ")
        XCTAssertEqual(blank, .unanswered(question: "status?"))
    }

    func testARefusalKeepsTheHostsSentenceVerbatim() {
        var state = PetBalloonState.idle
        XCTAssertTrue(state.ask("are you there?"))
        state.fail("no conversation yet")
        XCTAssertEqual(state, .failed(question: "are you there?", message: "no conversation yet"))
        XCTAssertEqual(state.failure, "no conversation yet")
        XCTAssertTrue(state.canRetry)
    }

    func testAnEmptyFailureFallsBackToTheUnreachableSentence() {
        var state = PetBalloonState.idle
        XCTAssertTrue(state.ask("hello?"))
        state.fail("  ")
        XCTAssertEqual(state.failure, PetBalloonState.unreachableText)
    }

    func testRetryReSendsTheSameQuestion() {
        var state = PetBalloonState.idle
        XCTAssertTrue(state.ask("status?"))
        state.receive(reply: nil)
        XCTAssertTrue(state.retry())
        XCTAssertEqual(state, .asking(question: "status?"))
        XCTAssertFalse(state.acceptsInput)
    }

    func testRetryDoesNothingWithoutSomethingToRetry() {
        var idle = PetBalloonState.idle
        XCTAssertFalse(idle.retry())
        XCTAssertEqual(idle, .idle)

        var asking = PetBalloonState.idle
        XCTAssertTrue(asking.ask("status?"))
        XCTAssertFalse(asking.retry(), "a turn already in flight is not retried twice")
        XCTAssertEqual(asking, .asking(question: "status?"))
    }

    func testALateAnswerForADismissedBalloonIsDropped() {
        var state = PetBalloonState.idle
        XCTAssertTrue(state.ask("status?"))
        state.dismiss()
        XCTAssertEqual(state, .idle)
        // The request was cancelled, but a reply that raced it must not paint a bubble nobody opened.
        state.receive(reply: "late")
        XCTAssertEqual(state, .idle)
        state.fail("late error")
        XCTAssertEqual(state, .idle)
    }

    func testDismissResetsEverything() {
        var state = PetBalloonState.idle
        XCTAssertTrue(state.ask("status?"))
        state.receive(reply: "fine")
        state.dismiss()
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(state.acceptsInput)
        XCTAssertNil(state.answer)
    }
}
