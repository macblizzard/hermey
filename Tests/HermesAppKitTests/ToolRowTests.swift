#if canImport(Combine)
import XCTest
@testable import HermesAppKit
import HermesKit

/// The end of a turn is where the tool cards used to fall off the screen.
///
/// While a turn runs, cards are drawn from `liveTools`, a section rendered *after* every
/// transcript row. The instant `message.complete` appended the answer, the cards sat below the
/// reply they produced, and the next resume — the host answers with messages, not tool events —
/// erased them. These tests pin the fix: at the end of the turn the cards become `.tool`
/// transcript rows, in order, above the answer.
@MainActor
final class ToolRowTests: XCTestCase {

    private func openModel(entries: [TranscriptEntry]) async -> (AppModel, ScriptedHost) {
        let host = ScriptedHost(session: "s1", entries: entries)
        let model = AppModel(client: host)
        await model.start()
        await model.select("s1")
        return (model, host)
    }

    private func waitUntil(_ condition: @escaping () -> Bool,
                           timeout: TimeInterval = 3,
                           file: StaticString = #filePath,
                           line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition not met within \(timeout)s", file: file, line: line)
    }

    /// A completed call lands in the thread above the answer, not under it.
    func testCompletedToolLandsAboveTheAnswer() async throws {
        let (model, host) = await openModel(entries: [
            TranscriptEntry(id: "u1", role: .user, text: "check the uptime on the box"),
        ])
        XCTAssertEqual(model.transcript.map(\.role), [.user])

        host.emit(.toolStart(session: "s1", name: "terminal", callID: "t1", input: "uptime\n"))
        await waitUntil { model.liveTools.count == 1 }
        XCTAssertTrue(model.liveTools[0].isRunning)

        host.emit(.toolComplete(session: "s1",
                                name: "terminal",
                                callID: "t1",
                                output: "up 3 days",
                                ok: true,
                                durationMS: 1_200))
        host.emit(.messageDelta(session: "s1", text: "Casa is up"))
        host.emit(.messageComplete(session: "s1", text: "Casa is up 3 days, 20:49."))
        await waitUntil { model.transcript.count == 3 }

        XCTAssertEqual(model.transcript.map(\.role), [.user, .tool, .assistant])
        XCTAssertEqual(model.transcript[1].text, "terminal · uptime · 1.2s",
                       "the row must be the projection shape both apps parse back into a card")
        XCTAssertEqual(model.transcript[2].text, "Casa is up 3 days, 20:49.")
        XCTAssertEqual(model.transcript[1].tool?.name, "terminal",
                       "the flushed row keeps the tool's identity for the card")
        XCTAssertEqual(model.transcript[1].tool?.args, "uptime\n",
                       "the arguments survive the turn, so a tap can still show what ran")
        XCTAssertEqual(model.transcript[1].tool?.content, "up 3 days",
                       "and so does the result")
        XCTAssertTrue(model.liveTools.isEmpty, "the live cards moved into the transcript")
        XCTAssertFalse(model.isStreaming)
    }

    /// A call that never completed keeps its row and says so instead of inventing a duration.
    func testInterruptedToolStillLeavesARow() async throws {
        let (model, host) = await openModel(entries: [
            TranscriptEntry(id: "u1", role: .user, text: "run the long thing"),
        ])

        host.emit(.toolStart(session: "s1", name: "terminal", callID: "t2", input: "sleep 90"))
        await waitUntil { model.liveTools.count == 1 }

        host.emit(.messageComplete(session: "s1", text: "Stopped after the interrupt."))
        await waitUntil { model.transcript.count == 3 }

        XCTAssertEqual(model.transcript.map(\.role), [.user, .tool, .assistant])
        XCTAssertEqual(model.transcript[1].text, "terminal · sleep 90 · interrupted")
        XCTAssertTrue(model.liveTools.isEmpty)
    }

    /// Cards from a finished turn must not bleed into the next one.
    func testNextTurnStartsWithAnEmptyLiveList() async throws {
        let (model, host) = await openModel(entries: [
            TranscriptEntry(id: "u1", role: .user, text: "first"),
        ])

        host.emit(.toolStart(session: "s1", name: "bash", callID: "a", input: "ls"))
        host.emit(.toolComplete(session: "s1", name: "bash", callID: "a", output: "", ok: true, durationMS: 20))
        host.emit(.messageComplete(session: "s1", text: "done"))
        await waitUntil { model.transcript.count == 3 }

        host.emit(.toolStart(session: "s1", name: "read_file", callID: "b", input: "README.md"))
        await waitUntil { model.liveTools.count == 1 }

        XCTAssertEqual(model.liveTools.map(\.name), ["read_file"])
        XCTAssertEqual(model.transcript.filter { $0.role == .tool }.count, 1,
                       "the finished turn's card stayed where it happened")
    }

    /// Reasoning is streamed on its own channel and must outlive the answer that ended it.
    func testReasoningStaysInTheThreadAfterTheAnswer() async throws {
        let (model, host) = await openModel(entries: [
            TranscriptEntry(id: "u1", role: .user, text: "check build-host"),
        ])

        host.emit(.thinkingDelta(session: "s1", text: "build-host answers over tailscale; read uptime."))
        await waitUntil { !model.reasoningText.isEmpty }

        host.emit(.messageComplete(session: "s1", text: "up 42 days"))
        await waitUntil { model.transcript.count == 3 }

        XCTAssertEqual(model.transcript.map(\.role), [.user, .reasoning, .assistant])
        XCTAssertEqual(model.transcript[1].text, "build-host answers over tailscale; read uptime.")
        XCTAssertTrue(model.reasoningText.isEmpty, "the live bubble is cleared once the row holds it")
    }

    /// The row text has to survive `MobileToolRow.parse`; that means a single-token name first.
    func testRowTextShape() {
        let named = AppModel.LiveTool(id: "x", name: "bash", input: "rsync -a ~/vault/ ~/backup/", durationMS: 800)
        XCTAssertEqual(AppModel.toolRowText(named), "bash · rsync -a ~/vault/ ~/backup/ · 800 ms")

        let bare = AppModel.LiveTool(id: "y", name: "bash", output: nil, isRunning: false, durationMS: 65_000)
        XCTAssertEqual(AppModel.toolRowText(bare), "bash · 65.0s")

        let unnamed = AppModel.LiveTool(id: "z", name: "", isRunning: true)
        XCTAssertEqual(AppModel.toolRowText(unnamed), "unknown tool · interrupted")
    }
}
#endif
