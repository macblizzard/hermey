import XCTest

/// The populated-workspace half of the macOS UI suite.
///
/// These tests launch with `-uiTestFixture` (see `Apps/HermesMac/Testing/PreviewFixture.swift`),
/// which swaps the app's store for a frozen, offline one: fixed bots, one fixed session, and a
/// transcript containing a markdown table, a fenced code block and a long paragraph. Nothing here
/// touches a network, a keychain or the developer's own preferences, and no assertion depends on
/// timing beyond bounded waits.
///
/// Every lookup is by accessibility identifier or by the label the app already publishes; the
/// only identifiers added for this suite are `conversationSearchToggle` and
/// `conversationSearchCount`.
final class HermesMacConversationUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Must match `UITestFixture.launchToken`. Deliberately duplicated rather than shared: the
    /// UI-test bundle does not link the app target, and a typo here fails loudly (the fixture
    /// never activates) instead of silently running against an empty window.
    private static let fixtureToken = "hermes-mac-uitest-fixture"

    private static let lastReply = "Backup verified while you were in the bot list."
    private static let userMessage = "Audit the vault backup and tell me which files changed."

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // A previous test can leave the app running (tearDown only terminates a foreground app),
        // and two instances make `windows.firstMatch` answer for the wrong process.
        app.terminate()
    }

    override func tearDownWithError() throws {
        if app.state == .runningForeground {
            screenshot("Final state")
            app.terminate()
        }
    }

    // MARK: - Transcript

    func testPopulatedTranscriptRendersMarkdownTableCodeAndProse() {
        launchFixture()

        // A message row exists, and it is the one the user wrote.
        let userRow = element(containing: Self.userMessage)
        XCTAssertTrue(userRow.waitForExistence(timeout: 20), "the user's message is not on screen")

        // The assistant's answer rendered as blocks: a heading, the table's cells, the fenced
        // code, and a sentence from the long paragraph.
        XCTAssertTrue(element(containing: "Vault backup audit").exists, "markdown heading missing")
        XCTAssertTrue(element(containing: "vault/attachments").exists, "markdown table missing")
        XCTAssertTrue(element(containing: "diff -rq ~/vault/docs").exists, "fenced code block missing")
        XCTAssertTrue(element(containing: "paying that cost once").exists, "long paragraph missing")

        screenshot("Populated conversation")
    }

    // MARK: - In-chat search

    func testInChatSearchReportsAndNarrowsTheMatchCount() {
        launchFixture()

        // The search bar is keyboard-only chrome now (the audit removed a permanently visible
        // row), so open it the way a user does: ⌘F.
        app.typeKey("f", modifierFlags: .command)

        let field = identifier("conversationSearchField")
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the conversation search field did not open")
        field.click()
        field.typeText("vault")

        // Three rows mention "vault": the user turn, the assistant's answer, and the tool row.
        // The fourth (the docs-only summary) and the late reply do not.
        let count = identifier("conversationSearchCount")
        XCTAssertTrue(waitForLabel("1 of 3", on: count, timeout: 10),
                      "expected 3 matches, got \(count.label)")
        screenshot("Search · vault · 3 matches")

        // Narrow the same query: only the answer's table row mentions attachments.
        app.typeKey("a", modifierFlags: .command)
        field.typeText("attachments")
        XCTAssertTrue(waitForLabel("1 of 1", on: count, timeout: 10),
                      "expected 1 match, got \(count.label)")
        screenshot("Search · attachments · 1 match")

        app.buttons["Done"].click()
        let closed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: field)
        wait(for: [closed], timeout: 10)
    }

    // MARK: - Message menu

    func testMessageContextMenuOffersShareAndCopy() {
        launchFixture()

        let reply = element(containing: Self.lastReply)
        XCTAssertTrue(reply.waitForExistence(timeout: 20), "the last reply is not on screen")
        XCTAssertTrue(reply.exists, "the last reply is not reachable without scrolling")

        reply.rightClick()

        // The app's own menu reads "Copy Message" and a `ShareLink` ("Share" / "Share…").
        let copy = app.menuItems["Copy Message"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10), "Copy Message is missing from the message menu")
        let share = app.menuItems.matching(NSPredicate(format: "label BEGINSWITH[c] 'Share'")).firstMatch
        XCTAssertTrue(share.exists, "Share is missing from the message menu")
        screenshot("Message context menu")

        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Bot list

    func testSidebarBotListShowsPinnedAndUnreadAffordances() {
        launchFixture()

        let rows = botRows()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20), "the sidebar bot list is empty")
        XCTAssertGreaterThanOrEqual(rows.count, 3, "expected the fixture's three bots")

        // Pinned sorts first, and the row says so in the label it publishes.
        let first = rows.element(boundBy: 0)
        XCTAssertTrue(first.label.hasPrefix("Assistant"),
                      "the pinned bot should lead the list, got \(first.label)")
        XCTAssertTrue(first.label.contains("pinned"), "Assistant's row does not advertise the pin")

        // The unread dot came from a real `.messageComplete` while the list was showing.
        let unread = rows.matching(NSPredicate(format: "label CONTAINS[c] 'unread'")).firstMatch
        XCTAssertTrue(unread.exists, "no bot row shows the unread dot")
        XCTAssertTrue(unread.label.contains("Assistant"), "the unread dot is on the wrong bot")

        // An unpinned bot must not borrow either affordance.
        let ops = rows.matching(NSPredicate(format: "label BEGINSWITH[c] 'Ops'")).firstMatch
        XCTAssertTrue(ops.exists, "Ops is missing from the bot list")
        XCTAssertFalse(ops.label.contains("pinned"), "Ops should not be pinned")

        screenshot("Sidebar bot list")
    }

    // MARK: - The gate itself

    /// The fixture is opt-in. Without both launch arguments the app must behave exactly as it
    /// always has: no canned bot, no canned transcript, no connection.
    func testNormalLaunchDoesNotShowFixtureContent() {
        app.launch()
        app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 60) {
            // Say what the process did, not just that no window appeared: a terminated app means a
            // crash at launch, a running app with no window means the scene never rendered.
            XCTFail("Hermes did not open a window (state=\(app.state.rawValue))\n\(app.debugDescription.prefix(4000))")
            return
        }

        // Ask the cheap collection (static texts) rather than a whole-tree descendants query:
        // without the fixture this launch may be showing a pairing sheet, and the generic query
        // took minutes to evaluate here.
        let heading = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Vault backup audit")).firstMatch
        let message = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", Self.userMessage)).firstMatch
        XCTAssertFalse(heading.waitForExistence(timeout: 3), "fixture content rendered in a normal launch")
        XCTAssertFalse(message.exists, "fixture transcript rendered in a normal launch")
        screenshot("Normal launch")
    }

    // MARK: - Helpers

    private func launchFixture() {
        app.launchArguments = ["-uiTestFixture",
                               "-uiTestFixtureToken",
                               Self.fixtureToken]
        app.launch()
        // A hosted runner can start the app behind other windows; activation is what makes the
        // window query reliable, not `isHittable` (which depends on focus, not on existence).
        app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 30) {
            // A missing window is either a launch-time crash (state != running) or a scene that
            // never rendered; print both facts so the CI log answers the question.
            XCTFail("Hermes did not open a window (state=\(app.state.rawValue))\n\(app.debugDescription.prefix(3000))")
            return
        }

        // Settle: the fixture's late reply is the last thing that changes the transcript, and
        // the search counts depend on it having landed.
        XCTAssertTrue(element(containing: Self.lastReply).waitForExistence(timeout: 30),
                      "the fixture host never attached")
    }

    /// Label- or value-matched element, regardless of the role SwiftUI picked for a block of
    /// markdown (a selectable text is not always a `staticText`). Plain texts are preferred,
    /// because those are the ones with a frame that can actually be clicked.
    private func element(containing text: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)
        let plainText = app.staticTexts.matching(predicate).firstMatch
        if plainText.exists { return plainText }
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    private func identifier(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// The sidebar's bot rows: the app labels each one "<name>, bot[, pinned][, unread]".
    private func botRows() -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] ', bot'"))
    }

    @discardableResult
    private func waitForLabel(_ label: String, on element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = expectation(for: NSPredicate(format: "label == %@", label),
                                      evaluatedWith: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        return result == .completed
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
