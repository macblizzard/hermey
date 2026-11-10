import XCTest
@testable import HermesAppKit

/// The body `POST /v1/pair/claim` takes. The host's model is snake_case; the Mac app posted
/// camelCase and the host answered 422 for a `public_key` that was never sent — with no reason on
/// screen, because the refusal's `detail` is an array.
final class PairClaimBodyTests: XCTestCase {
    private let body = PairClaimBody(code: "14639813",
                                     publicKey: "q83vEjRWeJAqM7Yy0nQ5v3jJ0mZm4BYvRPQj2VfQ0kM=",
                                     deviceName: "MacBook Pro",
                                     platform: "macos")

    func testTheWireUsesTheHostsSnakeCaseNames() throws {
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body.encoded()) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["code", "public_key", "device_name", "platform"])
        XCTAssertEqual(json["code"] as? String, "14639813")
        XCTAssertEqual(json["public_key"] as? String, body.publicKey)
        XCTAssertEqual(json["device_name"] as? String, "MacBook Pro")
        XCTAssertEqual(json["platform"] as? String, "macos")
        XCTAssertNil(json["publicKey"], "camelCase is what the host refused with 422")
        XCTAssertNil(json["deviceName"])
    }

    func testFastAPIsArrayDetailBecomesAReadableReason() {
        let data = Data("""
        {"detail":[{"loc":["body","public_key"],"msg":"field required","type":"missing"}]}
        """.utf8)
        XCTAssertEqual(PairClaimBody.detail(in: data), "public_key: field required")
    }

    func testAHandledRefusalKeepsItsSentence() {
        let data = Data(#"{"detail":"pairing code invalid or expired"}"#.utf8)
        XCTAssertEqual(PairClaimBody.detail(in: data), "pairing code invalid or expired")
    }

    func testAnAnswerWithNoDetailSaysNothingRatherThanGuessing() {
        XCTAssertEqual(PairClaimBody.detail(in: Data("{}".utf8)), "")
        XCTAssertEqual(PairClaimBody.detail(in: Data("not json".utf8)), "")
        XCTAssertEqual(PairClaimBody.detail(in: Data(#"{"detail":42}"#.utf8)), "")
    }
}
