import XCTest
@testable import HermesKit

/// The pet's chat, as a value: both roles in one thread, a hard twenty, and a clamp that keeps a
/// long model answer from turning a speech bubble into a page.
final class PetChatTests: XCTestCase {

    // MARK: - The conversation

    func testBothRolesAreMessagesInOneOrderedThread() {
        var chat = PetConversation()
        XCTAssertTrue(chat.append(PetMessage(role: .owner, text: "status?")))
        XCTAssertTrue(chat.append(PetMessage(role: .bot, text: "All green.")))
        XCTAssertEqual(chat.count, 2)
        XCTAssertEqual(chat.messages.map(\.role), [.owner, .bot])
        XCTAssertEqual(chat.lastOwnerMessage?.text, "status?")
        XCTAssertEqual(chat.lastBotMessage?.text, "All green.")
    }

    func testTwentyMessagesAndThenRoomForNothingElse() {
        var chat = PetConversation()
        for index in 0..<18 {
            let role: PetMessage.Role = index.isMultiple(of: 2) ? .owner : .bot
            XCTAssertTrue(chat.append(PetMessage(role: role, text: "m\(index)")))
        }
        // Eighteen messages is one question plus its answer, in a twenty-message conversation.
        XCTAssertTrue(chat.canAddExchange)
        XCTAssertFalse(chat.isFull)
        XCTAssertTrue(chat.append(PetMessage(role: .owner, text: "last question")))
        XCTAssertTrue(chat.append(PetMessage(role: .bot, text: "last answer")))
        XCTAssertEqual(chat.count, PetConversation.maxMessages)
        XCTAssertTrue(chat.isFull)
        XCTAssertFalse(chat.canAddExchange)
        XCTAssertFalse(chat.append(PetMessage(role: .owner, text: "one too many")),
                       "the cap holds on the way in, not only in the view")
        XCTAssertEqual(chat.count, 20)
    }

    func testATurnThatFailedLeavesOneMessageAndStillCloses() {
        var chat = PetConversation()
        for index in 0..<19 {
            chat.append(PetMessage(role: index.isMultiple(of: 2) ? .owner : .bot, text: "m\(index)"))
        }
        XCTAssertEqual(chat.count, 19, "a failure leaves the question without its answer")
        XCTAssertTrue(chat.isFull, "a nineteenth question has nowhere to put a twentieth message")
    }

    func testResetIsTheOnlyThingThatEmptiesIt() {
        var chat = PetConversation(messages: [PetMessage(role: .owner, text: "hi")])
        XCTAssertFalse(chat.isEmpty)
        chat.reset()
        XCTAssertTrue(chat.isEmpty)
        XCTAssertFalse(chat.isFull)
    }

    func testAStoredThreadCannotWidenTheCap() {
        let many = (0..<40).map { PetMessage(role: .owner, text: "m\($0)") }
        let chat = PetConversation(messages: many)
        XCTAssertEqual(chat.count, PetConversation.maxMessages)
        XCTAssertEqual(chat.messages.first?.text, "m20", "the newest are the ones worth keeping")
    }

    // MARK: - Brevity

    func testAShortAnswerIsLeftAlone() {
        XCTAssertEqual(PetBrevity.clamp("All green."), "All green.")
    }

    func testTwoSentencesAndNoMore() {
        let long = "All green. Two jobs are running. The third is queued."
        XCTAssertEqual(PetBrevity.clamp(long), "All green. Two jobs are running.…")
        XCTAssertTrue(PetBrevity.clamp(long).hasSuffix("…"))
    }

    func testTheSecondParagraphNeverShows() {
        XCTAssertEqual(PetBrevity.clamp("Done.\n\nHere is why, at length."), "Done.",
                       "one paragraph: a list or an essay's second paragraph is not a pet's answer")
    }

    func testADecimalIsNotASentenceBreak() {
        XCTAssertEqual(PetBrevity.clamp("Version 3.5 is live."), "Version 3.5 is live.")
    }

    func testTheCharacterLimitCutsOnAWordAndSaysSo() {
        let words = Array(repeating: "word", count: 200).joined(separator: " ")
        let shown = PetBrevity.clamp(words)
        XCTAssertLessThanOrEqual(shown.count, PetBrevity.characterLimit + 1) // + the ellipsis
        XCTAssertTrue(shown.hasSuffix("…"))
        XCTAssertFalse(shown.hasSuffix(" …"), "a word, not a stub of one")
        XCTAssertFalse(shown.contains("  "))
    }

    func testClampingNeverInventsText() {
        let text = "One sentence only."
        XCTAssertEqual(PetBrevity.clamp(text), text)
        XCTAssertEqual(PetBrevity.clamp("   "), "")
    }

    // MARK: - The store

    func testAThreadRoundTripsThroughDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pet-chat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = PetConversationStore(botID: "ops", root: root)
        var chat = PetConversation()
        chat.append(PetMessage(role: .owner, text: "status?"))
        chat.append(PetMessage(role: .bot, text: "All green."))
        store.save(chat)

        let reopened = PetConversationStore(botID: "ops", root: root).load()
        XCTAssertEqual(reopened, chat, "a relaunch opens the same thread")
        XCTAssertEqual(reopened.messages.map(\.role), [.owner, .bot])
    }

    func testOneBotCannotReadAnothersFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pet-chat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var chat = PetConversation()
        chat.append(PetMessage(role: .owner, text: "mine"))
        PetConversationStore(botID: "ops", root: root).save(chat)

        XCTAssertTrue(PetConversationStore(botID: "tinker", root: root).load().isEmpty)
        XCTAssertNotEqual(PetConversationStore(botID: "ops", root: root).fileURL,
                          PetConversationStore(botID: "tinker", root: root).fileURL)
    }

    func testACorruptFileIsAMissAndIsRemoved() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pet-chat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = PetConversationStore(botID: "ops", root: root)
        try Data("not a chat".utf8).write(to: store.fileURL)

        XCTAssertTrue(store.load().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path),
                       "a file that will not decode is deleted, never repaired")
    }

    func testClearingRemovesTheFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pet-chat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = PetConversationStore(botID: "ops", root: root)
        var chat = PetConversation()
        chat.append(PetMessage(role: .owner, text: "hi"))
        store.save(chat)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))

        store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertTrue(store.load().isEmpty)
    }

    func testAnEmptyThreadLeavesNoFileRatherThanAnEmptyOne() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pet-chat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = PetConversationStore(botID: "ops", root: root)
        store.save(PetConversation())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }
}
