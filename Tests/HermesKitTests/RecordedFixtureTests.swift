import Foundation
import XCTest
@testable import HermesKit

/// Pins the recorded bytes (`fixtures/m0-handshake.ndjson`, captured from Hermes Agent v0.22.6 over
/// stdio). These tests fail if the framing, the envelope or the unknown-method answer drifts.
final class RecordedFixtureTests: XCTestCase {

    func testEveryRecordedLineDecodesToTheShapeItClaims() throws {
        // 1. gateway.ready arrives as a *notification* whose method is "event".
        guard case .notification(let method, let params) = try Fixtures.frame(0) else {
            return XCTFail("line 1 must be a notification")
        }
        XCTAssertEqual(method, "event")
        XCTAssertEqual(params["type"]?.stringValue, "gateway.ready")
        XCTAssertEqual(params["payload"]?["replay_epoch"]?.stringValue, "probe")
        XCTAssertEqual(params["payload"]?["skin"]?["name"]?.stringValue, "default")

        // 2. ping reply.
        guard case .response(let pingID, let pong, let pingError) = try Fixtures.frame(1) else {
            return XCTFail("line 2 must be a response")
        }
        XCTAssertEqual(pingID, .int(1))
        XCTAssertNil(pingError)
        XCTAssertEqual(pong?["pong"]?.boolValue, true)

        // 3. the capabilities reply is a 16-method contract, and it is a *subset* we answer.
        guard case .response(let capabilitiesID, let capabilities, _) = try Fixtures.frame(2) else {
            return XCTFail("line 3 must be a response")
        }
        XCTAssertEqual(capabilitiesID, .int(2))
        let methods = (capabilities?["server_requests"]?.arrayValue ?? []).compactMap { $0.stringValue }
        XCTAssertEqual(methods.count, 16)
        XCTAssertTrue(methods.contains("terminal.read"))
        XCTAssertEqual(capabilities?["declines_not_shown"]?.boolValue, true)
        XCTAssertTrue(GatewayClient.answerableServerRequests.isSubset(of: Set(methods)),
                      "everything we claim to handle must be on the backend's list")

        // 5. gateway.capabilities.
        guard case .response(let gatewayID, let gateway, _) = try Fixtures.frame(4) else {
            return XCTFail("line 5 must be a response")
        }
        XCTAssertEqual(gatewayID, .int(5))
        XCTAssertEqual(gateway?["per_session_exclusive_submit"]?.boolValue, true)
    }

    func testUnknownMethodAnswerKeepsTheGatewayWording() throws {
        guard case .response(let id, _, let error) = try Fixtures.frame(3) else {
            return XCTFail("line 4 must be an error response")
        }
        XCTAssertEqual(id, .int(4))
        XCTAssertEqual(error?.code, -32601)
        XCTAssertTrue(error?.message.contains("unknown method: no.such.method") ?? false)
    }

    /// The decoder must see exactly the events the recording contains, and nothing for the names it
    /// does *not* contain — a client that fired on `method == "gateway.ready"` would fire here and
    /// then never again.
    func testReadyIsNotProducedByTheGenericEventDecoder() throws {
        guard case .notification(_, let params) = try Fixtures.frame(0) else {
            return XCTFail("line 1 must be a notification")
        }
        let decoded = GatewayEventDecoder.event(type: params["type"]?.stringValue ?? "",
                                                session: "",
                                                payload: params["payload"] ?? .null)
        XCTAssertNil(decoded, "gateway.ready belongs to the handshake, not the event decoder")
    }

    func testClientCompletesTheRecordedHandshake() async throws {
        let fake = FakeGateway()
        await fake.configure(emitReady: false)
        // The recorded reply, byte for byte, instead of the fake's own copy of it.
        await fake.setResult(Fixtures.capabilitiesResult, for: "client.capabilities")
        let client = GatewayClient(makeTransport: { fake.bridge() }, timeouts: .testing, reconnect: .disabled)
        let log = EventLog()
        log.start(client.events)

        // The real gateway writes gateway.ready before it reads a single request; feeding it before
        // the handshake starts proves the client does not depend on who wins that race.
        await fake.emit(line: Fixtures.handshake[0])
        try await client.connect()

        XCTAssertEqual(client.state, .open)
        let methods = await fake.methods()
        XCTAssertEqual(methods, ["client.capabilities"])
        let params = await fake.params(method: "client.capabilities")
        XCTAssertEqual(params?["server_requests"]?.boolValue, true)

        let advertised = await client.advertisedServerRequestMethods()
        XCTAssertEqual(advertised.count, 16)
        XCTAssertTrue(advertised.contains("sudo"))

        let ready = await log.waitUntil { EventDigest.readyEpochs($0) == ["probe"] }
        XCTAssertTrue(ready)
    }
}
