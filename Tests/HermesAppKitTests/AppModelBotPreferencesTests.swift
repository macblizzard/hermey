#if canImport(Combine)
import Foundation
import XCTest
@testable import HermesAppKit
import HermesKit

/// Per-host UI preferences on `AppModel`: pins stay local to the host you made them on, and a
/// description is written through to the host before the list mirrors it.
@MainActor
final class AppModelBotPreferencesTests: XCTestCase {

    private func hostName(_ label: String) -> String {
        "test-\(label)-\(UUID().uuidString)"
    }

    private func key(_ host: String) -> String { "hermes.pinnedBots.\(host)" }

    func testPinTogglesOnAndOff() {
        let host = hostName("pin-toggle")
        defer { UserDefaults.standard.removeObject(forKey: key(host)) }
        let model = AppModel(client: ScriptedHost(session: "s1"), hostName: host)

        XCTAssertFalse(model.isPinned(botID: "assistant"))
        model.togglePin(botID: "assistant")
        XCTAssertTrue(model.isPinned(botID: "assistant"))
        XCTAssertEqual(model.pinnedBots, ["assistant"])

        model.togglePin(botID: "assistant")
        XCTAssertFalse(model.isPinned(botID: "assistant"))
        XCTAssertTrue(model.pinnedBots.isEmpty)
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: key(host)), [])
    }

    func testPinsPersistPerHostAndDoNotLeakToAnotherHost() async {
        let host = hostName("pin-persist")
        let otherHost = host + "-other"
        defer {
            UserDefaults.standard.removeObject(forKey: key(host))
            UserDefaults.standard.removeObject(forKey: key(otherHost))
        }

        let first = AppModel(client: ScriptedHost(session: "s1"), hostName: host)
        first.togglePin(botID: "assistant")
        first.togglePin(botID: "ops")
        await first.stop()

        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: key(host)), ["assistant", "ops"],
                       "a set has no order; storage is sorted so the file stays stable")

        let reopened = AppModel(client: ScriptedHost(session: "s1"), hostName: host)
        await reopened.start()
        XCTAssertEqual(reopened.pinnedBots, ["assistant", "ops"], "pins survive a fresh model for the same host")
        await reopened.stop()

        let other = AppModel(client: ScriptedHost(session: "s1"), hostName: otherHost)
        await other.start()
        XCTAssertTrue(other.pinnedBots.isEmpty, "one host's pins never appear on another")
        await other.stop()
    }

    func testEmptyBotIDsAreNotPinnable() {
        let host = hostName("pin-empty")
        defer { UserDefaults.standard.removeObject(forKey: key(host)) }
        let model = AppModel(client: ScriptedHost(session: "s1"), hostName: host)

        model.togglePin(botID: "")
        XCTAssertTrue(model.pinnedBots.isEmpty)
    }

    func testConfigureDescriptionWritesThroughAndUpdatesTheRow() async throws {
        let host = hostName("description")
        defer { UserDefaults.standard.removeObject(forKey: key(host)) }
        let scripted = ScriptedHost(session: "s1")
        scripted.bots = [Bot(id: "assistant"), Bot(id: "ops")]
        let model = AppModel(client: scripted, hostName: host)
        await model.start()

        try await model.configureDescription(botID: "assistant",
                                             description: "  Lead Developer of Example Labs  ")

        XCTAssertEqual(scripted.descriptions.count, 1)
        XCTAssertEqual(scripted.descriptions.first?.0, "assistant")
        XCTAssertEqual(scripted.descriptions.first?.1, "Lead Developer of Example Labs",
                       "the text is trimmed before it crosses the wire")
        XCTAssertEqual(model.bots.first(where: { $0.id == "assistant" })?.description,
                       "Lead Developer of Example Labs",
                       "the list reflects the saved description without waiting for a reload")
        XCTAssertNil(model.bots.first(where: { $0.id == "ops" })?.description)
        await model.stop()
    }
}
#endif
