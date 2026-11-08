#if canImport(Combine)
import Combine
import Foundation
import XCTest
@testable import HermesAppKit
import HermesKit

/// The actual AppModel lifecycle over the actual GatewayClient event feed. ScriptedHost supplies
/// session snapshots without a real service; LifecycleWire supplies ordered in-process frames.
@MainActor
final class AppModelEventLifetimeTests: XCTestCase {
    func testRepeatedStartStillDeliversLiveDeltaAndCompletion() async {
        let (model, wire) = makeModel()
        await model.start()
        await model.select("s1")
        await assertReply("first", model: model, wire: wire)
        // Root task, pairing and foreground retry can all call start on the same model/client.
        await model.start()
        await assertReply("second", model: model, wire: wire)
        await model.start()
        await assertReply("third", model: model, wire: wire)
        await model.stop()
    }

    func testStopThenStartStillDeliversLiveDeltaAndCompletion() async {
        let (model, wire) = makeModel()
        await model.start()
        await model.select("s1")
        await assertReply("before stop", model: model, wire: wire)
        await model.stop()
        await model.start()
        await assertReply("after stop", model: model, wire: wire)
        await model.stop()
    }

    private func makeModel() -> (AppModel, LifecycleWire) {
        let wire = LifecycleWire()
        let client = GatewayClient(makeTransport: { wire.bridge() }, reconnect: .disabled)
        return (AppModel(client: ScriptedHost(session: "s1", eventClient: client)), wire)
    }

    private func assertReply(_ text: String, model: AppModel, wire: LifecycleWire,
                             file: StaticString = #filePath, line: UInt = #line) async {
        // Published-value gates prove the old observer has processed a turn before replacing it,
        // and prove both delta and completion reach the new observer. No scheduling sleeps/polls.
        let delta = expectation(description: "streamed \(text)")
        let deltaGate = model.$streamingText.filter { $0 == text }.prefix(1).sink { _ in delta.fulfill() }
        wire.emit("message.delta", text: text)
        await fulfillment(of: [delta], timeout: 2)
        XCTAssertEqual(model.streamingText, text, file: file, line: line)

        let complete = expectation(description: "completed \(text)")
        let completeGate = model.$transcript
            .filter { $0.last?.role == .assistant && $0.last?.text == text }
            .prefix(1).sink { _ in complete.fulfill() }
        wire.emit("message.complete", text: text)
        await fulfillment(of: [complete], timeout: 2)
        XCTAssertEqual(model.transcript.last?.text, text, file: file, line: line)
        XCTAssertFalse(model.isStreaming, file: file, line: line)
        withExtendedLifetime((deltaGate, completeGate)) {}
    }
}

/// A fresh transport stream per connection, just like the real socket factory. This deliberately
/// leaves GatewayClient's decoded event subscription ownership completely unmocked.
private final class LifecycleWire: @unchecked Sendable {
    private let lock = NSLock()
    private var current: AsyncStream<GatewayTransport.Event>.Continuation?

    func bridge() -> TransportBridge {
        let (events, continuation) = AsyncStream<GatewayTransport.Event>.makeStream()
        lock.lock()
        current = continuation
        lock.unlock()
        return TransportBridge(events: events, connect: {
            continuation.yield(.frame(.notification(method: "event", params: .object([
                "type": .string("gateway.ready"), "payload": .object([:]),
            ]))))
        }, send: { text in
            let call = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            guard let id = call["id"] else { return }
            let reply = try JSONRPCCodec.encodeToString(JSONValue.object([
                "jsonrpc": .string("2.0"), "id": id, "result": .object([:]),
            ]))
            if let frame = try JSONRPCCodec.decodeLine(Data(reply.utf8)) {
                continuation.yield(.frame(frame))
            }
        }, disconnect: { _ in continuation.finish() })
    }

    func emit(_ type: String, text: String) {
        lock.lock()
        let continuation = current
        lock.unlock()
        continuation?.yield(.frame(.notification(method: "event", params: .object([
            "type": .string(type), "session_id": .string("s1"),
            "payload": .object(["text": .string(text)]),
        ]))))
    }
}
#endif
