import Foundation
import XCTest
@testable import HermesKit

private actor SeamInbox {
    var values: [ClientEvent] = []
    func append(_ event: ClientEvent) { values.append(event) }
    func texts() -> [String] { EventDigest.deltas(values) }
    func completions() -> [String] { EventDigest.completions(values) }
}

final class LiveReplySeamTests: XCTestCase {
    private func setupClient() async throws -> (GatewayClient, FakeGateway) {
        let host = FakeGateway()
        let client = GatewayClient(makeTransport: { host.bridge() }, timeouts: .testing, reconnect: .disabled)
        try await client.connect()
        _ = try await client.resumeSession("stored-1", profile: "assistant")
        return (client, host)
    }

    private func subscribe(_ client: GatewayClient, _ inbox: SeamInbox) -> Task<Void, Never> {
        // Exactly the stream/subscription shape used by AppModel.observeEvents (710-718),
        // without Combine/SwiftUI, which are unavailable in the Linux Swift container.
        let events = client.events
        return Task {
            for await event in events { await inbox.append(event) }
        }
    }

    func testControlSingleSubscriptionDeliversIDLessReply() async throws {
        let (client, host) = try await setupClient()
        let inbox = SeamInbox()
        let observer = subscribe(client, inbox)
        await host.emit(event: "message.delta", payload: .object(["text": .string("control")]))
        let delivered = await eventually { await inbox.texts() == ["control"] }
        XCTAssertTrue(delivered)
        observer.cancel()
        await observer.value
        await client.disconnect()
    }

    func testReplacingModelSubscriptionMustStillDeliverLiveReply() async throws {
        let (client, host) = try await setupClient()
        let first = SeamInbox()
        let observer = subscribe(client, first)
        await host.emit(event: "message.delta", payload: .object(["text": .string("before restart")]))
        let firstDelivered = await eventually { await first.texts() == ["before restart"] }
        XCTAssertTrue(firstDelivered)
        // AppModel.start -> observeEvents cancels the previous iterator on this SAME stream.
        observer.cancel()
        await observer.value
        let second = SeamInbox()
        let replacement = subscribe(client, second)
        await host.emit(event: "message.delta", payload: .object(["text": .string("after restart")]))
        await host.emit(event: "message.complete", payload: .object(["text": .string("after restart")]))
        let delivered = await eventually(timeout: 0.2) { await second.completions() == ["after restart"] }
        await host.setResult(.object(["pong": .bool(true)]), for: "ping")
        try await client.ping() // transport pump + response correlation are STILL alive
        XCTAssertTrue(delivered, "Live reply is permanently lost after subscription cancellation, despite a working socket/RPC")
        let texts = await second.texts()
        XCTAssertEqual(texts, ["after restart"])
        replacement.cancel()
        await replacement.value
        await client.disconnect()
    }

}
