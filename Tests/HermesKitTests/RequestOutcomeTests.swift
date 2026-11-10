import XCTest
@testable import HermesKit

/// `-999 cancelled` under the Bot Computer pane, verbatim from a screenshot, is what these pin:
/// a cancelled request says nothing, and anything else says one readable sentence.
final class RequestOutcomeTests: XCTestCase {

    func testACancelledRequestIsSilent() {
        XCTAssertTrue(RequestOutcome.isCancellation(URLError(.cancelled)))
        XCTAssertNil(RequestOutcome.describe(URLError(.cancelled)))

        // The same thing arriving as a plain NSError, which is how UIKit/SwiftUI usually hand it over.
        let ns = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        XCTAssertTrue(RequestOutcome.isCancellation(ns))
        XCTAssertNil(RequestOutcome.describe(ns))

        XCTAssertTrue(RequestOutcome.isCancellation(CancellationError()))
    }

    func testARealFailureIsNotMistakenForACancellation() {
        XCTAssertFalse(RequestOutcome.isCancellation(URLError(.timedOut)))
        XCTAssertNotNil(RequestOutcome.describe(URLError(.timedOut)))
        XCTAssertFalse(RequestOutcome.isCancellation(URLError(.badServerResponse)))
    }

    func testTheHostThatDidNotAnswerIsNamed() {
        let url = URL(string: "https://hermes.example.ts.net:8443/v1/display/status?profile=assistant")!
        let error = URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: url])
        let text = RequestOutcome.describe(error) ?? ""
        XCTAssertTrue(text.contains("did not answer"), text)
        XCTAssertTrue(text.contains("hermes.example.ts.net"), text)

        let refused = URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: url])
        XCTAssertTrue((RequestOutcome.describe(refused) ?? "").contains("Cannot reach the host"))
    }

    func testNoRawNSErrorDumpEverReachesTheStrip() {
        for code in [URLError.timedOut, .cannotConnectToHost, .networkConnectionLost,
                     .notConnectedToInternet, .badServerResponse, .secureConnectionFailed] {
            let text = RequestOutcome.describe(URLError(code)) ?? ""
            XCTAssertFalse(text.contains("NSURLErrorDomain"), text)
            XCTAssertFalse(text.contains("NSErrorFailingURLStringKey"), text)
            XCTAssertFalse(text.isEmpty, "\(code) produced nothing to show")
        }
    }

    func testOurOwnErrorsKeepTheirOwnSentence() {
        let error = BotComputerError.rejected(status: 401, detail: "invalid, expired or revoked ticket")
        XCTAssertEqual(RequestOutcome.describe(error), error.errorDescription)
    }
}
