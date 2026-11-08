import Foundation
import XCTest
@testable import HermesKit

/// Rows the host *projects* carry their data in named fields, not in `text`.
///
/// The resume/history projection for a tool call is
/// `{role:"tool", name, context, args?, labels?, tool_call_id, content?}` — `content` only for the
/// editing tools. Reading `text`/`content` alone produced a card labelled "Tool" with nothing
/// behind it, on every tool call in history, and reasoning was invisible for the same kind of
/// reason: the model's reasoning arrives on `reasoning.delta`, not `thinking.delta`.
final class ProjectionDecodingTests: XCTestCase {

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    func testProjectedToolRowKeepsNameArgumentsAndLabels() throws {
        let projected = try json("""
        {"role":"tool",
         "name":"terminal",
         "context":"tailscale ssh root@build-host 'uptime'",
         "args":{"command":"tailscale ssh root@build-host 'uptime'"},
         "labels":[{"text":"build-host","kind":"target"}],
         "tool_call_id":"call_1",
         "timestamp":1793912000}
        """)

        let entry = try XCTUnwrap(GatewayPayloadDecoder.transcript([projected]).first)
        XCTAssertEqual(entry.role, .tool)
        XCTAssertEqual(entry.id, "tcall_1", "the call id is the row's stable identity")
        XCTAssertEqual(entry.tool?.name, "terminal")
        XCTAssertEqual(entry.tool?.context, "tailscale ssh root@build-host 'uptime'")
        XCTAssertTrue(entry.tool?.args?.contains("\"command\"") ?? false,
                      "args must be readable, not a compact one-liner")
        XCTAssertEqual(entry.tool?.labels, ["build-host"])
        XCTAssertEqual(entry.tool?.detail, entry.tool?.args,
                       "with no result in the payload, the call itself is what a tap opens")
    }

    func testEditToolRowPrefersItsResultOverItsArguments() throws {
        let projected = try json("""
        {"role":"tool","name":"patch","context":"Sources/HermesKit/GatewayClient.swift",
         "args":{"path":"Sources/HermesKit/GatewayClient.swift"},
         "content":"Applied 1 hunk","tool_call_id":"call_2"}
        """)

        let entry = try XCTUnwrap(GatewayPayloadDecoder.transcript([projected]).first)
        XCTAssertEqual(entry.tool?.content, "Applied 1 hunk")
        XCTAssertEqual(entry.tool?.detail, "Applied 1 hunk")
    }

    func testMessageRowsCarryNoToolDetail() throws {
        let user = try json(#"{"role":"user","text":"check the uptime"}"#)
        let entry = try XCTUnwrap(GatewayPayloadDecoder.transcript([user]).first)
        XCTAssertNil(entry.tool)
        XCTAssertEqual(entry.text, "check the uptime")
    }

    func testReasoningDeltaIsTheReasoningStream() throws {
        let payload = try json(#"{"text":"the host is reachable; read uptime over ssh","verbose":true}"#)
        let events = GatewayEventDecoder.events(type: "reasoning.delta", session: "s1", payload: payload)

        guard case .thinkingDelta(let session, let text)? = events?.first else {
            return XCTFail("reasoning.delta must reach the reasoning stream, got \(String(describing: events))")
        }
        XCTAssertEqual(session, "s1")
        XCTAssertEqual(text, "the host is reachable; read uptime over ssh")
    }

    func testEmptyReasoningDeltaIsAnEmptyListNotAClear() throws {
        let payload = try json(#"{"text":""}"#)
        XCTAssertEqual(GatewayEventDecoder.events(type: "reasoning.delta", session: "s1", payload: payload)?.count,
                       0,
                       "an empty chunk is a heartbeat and must never read as 'reasoning finished'")
    }

    // MARK: Interim commentary (text beside tool calls)

    func testInterimCommentaryBecomesItsOwnSegment() throws {
        let payload = try json(#"{"text":"Checking the release first.","already_streamed":false,"turn_id":"t9","segment":2}"#)
        let events = GatewayEventDecoder.events(type: "message.interim", session: "s1", payload: payload)

        guard case .interimMessage(let session, let text, let alreadyStreamed, let key)? = events?.first else {
            return XCTFail("message.interim was dropped: \(String(describing: events))")
        }
        XCTAssertEqual(session, "s1")
        XCTAssertEqual(text, "Checking the release first.")
        XCTAssertFalse(alreadyStreamed)
        XCTAssertEqual(key, "t9#2", "the seal is identified by its turn and segment")
    }

    func testInterimSealSaysWhetherTheWordsWereAlreadyStreamed() throws {
        let payload = try json(#"{"text":"On it.","already_streamed":true,"turn_id":"t9","segment":1}"#)
        let events = GatewayEventDecoder.events(type: "message.interim", session: "s1", payload: payload)
        guard case .interimMessage(_, _, let alreadyStreamed, _)? = events?.first else {
            return XCTFail("message.interim was dropped")
        }
        XCTAssertTrue(alreadyStreamed, "a client appending a row must clear the live bubble it streamed into")
    }

    func testEmptyInterimIsNothingToShow() throws {
        let payload = try json(#"{"text":"   ","already_streamed":false}"#)
        XCTAssertEqual(GatewayEventDecoder.events(type: "message.interim", session: "s1", payload: payload)?.count, 0)
    }
}
