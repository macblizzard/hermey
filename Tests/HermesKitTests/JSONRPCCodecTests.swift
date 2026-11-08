import XCTest
@testable import HermesKit

final class JSONRPCCodecTests: XCTestCase {

    func testEncodesRequestOnOneLine() throws {
        let req = RPCRequest(id: .int(7), method: "prompt.submit",
                             params: .object(["session_id": .string("s-1"), "text": .string("hi")]))
        let line = try JSONRPCCodec.encodeToString(req)
        XCTAssertFalse(line.contains("\n"))
        let obj = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        XCTAssertEqual(obj["jsonrpc"]?.stringValue, "2.0")
        XCTAssertEqual(obj["method"]?.stringValue, "prompt.submit")
        XCTAssertEqual(obj["id"]?.intValue, 7)
        XCTAssertEqual(obj["params"]?["session_id"]?.stringValue, "s-1")
    }

    func testDecodesResponseWithResult() throws {
        let line = Data(#"{"jsonrpc":"2.0","id":3,"result":{"ok":true,"sessions":[]}}"#.utf8)
        guard case .response(let id, let result, let error) = try XCTUnwrap(JSONRPCCodec.decodeLine(line)) else {
            return XCTFail("expected a response frame")
        }
        XCTAssertEqual(id, .int(3))
        XCTAssertNil(error)
        XCTAssertEqual(result?["ok"]?.boolValue, true)
    }

    func testDecodesErrorWithData() throws {
        let line = Data(#"{"jsonrpc":"2.0","id":"x","error":{"code":4009,"message":"session busy","data":{"session_id":"s"}}}"#.utf8)
        guard case .response(_, _, let error) = try XCTUnwrap(JSONRPCCodec.decodeLine(line)) else {
            return XCTFail("expected a response frame")
        }
        XCTAssertEqual(error?.code, 4009)
        XCTAssertEqual(error?.data?["session_id"]?.stringValue, "s")
    }

    /// The gateway sends requests *to* the client (approval, clarify, sudo…). If the
    /// client cannot tell those apart from responses, approvals never resolve.
    func testDecodesServerToClientRequest() throws {
        let line = Data(#"{"jsonrpc":"2.0","id":"srq-7","method":"approval","params":{"request_id":"r1","command":"rm -rf build"}}"#.utf8)
        guard case .request(let req) = try XCTUnwrap(JSONRPCCodec.decodeLine(line)) else {
            return XCTFail("expected a request frame")
        }
        XCTAssertEqual(req.id, .string("srq-7"))
        XCTAssertEqual(req.method, "approval")
        XCTAssertEqual(req.params?["command"]?.stringValue, "rm -rf build")

        let answer = try JSONRPCCodec.encodeToString(RPCResponse(id: req.id, result: .object(["choice": .string("once")])))
        XCTAssertTrue(answer.contains(#""choice":"once""#))
        XCTAssertTrue(answer.contains(#""id":"srq-7""#))
    }

    func testNotificationDecoding() throws {
        let line = Data(#"{"jsonrpc":"2.0","method":"message.delta","params":{"session_id":"s","text":"He"}}"#.utf8)
        guard case .notification(let method, let params) = try XCTUnwrap(JSONRPCCodec.decodeLine(line)) else {
            return XCTFail("expected a notification")
        }
        XCTAssertEqual(method, "message.delta")
        XCTAssertEqual(params["text"]?.stringValue, "He")
    }

    func testIgnoresUnknownFieldsAndEvents() throws {
        let line = Data(#"{"jsonrpc":"2.0","method":"some.future.event","params":{"a":1},"extra":{"deep":[1,2,3]}}"#.utf8)
        guard case .notification(let method, _) = try XCTUnwrap(JSONRPCCodec.decodeLine(line)) else {
            return XCTFail("unknown events must decode, not throw")
        }
        XCTAssertEqual(method, "some.future.event")
    }

    func testBlankLineIsSkipped() throws {
        XCTAssertNil(try JSONRPCCodec.decodeLine(Data("\n".utf8)))
        XCTAssertNil(try JSONRPCCodec.decodeLine(Data("  \r\n".utf8)))
    }

    func testNDJSONBufferReassemblesSplitFrames() {
        var buffer = NDJSONBuffer()
        XCTAssertTrue(buffer.append(Data(#"{"jsonrpc":"2.0","id":1,"res"#.utf8)).isEmpty)
        let frames = buffer.append(Data(#"ult":{}}"#.utf8) + Data("\n".utf8) + Data(#"{"jsonrpc":"2.0","id":2,"result":{}}"#.utf8))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(String(data: buffer.pending, encoding: .utf8), #"{"jsonrpc":"2.0","id":2,"result":{}}"#)
    }

    func testSessionBusyErrorIsRecognised() {
        XCTAssertEqual(RPCError.sessionBusy.code, 4009)
        XCTAssertEqual(RPCError.methodNotFound.code, -32601)
    }
}
