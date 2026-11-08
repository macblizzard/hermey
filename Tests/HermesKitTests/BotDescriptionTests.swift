import Foundation
import XCTest
@testable import HermesKit

/// Bot descriptions: a human-readable line stored on the host so every device shows the same text.
final class BotDescriptionTests: XCTestCase {

    private func makeClient(_ fake: FakeGateway) -> GatewayClient {
        GatewayClient(makeTransport: { fake.bridge() }, timeouts: .testing, reconnect: .disabled)
    }

    func testConfigureDescriptionSendsExactlyNameAndDescription() async throws {
        let fake = FakeGateway()
        await fake.setResult(.object(["ok": .bool(true),
                                      "applied": .object(["description": .bool(true)])]),
                             for: "profiles.configure")
        let client = makeClient(fake)
        try await client.connect()

        try await client.configureDescription(profile: "assistant",
                                              description: "Lead Developer of Example Labs")

        let params = await fake.params(method: "profiles.configure")
        XCTAssertEqual(params, .object([
            "name": .string("assistant"),
            "description": .string("Lead Developer of Example Labs"),
        ]), "exactly two params: no model, no provider, no confirm flag")
    }

    func testConfigureDescriptionThrowsWhenTheHostRefusesTheWrite() async throws {
        let fake = FakeGateway()
        await fake.setResult(.object(["ok": .bool(false),
                                      "applied": .object(["description": .bool(false)])]),
                             for: "profiles.configure")
        let client = makeClient(fake)
        try await client.connect()

        do {
            try await client.configureDescription(profile: "assistant", description: "Lead Developer")
            XCTFail("a refused write must not look like success")
        } catch {
            XCTAssertTrue(error is GatewayError)
        }
    }

    func testProfilesListDecodesADescriptionAndTreatsBlankAsAbsent() async throws {
        let fake = FakeGateway()
        await fake.setResult(.object([
            "profiles": .array([
                .object(["name": .string("assistant"), "description": .string("Lead Developer of Example Labs")]),
                .object(["name": .string("ops"), "description": .string("  ")]),
                .object(["name": .string("analyst")]),
            ]),
        ]), for: "profiles.list")
        let client = makeClient(fake)
        try await client.connect()

        let bots = try await client.listBots()
        XCTAssertEqual(bots.map(\.id), ["assistant", "ops", "analyst"])
        XCTAssertEqual(bots[0].description, "Lead Developer of Example Labs")
        XCTAssertNil(bots[1].description, "a blank description is no description")
        XCTAssertNil(bots[2].description)
    }
}
