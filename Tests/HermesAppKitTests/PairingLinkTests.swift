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

    /// The bug this guards: a fresh Mac has no remembered host, so a code from `hermey pair` parsed
    /// to nil and the sheet told the person it was "not a pairing code" — the digits never reached
    /// the host. A code with nowhere to go is a *code plus a missing address*, and the sheet has to
    /// be able to tell that from a bad paste.
    func testABareCodeWithNoHostAnywhereAsksForTheAddress() {
        XCTAssertEqual(PairingLink.classify("64251508"), .codeNeedingHost("64251508"))
        XCTAssertEqual(PairingLink.classify("  64251508\n"), .codeNeedingHost("64251508"))
        XCTAssertEqual(PairingLink.classify("64251508", defaultHost: ""), .codeNeedingHost("64251508"),
                       "an empty address is not an address")
    }

    /// The address typed into the sheet is what the digits are claimed against on a first pairing.
    func testACodeAndATypedAddressPair() {
        guard case .link(let link) = PairingLink.classify("64251508", defaultHost: "https://new.example.ts.net:8443") else {
            return XCTFail("a code plus an address must be a link")
        }
        XCTAssertEqual(link.code, "64251508")
        XCTAssertEqual(link.httpBase, "https://new.example.ts.net:8443")
        XCTAssertEqual(link.websocketBase, "wss://new.example.ts.net:8443")
    }

    /// A known host still fills in for a link that omits `host=` — the phone's `hermes://pair?code=`
    /// shape — so re-pairing does not need the address typed again.
    func testALinkWithoutAHostUsesTheAddressItIsGiven() {
        guard case .link(let link) = PairingLink.classify("hermes://pair?code=12345678", defaultHost: "h.example:8443") else {
            return XCTFail("the address in the sheet must be used")
        }
        XCTAssertEqual(link.websocketBase, "wss://h.example:8443")
    }

    /// Everything that is neither a code nor a link carrying one stays unusable, so the sheet can
    /// still say so.
    func testSomethingElseIsUnusable() {
        XCTAssertEqual(PairingLink.classify("hello"), .unusable)
        XCTAssertEqual(PairingLink.classify("hermes://pair?host=https%3A%2F%2Fh.example"), .unusable)
        XCTAssertEqual(PairingLink.classify("wss://hermes.example.ts.net:8443"), .unusable,
                       "an address alone is not a pairing")
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
