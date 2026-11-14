import XCTest
@testable import HermesKit

/// The memory sheet draws two documents, and the difference it must never lose is between *nothing
/// remembered* and *something unreadable*: only one of those needs the owner to do anything.
final class BotMemoryTests: XCTestCase {
    private func memory(_ json: String) -> BotMemory? {
        BotMemory.decode(Data(json.utf8))
    }

    func testItReadsBothDocuments() {
        let value = memory("""
        {"profile": "cody",
         "memory": {"name": "MEMORY.md", "label": "What it noted for itself",
                    "text": "Memories saved this session\\n- a fact\\n", "chars": 29, "present": true},
         "user": {"name": "USER.md", "label": "What it knows about you",
                  "text": "User profile\\n- short replies\\n", "chars": 27, "present": true}}
        """)

        XCTAssertNotNil(value)
        XCTAssertEqual(value?.memory.name, "MEMORY.md")
        XCTAssertEqual(value?.memory.chars, 29)
        XCTAssertTrue(value?.memory.text.contains("a fact") == true)
        XCTAssertEqual(value?.user.name, "USER.md")
        XCTAssertFalse(value?.isEmpty ?? true)
    }

    func testANewBotIsTwoEmptyDocumentsAndThatIsAnAnswer() {
        let value = memory("""
        {"memory": {"name": "MEMORY.md", "present": false, "text": "", "chars": 0},
         "user": {"name": "USER.md", "present": false, "text": "", "chars": 0}}
        """)

        XCTAssertTrue(value?.isEmpty == true)
        XCTAssertNil(value?.memory.error, "no file yet is not a fault")
        XCTAssertFalse(value?.memory.present ?? true)
    }

    func testAnUnreadableDocumentIsNotTheSameAsAnEmptyOne() {
        let value = memory("""
        {"memory": {"name": "MEMORY.md", "present": true, "text": "", "chars": 0,
                    "error": "larger than the 256 KB a phone will draw"},
         "user": {"present": false}}
        """)

        XCTAssertFalse(value?.isEmpty ?? true, "there is something to report, so this is not 'nothing'")
        XCTAssertEqual(value?.memory.error?.contains("larger") , true)
    }

    func testAPayloadThatIsNotAMemoryAnswerIsNil() {
        // A wrong shape must fail loudly at the call site rather than draw two blanks over a bot that
        // may have plenty remembered.
        XCTAssertNil(memory("not json"))
        XCTAssertNil(memory("{}"))
        XCTAssertNil(memory("{\"something\": 1}"))
    }

    func testTheSizeIsWhatIsReplayedIntoEveryTurn() {
        XCTAssertEqual(BotMemoryDocument(name: "MEMORY.md", label: "", chars: 0).sizeText,
                       "0 characters")
        XCTAssertEqual(BotMemoryDocument(name: "MEMORY.md", label: "", chars: 1).sizeText,
                       "1 character")
        // Grouped, because 2981 characters is a number a person reads at a glance.
        XCTAssertTrue(BotMemoryDocument(name: "MEMORY.md", label: "", chars: 2981)
            .sizeText.contains("2,981") || Locale.current.decimalSeparator == nil,
                      "the thousands separator follows the reader's locale")
    }

    func testAMissingCountIsTakenFromTheTextRatherThanSaidAsZero() {
        // An older host may omit `chars`; "0 characters" over a page of notes is a lie the screen
        // would be telling in its most prominent line.
        let value = memory("{\"memory\": {\"text\": \"four\"}, \"user\": {}}")
        XCTAssertEqual(value?.memory.chars, 4)
    }


    // MARK: - Staging a file for the share sheet

    func testStagingWritesOneFileUnderTheDocumentsOwnName() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("botmem-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try WorkspaceSharing.stage(Data("hello".utf8), named: "quarterly-deck.pdf",
                                             in: directory)

        XCTAssertEqual(url.lastPathComponent, "quarterly-deck.pdf")
        XCTAssertEqual(try Data(contentsOf: url), Data("hello".utf8))
    }

    func testAStagedNameCannotClimbOutOfTheTempFolder() throws {
        XCTAssertEqual(WorkspaceSharing.safeFileName("../../etc/passwd"), "passwd")
        XCTAssertEqual(WorkspaceSharing.safeFileName("reports/q3.md"), "q3.md")
        XCTAssertEqual(WorkspaceSharing.safeFileName(""), "document")
        XCTAssertEqual(WorkspaceSharing.safeFileName(".."), "document")
        XCTAssertEqual(WorkspaceSharing.safeFileName("   "), "document")
    }

    func testDiscardingRemovesTheStagedCopy() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("botmem-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try WorkspaceSharing.stage(Data("x".utf8), named: "a.txt", in: directory)
        WorkspaceSharing.discard(url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        // Discarding something that is already gone is not an error: the sheet can close twice.
        WorkspaceSharing.discard(url)
        WorkspaceSharing.discard(nil)
    }
}
