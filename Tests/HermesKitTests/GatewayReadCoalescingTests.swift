import Foundation
import XCTest
@testable import HermesKit

/// One launch asked the host for the same things several times.
///
/// Measured on the live bridge: `profiles.list` ×2, `session.list` ×5, `model.options` ×3 inside
/// three seconds (the last of them answering after 3.7 s), and a reconnect after a compaction
/// repeated the burst. The gateway answers those one at a time, so the transcript the user waits for
/// queues behind work nobody asked for. These cases pin the client's answer: an identical read costs
/// one round trip however many callers want it, a *different* read is still a different question,
/// the catalogue is remembered only for as long as it can be trusted, and a refusal is never served
/// from memory.
final class GatewayReadCoalescingTests: XCTestCase {

    private func makeClient(_ fake: FakeGateway) -> GatewayClient {
        GatewayClient(makeTransport: { fake.bridge() }, timeouts: .testing, reconnect: .disabled)
    }

    private func catalogue(models: [String] = ["deepseek-v4.1-flash"]) -> JSONValue {
        .object([
            "model": .string(models.first ?? ""),
            "provider": .string("opencode-go"),
            "providers": .array([
                .object([
                    "slug": .string("opencode-go"),
                    "models": .array(models.map { .string($0) }),
                ]),
            ]),
        ])
    }

    // MARK: Concurrent callers

    func testTwoCallersAskingTheSameThingCostOneRoundTrip() async throws {
        let fake = FakeGateway()
        // Without a slow answer the first read finishes before the second starts, which is the case
        // this feature does not need to handle. Holding the answer is what puts two callers in the
        // same window deterministically (`Task.yield()` proves nothing about how far a task got).
        await fake.delay(0.4, for: "profiles.list")
        let client = makeClient(fake)
        try await client.connect()

        async let first = client.listBots()
        async let second = client.listBots()
        let (a, b) = try await (first, second)

        XCTAssertEqual(a.map(\.id), b.map(\.id), "both callers get the same answer")
        let sent = await fake.frames(method: "profiles.list").count
        XCTAssertEqual(sent, 1, "the second caller joins the flight instead of asking the host again")
    }

    func testAFlagFloodOnSessionListIsOneQuestion() async throws {
        let fake = FakeGateway()
        await fake.delay(0.3, for: "session.list")
        let client = makeClient(fake)
        try await client.connect()

        async let one = client.listSessions(limit: 20, profile: "chief", includeHidden: true)
        async let two = client.listSessions(limit: 20, profile: "chief", includeHidden: true)
        async let three = client.listSessions(limit: 20, profile: "chief", includeHidden: true)
        _ = try await (one, two, three)

        let sent = await fake.frames(method: "session.list").count
        XCTAssertEqual(sent, 1, "five views opening at once are one request")
    }

    func testADifferentBotIsADifferentQuestion() async throws {
        let fake = FakeGateway()
        await fake.delay(0.3, for: "session.list")
        let client = makeClient(fake)
        try await client.connect()

        async let chief = client.listSessions(limit: 20, profile: "chief", includeHidden: true)
        async let analyst = client.listSessions(limit: 20, profile: "analyst", includeHidden: true)
        _ = try await (chief, analyst)

        let sent = await fake.frames(method: "session.list").count
        XCTAssertEqual(sent, 2, "per-bot scoping must not be collapsed away")
    }

    // MARK: The catalogue's TTL

    func testTheCatalogueIsRememberedForBothSurfaces() async throws {
        let fake = FakeGateway()
        await fake.setResult(catalogue(), for: "model.options")
        let client = makeClient(fake)
        try await client.connect()

        _ = try await client.modelCatalog(profile: "cody")
        _ = try await client.modelCatalog(profile: "cody")

        let sent = await fake.frames(method: "model.options").count
        XCTAssertEqual(sent, 1, "1-4 s of host work, asked once within the window")
    }

    func testTheCatalogueIsAProfileScopedQuestion() async throws {
        let fake = FakeGateway()
        await fake.setResult(catalogue(), for: "model.options")
        let client = makeClient(fake)
        try await client.connect()

        _ = try await client.modelCatalog(profile: "chief")
        _ = try await client.modelCatalog(profile: "analyst")

        let sent = await fake.frames(method: "model.options").count
        XCTAssertEqual(sent, 2, "a bot's own catalogue is never another bot's")
    }

    func testChangingTheModelDropsTheRememberedCatalogue() async throws {
        let fake = FakeGateway()
        await fake.setResult(catalogue(), for: "model.options")
        await fake.setResult(.object(["ok": .bool(true),
                                      "applied": .object(["model": .string("gpt-6.1-sol"),
                                                          "provider": .string("opencode-go")])]),
                             for: "profiles.configure")
        let client = makeClient(fake)
        try await client.connect()

        _ = try await client.modelCatalog(profile: "cody")
        _ = try await client.configureModel(profile: "cody", model: "gpt-6.1-sol",
                                            provider: "opencode-go", confirm: false)
        _ = try await client.modelCatalog(profile: "cody")

        let sent = await fake.frames(method: "model.options").count
        XCTAssertEqual(sent, 2, "a remembered catalogue must not outlive the change that invalidated it")
    }

    // MARK: Failure

    func testARefusalIsNotRemembered() async throws {
        let fake = FakeGateway()
        await fake.setError(RPCError(code: -32603, message: "no host"), for: "profiles.list")
        let client = makeClient(fake)
        try await client.connect()

        do {
            _ = try await client.listBots()
            XCTFail("the refusal has to reach the caller")
        } catch { /* expected */ }

        await fake.clearError(for: "profiles.list")
        await fake.setResult(.object(["profiles": .array([
            .object(["name": .string("default"), "is_default": .bool(true)]),
        ])]), for: "profiles.list")
        let bots = try await client.listBots()

        XCTAssertEqual(bots.count, 1)
        let sent = await fake.frames(method: "profiles.list").count
        XCTAssertEqual(sent, 2, "a failure is not an answer: the next caller asks again")
    }

    func testACompactionDropsWhatTheHostJustRewrote() async throws {
        let fake = FakeGateway()
        await fake.setResult(catalogue(), for: "model.options")
        await fake.setResult(FakeGateway.resumeResult(storedID: "20260101_000002_probe"),
                             for: "session.resume")
        let client = makeClient(fake)
        try await client.connect()

        _ = try await client.resumeSession("20260101_000002_probe", profile: "cody")
        _ = try await client.modelCatalog(profile: "cody")
        try await client.compress(session: "20260101_000002_probe")
        _ = try await client.modelCatalog(profile: "cody")

        let sent = await fake.frames(method: "model.options").count
        XCTAssertEqual(sent, 2, "after a compaction nothing remembered is trusted")
    }
}
