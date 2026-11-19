import XCTest
@testable import HermeyUI

/// The "open at login" row's states and its promise.
///
/// The last test here is the one that matters most. This row is easy to over-claim: a login item
/// starts the app when the Mac starts, and people reasonably read that as "the Mac comes back when my
/// phone asks". It does not — launchd runs nothing while macOS is asleep, and the wake has to come from
/// Wake-on-LAN or a Bonjour sleep proxy. A sentence that blurs the two would be the app promising a
/// capability it does not have, so the copy is pinned here.
final class LaunchAtLoginStatusTests: XCTestCase {

    func testEveryStateIsCovered() {
        XCTAssertEqual(LaunchAtLoginStatus.allCases.count, 4)
        XCTAssertEqual(Set(LaunchAtLoginStatus.allCases.map(\.rawValue)).count, 4)
    }

    /// An entry waiting for approval is not running at login yet, so only `.on` may draw as on.
    func testOnlyOnDrawsTheToggleAsOn() {
        for status in LaunchAtLoginStatus.allCases {
            XCTAssertEqual(status.toggleIsOn, status == .on, "\(status.rawValue) draws the wrong toggle state")
        }
    }

    /// The button that opens System Settings is offered for exactly one state.
    func testOnlyTheApprovalStateOffersTheSettingsButton() {
        for status in LaunchAtLoginStatus.allCases {
            XCTAssertEqual(status.offersApproval, status == .needsApproval)
        }
    }

    func testEveryStateExplainsItself() {
        for status in LaunchAtLoginStatus.allCases {
            XCTAssertFalse(status.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(status.rawValue) has no explanation")
            XCTAssertGreaterThan(status.detail.count, 40, "\(status.rawValue) says too little to act on")
        }
    }

    /// No state may claim it wakes a sleeping Mac. Where the copy mentions waking at all, it has to be
    /// a denial — "does not wake", "cannot wake" — never a promise.
    func testNoStateClaimsToWakeASleepingMac() {
        let denials = ["does not wake", "cannot wake", "can't wake", "will not wake"]
        for status in LaunchAtLoginStatus.allCases {
            let text = status.detail.lowercased()
            guard text.contains("wake") else { continue }
            XCTAssertTrue(denials.contains(where: text.contains),
                          "\(status.rawValue) mentions waking without denying it: “\(status.detail)”")
        }
    }

    /// The one state that must describe the wake limits is the "on" state, because that is the one a
    /// person reads after turning it on.
    func testTheOnStateStatesTheWakeLimit() {
        let text = LaunchAtLoginStatus.on.detail.lowercased()
        XCTAssertTrue(text.contains("wake"), "the on state should say plainly that it does not wake the Mac")
        XCTAssertTrue(text.contains("does not wake"))
    }

    func testOffStateSaysWhatStaysUnavailable() {
        let text = LaunchAtLoginStatus.off.detail.lowercased()
        XCTAssertTrue(text.contains("restart") || text.contains("open"), "off should say when it bites")
    }
}
