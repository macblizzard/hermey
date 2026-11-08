import XCTest
@testable import HermesKit

/// The decision only — no socket, no bridge, no UserDefaults. `AppModel` carries the plan out;
/// these cases pin what the plan may be.
final class EndlessSessionPolicyTests: XCTestCase {

    private let host = "20260101_120000_host"


    // MARK: Host value wins

    func testHostValueWinsOverTheLocalCache() {
        let plan = EndlessSessionPolicy.plan(host: .value(host), local: "20260101_110000_local")
        XCTAssertEqual(plan.step, .resume(host))
        XCTAssertEqual(plan.origin, .host)
        XCTAssertFalse(plan.publish, "the bridge already holds the id it just gave us")
    }

    func testHostValueIsUsedWithNoLocalKnowledge() {
        let plan = EndlessSessionPolicy.plan(host: .value(host), local: nil)
        XCTAssertEqual(plan.step, .resume(host))
        XCTAssertFalse(plan.publish)
    }

    // MARK: Local fallback

    func testLocalIsUsedAndPublishedWhenTheHostHasNothing() {
        let plan = EndlessSessionPolicy.plan(host: .absent, local: "20260101_110000_local")
        XCTAssertEqual(plan.step, .resume("20260101_110000_local"))
        XCTAssertEqual(plan.origin, .local)
        XCTAssertTrue(plan.publish, "otherwise the other device keeps its own id forever")
    }

    func testLocalIsUsedWhenTheBridgeCannotBeAskedButNothingIsPublished() {
        let plan = EndlessSessionPolicy.plan(host: .unavailable, local: "20260101_110000_local")
        XCTAssertEqual(plan.step, .resume("20260101_110000_local"))
        XCTAssertEqual(plan.origin, .local)
        XCTAssertFalse(plan.publish, "a pointer we could not read may exist and must not be clobbered")
    }

    // MARK: Create

    func testCreateWhenNeitherSideKnows() {
        for state in [EndlessSessionPointerState.absent, .unavailable] {
            let plan = EndlessSessionPolicy.plan(host: state, local: nil)
            XCTAssertEqual(plan.step, .create)
            XCTAssertEqual(plan.origin, .none)
            XCTAssertTrue(plan.publish, "a new conversation has to be announced")
        }
    }

    // MARK: Malformed and absent values

    func testUnusableHostValueIsTreatedAsAbsent() {
        for raw in ["", "   ", "not a session id", "../escape", "20260101_120000_host/../x",
                    String(repeating: "a", count: 129)] {
            let plan = EndlessSessionPolicy.plan(host: .value(raw), local: "20260101_110000_local")
            XCTAssertEqual(plan.step, .resume("20260101_110000_local"), "raw value: \(raw)")
            XCTAssertEqual(plan.origin, .local, "raw value: \(raw)")
            XCTAssertTrue(plan.publish, "a malformed pointer is repaired, not obeyed")
        }
    }

    func testUnusableHostValueWithNoLocalStillCreates() {
        let plan = EndlessSessionPolicy.plan(host: .value("\n"), local: nil)
        XCTAssertEqual(plan.step, .create)
        XCTAssertTrue(plan.publish)
    }

    func testEmptyLocalCacheIsNoKnowledge() {
        for local in [nil, "", "   "] as [String?] {
            let plan = EndlessSessionPolicy.plan(host: .absent, local: local)
            XCTAssertEqual(plan.step, .create)
        }
    }

    // MARK: Normalisation

    func testStoredIDTrimsAndAcceptsTheHostsShape() {
        XCTAssertEqual(EndlessSessionPolicy.storedID(" 20260101_120000_host\n"), host)
        XCTAssertEqual(EndlessSessionPolicy.storedID("abc-123.4"), "abc-123.4")
    }

    func testStoredIDRejectsWhatAResumeCouldNotBeTrustedWith() {
        for raw in [nil, "", "  ", "a", "with space", "with/slash", ".hidden", "quote\"d"] as [String?] {
            XCTAssertNil(EndlessSessionPolicy.storedID(raw), "raw value: \(raw ?? "nil")")
        }
    }
}
