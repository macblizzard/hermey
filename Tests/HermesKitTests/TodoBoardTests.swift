import XCTest
@testable import HermesKit

/// The board is read back out of the rows the session already streams; these pin the reading rules.
final class TodoBoardTests: XCTestCase {

    private func toolRow(_ name: String, args: String? = nil, content: String? = nil,
                         id: String = UUID().uuidString) -> TranscriptEntry {
        TranscriptEntry(id: id, role: .tool, text: "",
                        tool: TranscriptEntry.ToolDetail(name: name, args: args, content: content))
    }

    private func payload(_ todos: String) -> String { "{\"todos\": [\(todos)]}" }

    func testTheNewestResultIsTheBoard() {
        let older = toolRow("todo_list", content: payload(
            #"{"id": "a", "content": "old", "status": "pending"}"#))
        let newer = toolRow("todo_list", content: payload(
            #"{"id": "a", "content": "new", "status": "completed"}"#))
        let board = TodoBoard.board(from: [older, newer])
        XCTAssertEqual(board?.items.first?.content, "new")
        XCTAssertEqual(board?.counts.done, 1)
    }

    func testTheResultBeatsTheCallArgumentsInTheSameRow() {
        let row = toolRow("todo_list",
                          args: payload(#"{"id": "a", "content": "called", "status": "pending"}"#),
                          content: payload(#"{"id": "a", "content": "result", "status": "in_progress"}"#))
        let board = TodoBoard.board(from: [row])
        XCTAssertEqual(board?.items.first?.content, "result")
        XCTAssertTrue(board?.isActive == true)
    }

    func testHistoryWithoutContentFallsBackToTheCallArguments() {
        // The display projection omits `content` for todo_list, so a resume only carries the call's
        // complete board. Without this the strip would disappear after every reload.
        let row = toolRow("todo_list", args: payload(
            #"{"id": "a", "content": "still here", "status": "pending"}"#))
        XCTAssertEqual(TodoBoard.board(from: [row])?.items.first?.content, "still here")
    }

    func testACallRowWithNoBoardContributesNothing() {
        let assistant = TranscriptEntry(id: "a1", role: .assistant, text: "working")
        XCTAssertNil(TodoBoard.board(from: [assistant]))
        XCTAssertNil(TodoBoard.board(from: [toolRow("terminal", args: "{\"cmd\":\"ls\"}")]))
    }

    func testSubtasksNestUnderTheirParent() {
        let board = TodoBoard.board(from: [toolRow("todo_list", content: payload(
            #"{"id": "p", "content": "parent", "status": "in_progress"}, "# +
            #"{"id": "c", "content": "child", "status": "pending", "parent": "p"}, "# +
            #"{"id": "g", "content": "grandchild", "status": "pending", "parent": "c"}"#))])
        XCTAssertEqual(board?.rows.map(\.item.id), ["p", "c", "g"])
        XCTAssertEqual(board?.rows.map(\.depth), [0, 1, 2])
    }

    func testAnOrphanIsDrawnAtTheRoot() {
        let board = TodoBoard.board(from: [toolRow("todo_list", content: payload(
            #"{"id": "c", "content": "child", "status": "pending", "parent": "missing"}"#))])
        XCTAssertEqual(board?.rows.first?.depth, 0)
        XCTAssertEqual(board?.rows.count, 1)
    }

    func testAllFourStatusesAreRead() {
        let board = TodoBoard.board(from: [toolRow("todo_list", content: payload(
            #"{"id":"1","content":"a","status":"completed"}, "# +
            #"{"id":"2","content":"b","status":"in_progress"}, "# +
            #"{"id":"3","content":"c","status":"pending"}, "# +
            #"{"id":"4","content":"d","status":"cancelled"}"#))])
        XCTAssertEqual(board?.items.map(\.status), [.completed, .inProgress, .pending, .cancelled])
        XCTAssertEqual(board?.counts.done, 1)
        XCTAssertEqual(board?.counts.inProgress, 1)
        XCTAssertEqual(board?.counts.cancelled, 1)
        XCTAssertTrue(board?.isActive == true)
        XCTAssertFalse(board?.isComplete == true)
    }

    func testAFinishedBoardIsComplete() {
        let board = TodoBoard.board(from: [toolRow("todo_list", content: payload(
            #"{"id":"1","content":"a","status":"completed"}, "# +
            #"{"id":"2","content":"b","status":"cancelled"}"#))])
        XCTAssertTrue(board?.isComplete == true)
        XCTAssertFalse(board?.isActive == true)
    }

    func testMalformedAndEmptyPayloadsAreNoBoard() {
        for text in ["", "not json", "{}", #"{"todos": []}"#, #"{"todos": [{"status": "pending"}]}"#,
                     #"{"todos": "nope"}"#] {
            XCTAssertNil(TodoBoard.board(from: [toolRow("todo_list", content: text)]),
                         "expected nil for \(text)")
        }
    }

    func testTheNewestMalformedRowDoesNotResurrectAnOlderBoard() {
        let valid = toolRow("todo_list", content: payload(
            #"{"id":"1","content":"a","status":"pending"}"#))
        let broken = toolRow("todo_list", content: "{")
        XCTAssertNil(TodoBoard.board(from: [valid, broken]))
    }

    func testLiveCardsAreSearchedBeforeTheTranscript() {
        let stored = toolRow("todo_list", content: payload(
            #"{"id":"1","content":"stored","status":"pending"}"#))
        let live = toolRow("todo_list", content: payload(
            #"{"id":"1","content":"live","status":"in_progress"}"#))
        let board = TodoBoard.board(from: [stored], live: [live])
        XCTAssertEqual(board?.items.first?.content, "live")
    }
}
