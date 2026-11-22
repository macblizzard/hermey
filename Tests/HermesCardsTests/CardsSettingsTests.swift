import XCTest
@testable import HermesCards

/// `cards.enabled` is the rollback switch, so its default must be "draw" and an injected store
/// must answer without touching the app's real defaults.
final class CardsSettingsTests: XCTestCase {
    private let suiteName = "dev.hermey.cards.tests"
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testTheKeyIsTheOneTheDefaultsCommandWrites() {
        XCTAssertEqual(CardsSettings.enabledKey, "cards.enabled")
    }

    func testAnUntouchedStoreMeansOn() {
        XCTAssertNil(defaults.object(forKey: CardsSettings.enabledKey))
        XCTAssertTrue(CardsSettings.isEnabled(in: defaults))
    }

    func testTheSwitchRoundTrips() {
        CardsSettings.setEnabled(false, in: defaults)
        XCTAssertFalse(CardsSettings.isEnabled(in: defaults))

        CardsSettings.setEnabled(true, in: defaults)
        XCTAssertTrue(CardsSettings.isEnabled(in: defaults))
    }

    /// A half-written plist value is not a reason to hide approvals: anything but an explicit
    /// `false` keeps the default.
    func testANonBooleanValueKeepsTheDefault() {
        defaults.set("no", forKey: CardsSettings.enabledKey)
        XCTAssertTrue(CardsSettings.isEnabled(in: defaults))
    }
}

/// The default theme carries the house light palette and its radii, so a caller that passes no
/// theme still gets the app's look. Hex values are pinned in `Tests/test_cards_client.py`; here
/// the shape and the injection path are what matter.
final class CardThemeTests: XCTestCase {
    func testTheDefaultThemeUsesTheHouseRadii() {
        XCTAssertEqual(CardTheme.hermey.radiusCard, 16)
        XCTAssertEqual(CardTheme.hermey.radiusControl, 10)
        XCTAssertEqual(CardTheme().radiusCard, CardTheme.hermey.radiusCard)
    }

    func testAnInjectedThemeIsKeptAsGiven() {
        var theme = CardTheme.hermey
        theme.radiusCard = 4
        theme.radiusControl = 2
        XCTAssertEqual(theme.radiusCard, 4)
        XCTAssertEqual(theme.radiusControl, 2)
    }
}
