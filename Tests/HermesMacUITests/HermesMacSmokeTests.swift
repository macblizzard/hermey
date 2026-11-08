import XCTest

final class HermesMacSmokeTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Never inherit an instance another test left running.
        app.terminate()
    }

    override func tearDownWithError() throws {
        // Also preserve the last visible state when an assertion fails.
        screenshot("Final state")
        app.terminate()
    }

    func testLaunchAndDismissPairing() {
        app.launch()
        app.activate()
        let window = app.windows.firstMatch
        if !window.waitForExistence(timeout: 60) {
            XCTFail("Hermes did not open a window (state=\(app.state.rawValue))\n\(app.debugDescription.prefix(4000))")
            return
        }
        // `isHittable` reports focus, and a hosted runner's window is not always focused even
        // though it is on screen; existence after activation is the honest check here.
        XCTAssertTrue(window.exists, "Hermes window is not visible")
        screenshot("Launched window")

        // Use the app's own menu shortcut, not coordinates or test-only app code.
        app.typeKey("p", modifierFlags: [.command, .shift])
        let urlField = app.textFields["WebSocket URL"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 10), "Pairing sheet did not open")
        XCTAssertTrue(urlField.isHittable)
        screenshot("Pairing sheet")

        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: urlField)
        wait(for: [gone], timeout: 10)
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Main window was not restored")
        screenshot("Pairing dismissed")
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
