import Foundation
import XCTest
@testable import HermesKit

/// The wire contracts behind the endless-chat batch, captured from the live gateway
/// (`docs/ENDLESS-CHAT.md` §5):
///
/// - `tool.start` is `{tool_id, name, context?, args?, args_text?, preview?}` and the card's label
///   is `name` — the transcript projection rendered the literal word "tool" instead;
/// - `tool.complete` is `{tool_id, name, args?, duration_s?, result, summary?, result_text?}` and
///   its output resolves `result_text` → `result` → `summary` — the card read a key that was never
///   sent, so every finished tool said "No output.";
/// - `thinking.delta` is `{text}`, repeated with an **empty** text as a heartbeat, and is a stream
///   of its own;
/// - `message.complete` carries `usage.context_used` / `usage.context_max` / `usage.context_percent`;
/// - `model.options` names the running model at the top level, not in `providers[0].models[0]`.
final class EndlessChatProtocolTests: XCTestCase {

    private func makeClient(_ fake: FakeGateway) -> GatewayClient {
        GatewayClient(makeTransport: { fake.bridge() }, timeouts: .testing, reconnect: .disabled)
    }

    /// Connect a client the *test* keeps alive.
    ///
    /// The client owns the pump that feeds `log`; a helper that returned only the log would let the
    /// actor deallocate and silently stop the event stream (the tests then time out looking exactly
    /// like a wire bug). Every test therefore holds its own `client` for its whole body.
    private func connect(_ fake: FakeGateway, log: EventLog) async throws -> GatewayClient {
        let client = makeClient(fake)
        log.start(client.events)
        try await client.connect()
        return client
    }

    // MARK: Tool lifecycle

