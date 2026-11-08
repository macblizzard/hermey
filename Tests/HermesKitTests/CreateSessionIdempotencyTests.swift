import Foundation
import XCTest
@testable import HermesKit

/// Two devices opening one bot at the same moment both see "no shared conversation" and both
/// create. A deterministic `idempotency_key` is what makes the gateway coalesce them instead of
/// forking the conversation, so the key has to actually reach `session.create`.
final class CreateSessionIdempotencyTests: XCTestCase {

    private func makeClient(_ fake: FakeGateway) -> GatewayClient {
        GatewayClient(makeTransport: { fake.bridge() }, timeouts: .testing, reconnect: .disabled)
    }

    func testIdempotencyKeyTravelsWithTheProfile() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        try await client.connect()

        _ = try await client.createSession(model: nil, provider: nil, profile: "assistant",
                                           idempotencyKey: "bot-chat:assistant")

        let params = await fake.params(method: "session.create")
        XCTAssertEqual(params?["profile"]?.stringValue, "assistant")
        XCTAssertEqual(params?["idempotency_key"]?.stringValue, "bot-chat:assistant")
    }

    /// Existing callers (a plain "new chat") keep the wire shape they had: no key, no parameter.
    func testPlainCreateSendsNoKey() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        try await client.connect()

        _ = try await client.createSession(model: nil, provider: nil, profile: "assistant")

        let params = await fake.params(method: "session.create")
        XCTAssertNil(params?["idempotency_key"])
    }

    /// An empty key is "no key": the gateway must not see `""` and dedupe unrelated creates.
    func testEmptyKeyIsDropped() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        try await client.connect()

        _ = try await client.createSession(model: nil, provider: nil, profile: "assistant", idempotencyKey: "")

        let params = await fake.params(method: "session.create")
        XCTAssertNil(params?["idempotency_key"])
    }
}
