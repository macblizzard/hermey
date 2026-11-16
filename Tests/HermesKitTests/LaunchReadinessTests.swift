import XCTest
@testable import HermesKit

// The launch screen's visibility is one decision, so these are the transitions of that decision:
// what it takes to get off the splash, what ends it early, and what never brings it back. Times are
// supplied by the test, which is the whole reason `LaunchReadiness` has no clock of its own.
final class LaunchReadinessTests: XCTestCase {

    private let t0: TimeInterval = 1_000

    // MARK: - The first frame

    func testLaunchStartsCoveredAndWaiting() {
        let readiness = LaunchReadiness()
        XCTAssertEqual(readiness.phase, .waiting)
        XCTAssertTrue(readiness.showsBootScreen)
        XCTAssertFalse(readiness.isTerminal)
        XCTAssertNil(readiness.startedAt)
    }

    func testTheDefaultDeadlineIsTwelveSeconds() {
        XCTAssertEqual(LaunchReadiness.defaultDeadline, 12)
        XCTAssertEqual(LaunchReadiness().deadline, 12)
    }

    func testANegativeDeadlineIsTreatedAsZero() {
        XCTAssertEqual(LaunchReadiness(deadline: -5).deadline, 0)
    }

    func testBeginIsIdempotent() {
        // A redraw is not a second launch: if `begin` moved the clock, a view that reappeared would
        // restart the deadline and could keep someone on the splash indefinitely.
        var readiness = LaunchReadiness()
        readiness.begin(at: t0)
        readiness.begin(at: t0 + 5)
        XCTAssertEqual(readiness.startedAt, t0)
    }

    func testAdvanceStartsTheClockIfNobodyDid() {
        var readiness = LaunchReadiness()
        readiness.advance(.unanswered, at: t0)
        XCTAssertEqual(readiness.startedAt, t0)
        XCTAssertEqual(readiness.phase, .waiting)
    }

    // MARK: - Waiting is not an answer

    func testAConnectedSocketAloneIsNotUsable() {
        var readiness = LaunchReadiness()
        readiness.begin(at: t0)
        let signals = LaunchReadiness.Signals(isPaired: true, isConnected: true,
                                              connectionFailed: false, rosterAnswered: false,
                                              sessionsAnswered: false)
        XCTAssertEqual(readiness.advance(signals, at: t0 + 0.2), .waiting)
        XCTAssertTrue(readiness.showsBootScreen)
    }

    func testARosterWithoutSessionsIsNotUsable() {
        // The bot list is drawn from `sessions`, not from the roster alone: a list of names with no
        // conversation behind them is the state the launch screen exists to cover.
        var readiness = LaunchReadiness()
        readiness.begin(at: t0)
        let signals = LaunchReadiness.Signals(isPaired: true, isConnected: true,
                                              connectionFailed: false, rosterAnswered: true,
                                              sessionsAnswered: false)
        XCTAssertEqual(readiness.advance(signals, at: t0 + 0.4), .waiting)
    }

    func testSessionsWithoutARosterIsNotUsable() {
        var readiness = LaunchReadiness()
        readiness.begin(at: t0)
        let signals = LaunchReadiness.Signals(isPaired: true, isConnected: true,
                                              connectionFailed: false, rosterAnswered: false,
                                              sessionsAnswered: true)
        XCTAssertEqual(readiness.advance(signals, at: t0 + 0.4), .waiting)
    }

    // MARK: - Ready

    func testEveryAnswerEndsTheSplash() {
        var readiness = LaunchReadiness()
        readiness.begin(at: t0)
        XCTAssertEqual(readiness.advance(.usable, at: t0 + 0.6), .ready)
        XCTAssertFalse(readiness.showsBootScreen)
        XCTAssertTrue(readiness.isTerminal)
    }

    func testAnEmptyRosterStillCountsAsAnswered() {
        // A host with no bots is usable — it is the host that answers "none". The gate is told the
        // ask returned, never asked how many bots came back, so this is the same signal as any
        // other arrival.
        var readiness = LaunchReadiness()
        readiness.begin(at: t0)
        let signals = LaunchReadiness.Signals(isPaired: true, isConnected: true,
                                              connectionFailed: false, rosterAnswered: true,
                                              sessionsAnswered: true)
        XCTAssertEqual(readiness.advance(signals, at: t0 + 0.6), .ready)
    }

    func testReadyIsFinalAndNeverComesBack() {
        // A reconnect an hour later tears the socket down; the splash must not return over a person
        // who is reading a chat.
        var readiness = LaunchReadiness()
        readiness.begin(at: t0)
        readiness.advance(.usable, at: t0 + 0.5)
        let dropped = LaunchReadiness.Signals(isPaired: true, isConnected: false,
                                              connectionFailed: true, rosterAnswered: false,
                                              sessionsAnswered: false)
        XCTAssertEqual(readiness.advance(dropped, at: t0 + 60), .ready)
        XCTAssertFalse(readiness.showsBootScreen)
    }

    // MARK: - Failed, and the hand-offs

