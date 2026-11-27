import XCTest
@testable import HermesKit

/// The one decision that says whether a socket may be opened in plaintext.
///
/// Every case here is a real shape that reached one of the three copies this type replaced: a
/// bracket-stripped `::1` that never matched `"[::1]"`, a `127.0.0.2` that a string compare against
/// `"127.0.0.1"` called remote, and a tailnet name that a `ws` branch happily dialled.
final class LoopbackHostTests: XCTestCase {
    func testThisMachineInEverySpellingURLComponentsProduces() {
        XCTAssertTrue(LoopbackHost.isLoopback("127.0.0.1"))
        XCTAssertTrue(LoopbackHost.isLoopback("127.0.0.2"))
        XCTAssertTrue(LoopbackHost.isLoopback("127.0.0.53"))
        XCTAssertTrue(LoopbackHost.isLoopback("localhost"))
        XCTAssertTrue(LoopbackHost.isLoopback("LocalHost"))
        XCTAssertTrue(LoopbackHost.isLoopback("hermes.localhost"))
        // URLComponents hands back IPv6 without its brackets; a person types it with them.
        XCTAssertTrue(LoopbackHost.isLoopback("::1"))
        XCTAssertTrue(LoopbackHost.isLoopback("[::1]"))
        XCTAssertTrue(LoopbackHost.isLoopback("0:0:0:0:0:0:0:1"))
    }

    func testEverythingElseIsReachedOverTheNetwork() {
        XCTAssertFalse(LoopbackHost.isLoopback("hermes.example.ts.net"))
        XCTAssertFalse(LoopbackHost.isLoopback("192.168.1.10"))
        XCTAssertFalse(LoopbackHost.isLoopback("10.0.0.1"))
        // The unspecified address is "listen here", not "this is me".
        XCTAssertFalse(LoopbackHost.isLoopback("0.0.0.0"))
        XCTAssertFalse(LoopbackHost.isLoopback("::"))
        XCTAssertFalse(LoopbackHost.isLoopback(nil))
        XCTAssertFalse(LoopbackHost.isLoopback(""))
        // A host that merely starts like a loopback address is not one.
        XCTAssertFalse(LoopbackHost.isLoopback("127.0.0.1.evil.example"))
        XCTAssertFalse(LoopbackHost.isLoopback("127.example.com"))
        XCTAssertFalse(LoopbackHost.isLoopback("1270.0.0.1"))
        XCTAssertFalse(LoopbackHost.isLoopback("localhost.evil.example"))
    }
}