    /// The exact bug: rows labelled "tool" and finished rows that said "No output.".
    func testToolNameAndOutputComeFromTheKeysTheWireActuallySends() async throws {
        let fake = FakeGateway()
        let log = EventLog()
        let client = try await connect(fake, log: log)
        _ = client

        await fake.emit(event: "tool.start", session: "rt-1", payload: .object([
            "tool_id": .string("call-1"),
            "name": .string("read_file"),
            "args_text": .string(#"{"path":"/tmp/x"}"#),
        ]))
        await fake.emit(event: "tool.complete", session: "rt-1", payload: .object([
            "tool_id": .string("call-1"),
            "name": .string("read_file"),
            "duration_s": .double(0.8),
            "result": .object(["success": .bool(true)]),
            "result_text": .string("line 1\nline 2"),
        ]))

        let sawBoth = await log.waitUntil {
            !EventDigest.toolStarts($0).isEmpty && !EventDigest.toolCompletions($0).isEmpty
        }
        XCTAssertTrue(sawBoth)

        let start = try XCTUnwrap(EventDigest.toolStarts(log.all).first)
        XCTAssertEqual(start.name, "read_file", "the card's label is the payload's `name`")
        XCTAssertEqual(start.callID, "call-1")
        XCTAssertEqual(start.input, #"{"path":"/tmp/x"}"#, "`args_text` is already the display string")

        let completion = try XCTUnwrap(EventDigest.toolCompletions(log.all).first)
        XCTAssertEqual(completion.name, "read_file", "a completion names the tool too")
        XCTAssertEqual(completion.callID, "call-1")
        XCTAssertEqual(completion.output, "line 1\nline 2", "`result_text` wins over the structured result")
        XCTAssertEqual(completion.durationMS, 800)
        XCTAssertEqual(completion.ok, true)
    }

    /// A tool with no `result_text` still has something to show: the structured `result`, then the
    /// one-line `summary`. Reading only the missing key is what printed "No output.".
    func testToolOutputFallsBackFromResultToSummary() async throws {
        let fake = FakeGateway()
        let log = EventLog()
        let client = try await connect(fake, log: log)
        _ = client

        await fake.emit(event: "tool.complete", session: "rt-1", payload: .object([
            "tool_id": .string("call-2"),
            "name": .string("bash"),
            "result": .object(["stdout": .string("ok"), "exit_code": .int(0)]),
        ]))
        await fake.emit(event: "tool.complete", session: "rt-1", payload: .object([
            "tool_id": .string("call-3"),
            "name": .string("web_search"),
            "summary": .string("3 results"),
        ]))

        let sawBoth = await log.waitUntil { EventDigest.toolCompletions($0).count == 2 }
        XCTAssertTrue(sawBoth)
        let completions = EventDigest.toolCompletions(log.all)
        let structured = try XCTUnwrap(completions.first?.output)
        XCTAssertTrue(structured.contains("stdout"), "a JSON-only result is stringified, not blank: \(structured)")
        XCTAssertTrue(structured.contains("ok"))
        XCTAssertEqual(completions.last?.output, "3 results")
    }

    /// `tool.start` may describe the call in `args`, `context` or a one-line `preview`; an empty
    /// row is the alternative, and it reads as a broken card.
    func testToolInputSurvivesAnArgumentsObjectAndAPreview() async throws {
        let fake = FakeGateway()
        let log = EventLog()
        let client = try await connect(fake, log: log)
        _ = client

        await fake.emit(event: "tool.start", session: "rt-1", payload: .object([
            "tool_id": .string("c1"),
            "name": .string("bash"),
            "args": .object(["command": .string("ls -la")]),
        ]))
        await fake.emit(event: "tool.start", session: "rt-1", payload: .object([
            "tool_id": .string("c2"),
            "name": .string("read_file"),
            "context": .string("/vault/notes.md"),
        ]))

        let sawBoth = await log.waitUntil { EventDigest.toolStarts($0).count == 2 }
        XCTAssertTrue(sawBoth)
        let starts = EventDigest.toolStarts(log.all)
        guard starts.count == 2 else { return XCTFail("expected two starts, got \(starts)") }
        XCTAssertTrue(starts[0].input.contains("ls -la"), "args are stringified for display: \(starts[0].input)")
        XCTAssertEqual(starts[1].input, "/vault/notes.md")
    }

    // MARK: Reasoning

    /// Measured: `thinking.delta` arrives as `{"text": "..."}` and, repeatedly, `{"text": ""}` while
    /// the model is still deciding. The empty heartbeat is not content; a client that treated it as
    /// a chunk appended "", and one that treated it as a boundary cleared the reasoning it had.
    func testEmptyThinkingDeltaIsAHeartbeatAndNeverClearsReasoning() async throws {
        let fake = FakeGateway()
        let log = EventLog()
        let client = try await connect(fake, log: log)
        _ = client

        await fake.emit(event: "thinking.delta", session: "rt-1", payload: .object([:]))
        await fake.emit(event: "thinking.delta", session: "rt-1", payload: .object(["text": .string("")]))
        await fake.emit(event: "thinking.delta", session: "rt-1", payload: .object(["text": .string("Vault first.")]))
        await fake.emit(event: "thinking.delta", session: "rt-1", payload: .object(["text": .string("")]))
        await fake.emit(event: "thinking.delta", session: "rt-1", payload: .object(["text": .string(" Then docs.")]))

        let sawReasoning = await log.waitUntil { EventDigest.reasoningDeltas($0).count == 2 }
        XCTAssertTrue(sawReasoning)
        XCTAssertEqual(EventDigest.reasoningDeltas(log.all), ["Vault first.", " Then docs."],
                       "only real text reaches the reasoning stream, in order, never cleared")
        XCTAssertTrue(EventDigest.deltas(log.all).isEmpty,
                      "reasoning is not the reply: nothing may leak into the assistant stream")
        XCTAssertFalse(EventDigest.unknownTypes(log.all).contains("thinking.delta"),
                       "a modelled heartbeat is not an unknown event")
    }

    // MARK: Streaming state after a resume

    /// A turn that finished while the socket was down has no `message.complete` left to deliver,
    /// so the resume's `inflight` is the only authority on whether anything is still running. An
    /// app that kept its own streaming flag sat on "Thinking…" forever.
    func testResumeWithNoInflightReportsNoStreamingTurn() async throws {
        let fake = FakeGateway()
        await fake.setResult(.object([
            "session_id": .string("rt-1"),
            "stored_session_id": .string("stored-1"),
            "messages": .array([
                .object(["role": .string("assistant"), "text": .string("Done."), "row_id": .int(12)]),
            ]),
            "open_requests": .array([]),
        ]), for: "session.resume")
        let client = makeClient(fake)
        try await client.connect()

        let resumed = try await client.resumeSession("stored-1")

        XCTAssertNil(resumed.inflight)
        XCTAssertFalse(resumed.isStreaming, "no inflight turn means nothing more is coming")
        XCTAssertEqual(resumed.liveText, "")
        XCTAssertEqual(resumed.entries.map(\.text), ["Done."])
    }

    /// A non-streaming inflight is a settled turn whose text was never flushed: the text is worth
    /// keeping, the spinner is not.
    func testResumeWithANonStreamingInflightKeepsTheTextAndStopsStreaming() async throws {
        let fake = FakeGateway()
        await fake.setResult(FakeGateway.resumeResult(storedID: "stored-1",
                                                      assistant: "Hello wor",
                                                      streaming: false),
                             for: "session.resume")
        let client = makeClient(fake)
        try await client.connect()

        let resumed = try await client.resumeSession("stored-1")

        XCTAssertFalse(resumed.isStreaming)
        XCTAssertEqual(resumed.liveText, "Hello wor", "the partial reply survives, the streaming flag does not")
    }

    // MARK: Context usage and compaction

    /// `usage` rides on the completion, and the compaction threshold is read from it. It is
    /// published *before* the completion so a model that reacts to `messageComplete` already sees
    /// the number.
    func testMessageCompleteCarriesContextUsageBeforeTheCompletion() async throws {
        let fake = FakeGateway()
        let log = EventLog()
        let client = try await connect(fake, log: log)
        _ = client

        await fake.emit(event: "message.complete", session: "rt-1", payload: .object([
            "text": .string("Done."),
            "usage": .object([
                "context_used": .int(210_000),
                "context_max": .int(400_000),
                "context_percent": .double(52.5),
            ]),
        ]))

        let saw = await log.waitUntil { !EventDigest.completions($0).isEmpty }
        XCTAssertTrue(saw)
        let usage = try XCTUnwrap(EventDigest.contextUsages(log.all).first)
        XCTAssertEqual(usage.used, 210_000)
        XCTAssertEqual(usage.max, 400_000)
        XCTAssertEqual(usage.percent, 52.5)

        let kinds = log.all.map { event -> String in
            switch event {
            case .contextUsage: return "usage"
            case .messageComplete: return "complete"
            default: return "other"
            }
        }.filter { $0 != "other" }
        XCTAssertEqual(kinds, ["usage", "complete"], "the count must be public before the turn is declared over")
    }

    /// A completion without `usage` is normal (older hosts, interrupted turns) and must not be
    /// reported as "0 of 0".
    func testAMessageCompleteWithoutUsageReportsNothing() async throws {
        let fake = FakeGateway()
        let log = EventLog()
        let client = try await connect(fake, log: log)
        _ = client

        await fake.emit(event: "message.complete", session: "rt-1", payload: .object(["text": .string("hi")]))

        let saw = await log.waitUntil { !EventDigest.completions($0).isEmpty }
        XCTAssertTrue(saw)
        XCTAssertTrue(EventDigest.contextUsages(log.all).isEmpty)
    }

    /// `session.compress` addresses the **runtime** id; the stored id is refused with `4001` on a
    /// healthy socket, exactly like `prompt.submit` was.
    func testCompressAddressesTheRuntimeIDOfTheResumedSession() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        try await client.connect()
        _ = try await client.resumeSession("stored-1")

        try await client.compress(session: "stored-1")

        let params = await fake.params(method: "session.compress")
        XCTAssertEqual(params?["session_id"]?.stringValue, "rt-1",
                       "the runtime id every live-session call needs")
    }

    // MARK: Model label

    /// Measured `model.options`: `providers[0]` is Anthropic, while the host is running
    /// `deepseek-v4.1-flash` on `opencode-go` — named at the top level of the reply.
    func testModelCatalogReportsTheTopLevelModelNotTheFirstProviderEntry() async throws {
        let fake = FakeGateway()
        await fake.setResult(.object([
            "providers": .array([
                .object(["slug": .string("anthropic"), "name": .string("Anthropic"),
                         "models": .array([.string("claude-fable"), .string("claude-sonnet")])]),
                .object(["slug": .string("opencode-go"), "name": .string("OpenCode"),
                         "models": .array([.string("deepseek-v4.1-flash")])]),
            ]),
            "model": .string("deepseek-v4.1-flash"),
            "provider": .string("opencode-go"),
        ]), for: "model.options")
        let client = makeClient(fake)
        try await client.connect()

        let catalog = try await client.modelCatalog()

        XCTAssertEqual(catalog.current?.id, "deepseek-v4.1-flash")
        XCTAssertEqual(catalog.current?.provider, "opencode-go")
        XCTAssertEqual(catalog.options.first?.id, "claude-fable",
                       "the menu's first entry is not the running model")
        XCTAssertEqual(catalog.options.map(\.provider), ["anthropic", "anthropic", "opencode-go"])
    }

    /// A reply with no `model` still carries its menu, and no current model is reported rather than
    /// the first entry being guessed into the chip.
    func testModelCatalogWithoutACurrentModelIsNotAGuess() async throws {
        let fake = FakeGateway()
        await fake.setResult(.object([
            "providers": .array([
                .object(["slug": .string("solo"), "models": .array([.string("only")])]),
            ]),
        ]), for: "model.options")
        let client = makeClient(fake)
        try await client.connect()

        let catalog = try await client.modelCatalog()

        XCTAssertNil(catalog.current)
        XCTAssertEqual(catalog.options.map(\.id), ["only"])
    }
}
