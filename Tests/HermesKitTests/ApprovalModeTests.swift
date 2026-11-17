import XCTest
@testable import HermesKit

/// The labels a person sees must map to the spellings the host's terminal guard actually enforces.
final class ApprovalModeTests: XCTestCase {
    func testTheThreeHostModesAreTheThreeChoices() {
        XCTAssertEqual(Set(ApprovalMode.allCases.map(\.rawValue)), ["manual", "smart", "off"])
        XCTAssertEqual(ApprovalMode.manual.title, "Ask always")
        XCTAssertEqual(ApprovalMode.smart.title, "Auto")
        XCTAssertEqual(ApprovalMode.off.title, "Allow always")
        XCTAssertEqual(ApprovalMode.recommended, .smart)
    }

    func testMixedIsRealAndDoesNotPretendToBeOneMode() {
        let payload = #"{"mode":"mixed","profiles":{"cody":"manual","atlas":"off"}}"#
        let settings = ApprovalSettings.decode(Data(payload.utf8))
        XCTAssertNil(settings?.mode)
        XCTAssertEqual(settings?.profiles["cody"], .manual)
        XCTAssertEqual(settings?.profiles["atlas"], .off)
    }

    func testAWriteReportsWhichProfilesFailed() {
        let payload = #"{"mode":"smart","profiles":{"cody":"smart"},"updated":["cody"],"failed":{"atlas":"offline"}}"#
        let settings = ApprovalSettings.decode(Data(payload.utf8))
        XCTAssertEqual(settings?.mode, .smart)
        XCTAssertEqual(settings?.updated, ["cody"])
        XCTAssertEqual(settings?.failed["atlas"], "offline")
    }
}
