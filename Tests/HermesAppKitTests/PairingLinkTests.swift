import XCTest
@testable import HermesAppKit

/// A code reaches a Mac in whatever shape the person happened to copy — the phone's deep link, a bare
/// string read off a terminal, or a URL from a transcript. The sheet must accept all of them, and
/// refuse anything else loudly instead of claiming a device row it cannot finish pairing.
final class PairingLinkTests: XCTestCase {
    func testDeepLinkCarriesBothHostAndCode() {
        let link = PairingLink.parse("hermes://pair?host=https%3A%2F%2Fhermes.example.ts.net%3A8443&code=14639813")

        XCTAssertEqual(link?.code, "14639813")
        XCTAssertEqual(link?.httpBase, "https://hermes.example.ts.net:8443")
        XCTAssertEqual(link?.websocketBase, "wss://hermes.example.ts.net:8443")
    }

    func testABareCodeUsesTheHostThisMacAlreadyKnows() {
        let link = PairingLink.parse("64251508", defaultHost: "wss://hermes.example.ts.net:8443")

        XCTAssertEqual(link?.code, "64251508")
        XCTAssertEqual(link?.httpBase, "https://hermes.example.ts.net:8443")
    }

    func testABareCodeWithoutAHostIsRefused() {
        XCTAssertNil(PairingLink.parse("64251508"), "no host to pair with — the sheet must ask for one")
    }

    func testAUrlThatCarriesACodeInItsQueryNamesItsOwnHost() {
        let link = PairingLink.parse("https://hermes.example.ts.net:8443/?code=12345678")

        XCTAssertEqual(link?.code, "12345678")
        XCTAssertEqual(link?.websocketBase, "wss://hermes.example.ts.net:8443")
    }

    func testAPasteSurvivesQuotesWhitespaceAndNewlines() {
        let link = PairingLink.parse("  \"hermes://pair?host=https%3A%2F%2Fh.example%3A8443&code=12345678\"\n")

        XCTAssertEqual(link?.code, "12345678")
        XCTAssertEqual(link?.httpBase, "https://h.example:8443")
    }

    func testHostWithoutASchemeGetsOne() {
        let link = PairingLink.parse("hermes.example.ts.net:8443/?code=12345678")

        XCTAssertEqual(link?.httpBase, "https://hermes.example.ts.net:8443")
    }

    func testThingsThatAreNotPairingsAreRefused() {
        XCTAssertNil(PairingLink.parse(""))
        XCTAssertNil(PairingLink.parse("   "))
        XCTAssertNil(PairingLink.parse("hello"))
        XCTAssertNil(PairingLink.parse("hermes://pair?host=https%3A%2F%2Fh.example"))
        XCTAssertNil(PairingLink.parse("hermes://pair?code=abc"), "a code is digits only")
        XCTAssertNil(PairingLink.parse("wss://hermes.example.ts.net:8443"), "an address alone is not a pairing")
    }

    func testCodeLengthHasSomeRoom() {
        // The bridge mints eight digits today; a shorter or longer code is still a code.
        XCTAssertNotNil(PairingLink.parse("123456", defaultHost: "h.example"))
        XCTAssertNotNil(PairingLink.parse("123456789012", defaultHost: "h.example"))
        XCTAssertNil(PairingLink.parse("12345", defaultHost: "h.example"))
    }
}
