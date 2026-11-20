import XCTest
@testable import HermesKit

/// The classifier behind the one silent retry in `AppModel.openStoredConversation`: a dead socket is
/// worth dialling again, a refused resume is not.
final class TransportFailureTests: XCTestCase {

    func test_aDeadSocketIsATransportFailure() {
        XCTAssertTrue(TransportFailure.isTransport(
            GatewayError.transportClosed("Software caused connection abort")))
        XCTAssertTrue(TransportFailure.isTransport(GatewayError.notConnected))
        XCTAssertTrue(TransportFailure.isTransport(GatewayError.handshakeTimedOut))
        XCTAssertTrue(TransportFailure.isTransport(
            GatewayError.timeout(method: "session.resume", seconds: 60)))
        XCTAssertTrue(TransportFailure.isTransport(TransportError.notConnected))
    }

    func test_thePlatformSpellingsOfTheSameAbortAreTransportFailures() {
        // The same dead socket reaches the app three ways, depending on which layer noticed it
        // first — a bare `URLSessionWebSocketTask` error, a Foundation error, or a POSIX one. The
        // user's report ("Software caused connection abort") is the POSIX name of the middle case.
        XCTAssertTrue(TransportFailure.isTransport(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)))
        XCTAssertTrue(TransportFailure.isTransport(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
        XCTAssertTrue(TransportFailure.isTransport(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)))
        XCTAssertTrue(TransportFailure.isTransport(NSError(domain: NSPOSIXErrorDomain, code: 53)))
        XCTAssertTrue(TransportFailure.isTransport(NSError(domain: NSPOSIXErrorDomain, code: 54)))
    }

    func test_aRefusedResumeIsNotATransportFailure() {
        // The host answered. Replacing one of these is how a live conversation gets mistaken for an
        // empty bot, so nothing here may be retried or papered over.
        XCTAssertFalse(TransportFailure.isTransport(
            GatewayError.rpc(RPCError(code: 4001, message: "session not found"))))
        XCTAssertFalse(TransportFailure.isTransport(
            GatewayError.rpc(RPCError(code: 4007, message: "session not found"))))
        XCTAssertFalse(TransportFailure.isTransport(
            GatewayError.rpc(RPCError(code: -32602, message: "invalid params"))))
        XCTAssertFalse(TransportFailure.isTransport(
            GatewayError.malformedResponse(method: "session.resume")))
        XCTAssertFalse(TransportFailure.isTransport(GatewayError.cancelled))
        XCTAssertFalse(TransportFailure.isTransport(
            GatewayError.needsEmptyTranscriptConfirmation("this would erase the transcript")))
    }

    func test_anUndiallableURLAndAnUnrelatedErrorAreNot() {
        XCTAssertFalse(TransportFailure.isTransport(TransportError.badURL("no scheme")))
        XCTAssertFalse(TransportFailure.isTransport(NSError(domain: NSPOSIXErrorDomain, code: 2)))
        XCTAssertFalse(TransportFailure.isTransport(NSError(domain: "SomeOtherDomain", code: 1)))
    }
}
