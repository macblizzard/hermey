import XCTest
@testable import HermesAppKit

/// Opening the shared computer beside the conversation put a third pane in a window sized for two, and
/// the shell clipped on *both* sides — the bot panel's labels on the left, the computer pane's buttons
/// on the right. These cases pin the arithmetic the window minimum, the pane floors and the
/// grow-the-window helper all read.
final class WindowLayoutTests: XCTestCase {
    /// 8 + 200 + 7 + 1 + 424 + 8 — the number the shell used before, kept as a regression.
    func testTwoPanesMatchTheShellsLongStandingMinimum() {
        XCTAssertEqual(WindowLayout.minimumWidth(sidebarWidth: 200, panelOpen: false), 648)
    }

    func testOpeningTheComputerAddsItsPaneAndAHairline() {
        let two = WindowLayout.minimumWidth(sidebarWidth: 240, panelOpen: false)
        let three = WindowLayout.minimumWidth(sidebarWidth: 240, panelOpen: true)

        // The pane, its boundary line, and the width the conversation hands back.
        XCTAssertEqual(three - two,
                       WindowLayout.hairline
                       + WindowLayout.computerMin
                       + WindowLayout.conversationMinWithComputer
                       - WindowLayout.conversationMin,
                       "the pane, its hairline and the conversation's concession are the whole difference")
        XCTAssertGreaterThan(three, two)
    }

    /// The pane opening must not be able to ask for *less* than it did before, or the window could
    /// shrink under the conversation while the panel is up.
    func testThreePanesNeverNeedLessThanTwo() {
        for width in stride(from: CGFloat(0), through: 400, by: 20) {
            XCTAssertGreaterThanOrEqual(WindowLayout.minimumWidth(sidebarWidth: width, panelOpen: true),
                                        WindowLayout.minimumWidth(sidebarWidth: width, panelOpen: false))
        }
    }

    func testAHiddenPanelIsNotChargedFor() {
        XCTAssertEqual(WindowLayout.minimumWidth(sidebarWidth: nil, panelOpen: false),
                       WindowLayout.surround * 2 + WindowLayout.conversationMin)
        XCTAssertEqual(WindowLayout.minimumWidth(sidebarWidth: nil, panelOpen: true),
                       WindowLayout.surround * 2
                       + WindowLayout.conversationMinWithComputer
                       + WindowLayout.hairline
                       + WindowLayout.computerMin)
    }

    /// A panel dragged narrower than its floor cannot narrow the window below that floor.
    func testTheSidebarFloorHoldsTheWindowOpen() {
        XCTAssertEqual(WindowLayout.minimumWidth(sidebarWidth: 40, panelOpen: false),
                       WindowLayout.minimumWidth(sidebarWidth: WindowLayout.sidebarFloor, panelOpen: false))
    }

    /// Three panes have to fit on the smallest display this app supports, or "grow the window" turns
    /// into "clip the window".
    func testThreePanesFitA1024PointDisplay() {
        XCTAssertLessThanOrEqual(WindowLayout.minimumWidth(sidebarWidth: 240, panelOpen: true), 1024)
    }

    /// The reading pane gives width back when it stops being the only pane.
    func testTheConversationGivesWidthBackToTheComputer() {
        XCTAssertLessThan(WindowLayout.conversationMinWithComputer, WindowLayout.conversationMin)
        XCTAssertLessThanOrEqual(WindowLayout.conversationMinWithComputer + WindowLayout.computerMin,
                                 WindowLayout.computerIdeal + 160)
    }
}