    func testAnUnpairedInstallFailsImmediately() {
        // No host, no waiting: the pair screen is the app, and covering it is a wall.
        var readiness = LaunchReadiness()
        readiness.begin(at: t0)
        let signals = LaunchReadiness.Signals(isPaired: false, isConnected: false,
                                              connectionFailed: false, rosterAnswered: false,
                                              sessionsAnswered: false)
        XCTAssertEqual(readiness.advance(signals, at: t0), .failed(.notPaired))
        XCTAssertFalse(readiness.showsBootScreen)
        XCTAssertFalse(readiness.didTimeOut)
    }

    func testAFailedConnectionHandsOffWithoutWaitingForTheDeadline() {
        var readiness = LaunchReadiness()
        readiness.begin(at: t0)
        let signals = LaunchReadiness.Signals(isPaired: true, isConnected: false,
                                              connectionFailed: true, rosterAnswered: false,
                                              sessionsAnswered: false)
        XCTAssertEqual(readiness.advance(signals, at: t0 + 0.3), .failed(.connection))
        XCTAssertFalse(readiness.showsBootScreen)
    }

    func testAFailureBeatsTheDeadlineItWouldHaveHitLater() {
        var readiness = LaunchReadiness()
        readiness.begin(at: t0)
        let signals = LaunchReadiness.Signals(isPaired: true, isConnected: false,
                                              connectionFailed: true, rosterAnswered: false,
                                              sessionsAnswered: false)
        XCTAssertEqual(readiness.advance(signals, at: t0 + 30), .failed(.connection),
                       "the reason must be the failure the app can name, not a timeout")
    }

    func testOnlyTheNotPairedFailureWantsPairingUI() {
        XCTAssertFalse(LaunchReadiness.Failure.notPaired.wantsConnectionUI)
        XCTAssertTrue(LaunchReadiness.Failure.connection.wantsConnectionUI)
        XCTAssertTrue(LaunchReadiness.Failure.deadline.wantsConnectionUI)
    }

    // MARK: - The deadline

    func testAHostThatNeverAnswersExpiresAtTheDeadline() {
        var readiness = LaunchReadiness()
        readiness.begin(at: t0)
        XCTAssertEqual(readiness.advance(.unanswered, at: t0 + 11.99), .waiting)
        XCTAssertEqual(readiness.advance(.unanswered, at: t0 + 12), .failed(.deadline))
        XCTAssertTrue(readiness.didTimeOut)
        XCTAssertFalse(readiness.showsBootScreen)
    }

    func testTheDeadlineOutranksALateAnswer() {
        // At the stroke of the deadline the person is already owed the app's own screen.
        var readiness = LaunchReadiness()
        readiness.begin(at: t0)
        XCTAssertEqual(readiness.advance(.usable, at: t0 + 12), .failed(.deadline))
    }

    func testAnExpiredSplashDoesNotReturnWhenTheHostWakesUp() {
        var readiness = LaunchReadiness()
        readiness.begin(at: t0)
        readiness.advance(.unanswered, at: t0 + 12)
        XCTAssertEqual(readiness.advance(.usable, at: t0 + 40), .failed(.deadline),
                       "a host that answers long after the deadline is the app's problem to show, "
                       + "not a reason to cover it again")
    }

    func testAZeroDeadlineExpiresAtOnce() {
        var readiness = LaunchReadiness(deadline: 0)
        readiness.begin(at: t0)
        XCTAssertEqual(readiness.advance(.unanswered, at: t0), .failed(.deadline))
    }

    func testACustomDeadlineIsHonoured() {
        var readiness = LaunchReadiness(deadline: 3)
        readiness.begin(at: t0)
        XCTAssertEqual(readiness.advance(.unanswered, at: t0 + 2.9), .waiting)
        XCTAssertEqual(readiness.advance(.unanswered, at: t0 + 3), .failed(.deadline))
    }

    // MARK: - The view's single question

    func testOnlyAWaitingPhaseShowsTheLaunchScreen() {
        XCTAssertTrue(LaunchReadiness().showsBootScreen)

        var ready = LaunchReadiness()
        ready.begin(at: t0)
        ready.advance(.usable, at: t0)
        XCTAssertFalse(ready.showsBootScreen)

        for failure in [LaunchReadiness.Failure.notPaired, .connection, .deadline] {
            var failed = LaunchReadiness()
            failed.begin(at: t0)
            switch failure {
            case .notPaired:
                failed.advance(LaunchReadiness.Signals(isPaired: false, isConnected: false,
                                                      connectionFailed: false, rosterAnswered: false,
                                                      sessionsAnswered: false), at: t0)
            case .connection:
                failed.advance(LaunchReadiness.Signals(isPaired: true, isConnected: false,
                                                      connectionFailed: true, rosterAnswered: false,
                                                      sessionsAnswered: false), at: t0)
            case .deadline:
                failed.advance(.unanswered, at: t0 + LaunchReadiness.defaultDeadline)
            }
            XCTAssertEqual(failed.phase, .failed(failure))
            XCTAssertFalse(failed.showsBootScreen, "\(failure) must uncover the app")
        }
    }
}
