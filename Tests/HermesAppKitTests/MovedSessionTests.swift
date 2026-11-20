#if canImport(Combine)
import Combine
import Foundation
import XCTest
@testable import HermesAppKit
import HermesKit

/// B3 — the transcript refuses the conversation it is looking at.
///
/// Reported 2026-11-20, from a screenshot: the sidebar showed cody's newest message at 20:51 with an
/// unread badge of 1, and the open cody window did not show it. The app had received the message and
/// recorded it (preview and badge), and the transcript refused to draw it: every branch of
/// `apply(_:)` returned early because the event's session id was not the one this window resumed.
///
/// The host mints a **runtime** session id per attach and a new session id when a conversation
/// starts, so the two diverge exactly when the owner is waiting for a reply. Three rules come out of
/// it, and each has a test here: a move is adopted (the bot has one conversation, the window follows
/// it), another bot's traffic is never drawn here, and a badge the current thread can clear is not a
/// badge at all.
@MainActor
final class MovedSessionTests: XCTestCase {

    private func row(_ text: String) -> TranscriptEntry {
        TranscriptEntry(id: "row-\(text)", role: .assistant, text: text)
    }

    /// Two bots, each with one conversation this launch has already seen, and a host that answers a
    /// resume for whatever id is asked — which is what makes a *second* session id scriptable.
    private func model(alpha: String, beta: String?) async -> (AppModel, ScriptedHost) {
        let client = ScriptedHost(session: "\(alpha)-live")
        var bots = [Bot(id: alpha)]
        client.sessionByProfile = [alpha: "\(alpha)-live"]
        client.entriesByProfile = [alpha: [row("older reply")]]
        if let beta {
            bots.append(Bot(id: beta))
            client.sessionByProfile[beta] = "\(beta)-live"
            client.entriesByProfile[beta] = [row("beta's reply")]
            UserDefaults.standard.removeObject(forKey: "hermes.endlessSession.\(beta)")
        }
        client.bots = bots
        UserDefaults.standard.removeObject(forKey: "hermes.endlessSession.\(alpha)")
        let model = AppModel(client: client, hostName: "moved-\(UUID().uuidString)")
        await model.start()
        return (model, client)
    }

    /// Wait until the transcript satisfies a predicate, driven by the published value and not a clock.
    private func expect(_ model: AppModel, transcript matching: @escaping ([TranscriptEntry]) -> Bool,
                        file: StaticString = #filePath, line: UInt = #line) async {
        let gate = expectation(description: "transcript matched")
        let sink = model.$transcript.filter(matching).prefix(1).sink { _ in gate.fulfill() }
        await fulfillment(of: [gate], timeout: 2)
        withExtendedLifetime(sink) {}
    }

    /// The report itself: the event names a session the window is not showing, and it is still the
    /// open bot's own conversation (a new session started, or the host minted a fresh runtime id).
    func test_an_event_for_the_open_bots_moved_session_is_painted() async {
        let alpha = "alpha-\(UUID().uuidString)"
        let (model, client) = await self.model(alpha: alpha, beta: nil)
        let moved = "\(alpha)-moved"
        client.entriesByRequestedID[moved] = [row("older reply"), row("the reply that never appeared")]
        // The host names the durable conversation beside the new runtime id: the same chat, so the
        // window may follow it.
        client.storedByRequestedID[moved] = "\(alpha)-live"

        await model.selectBot(alpha)
        await model.select("\(alpha)-live")
        await expect(model, transcript: { $0.last?.text == "older reply" })

        client.emit(.messageComplete(session: moved, text: "the reply that never appeared"))
        await expect(model, transcript: { $0.last?.text == "the reply that never appeared" })

        XCTAssertEqual(model.selectedSessionID, moved, "the window did not follow the conversation")
        XCTAssertEqual(model.transcript.map(\.text), ["older reply", "the reply that never appeared"],
                       "the host's page for the moved conversation, and no duplicate of the completion")
        XCTAssertEqual(model.transcriptOwner, alpha, "the adopted rows are not filed under the open bot")
        XCTAssertTrue(client.resumed.contains(moved), "the moved session was never asked about")
    }

    /// One resume per moved id, even though a turn sends many events under the new id.
    func test_a_moved_session_is_resumed_once() async {
        let alpha = "alpha-\(UUID().uuidString)"
        let (model, client) = await self.model(alpha: alpha, beta: nil)
        let moved = "\(alpha)-moved"
        client.entriesByRequestedID[moved] = [row("older reply")]
        client.storedByRequestedID[moved] = "\(alpha)-live"

        await model.selectBot(alpha)
        await model.select("\(alpha)-live")

        client.emit(.messageDelta(session: moved, text: "one "))
        client.emit(.messageDelta(session: moved, text: "two "))
        client.emit(.messageDelta(session: moved, text: "three"))
        // A delta lands in the live bubble, not in the transcript: the turn completes before rows exist.
        let gate = expectation(description: "the turn's words reached the conversation")
        let sink = model.$streamingText.filter { $0.contains("three") }.prefix(1).sink { _ in gate.fulfill() }
        await fulfillment(of: [gate], timeout: 2)
        withExtendedLifetime(sink) {}

        XCTAssertEqual(client.resumed.filter { $0 == moved }.count, 1,
                       "every frame of the turn asked the host again")
        XCTAssertEqual(model.selectedSessionID, moved)
    }

    /// A session this launch has already attributed to another bot is that bot's, and is never drawn
    /// in the open window — the defect reports 5 and 6 are about.
    func test_another_bots_moved_session_is_only_counted() async {
        let alpha = "alpha-\(UUID().uuidString)"
        let beta = "beta-\(UUID().uuidString)"
        let (model, client) = await self.model(alpha: alpha, beta: beta)

        await model.selectBot(alpha)
        await model.select("\(alpha)-live")
        await model.selectBot(beta)
        await model.select("\(beta)-live")
        await expect(model, transcript: { $0.last?.text == "beta's reply" })
        let before = client.resumed.count

        client.emit(.messageComplete(session: "\(alpha)-live", text: "alpha said something"))
        // No adoption means no resume; give the event loop a turn to have done it if it were going to.
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(client.resumed.count, before, "another bot's session was asked about")
        XCTAssertEqual(model.transcript.map(\.text), ["beta's reply"],
                       "another bot's reply was drawn in beta's window")
        XCTAssertEqual(model.transcriptOwner, beta)
    }

    /// The guard that makes reports 5 and 6 impossible rather than unlikely: the host answers a
    /// durable id that this window does not hold, so the conversation is a *different* one and is
    /// never painted here. The window keeps what it has and the id is only counted as unseen.
    func test_a_different_conversation_never_takes_the_window() async {
        let alpha = "alpha-\(UUID().uuidString)"
        let (model, client) = await self.model(alpha: alpha, beta: nil)
        let stranger = "\(alpha)-somebody-elses"
        client.entriesByRequestedID[stranger] = [row("not alpha's conversation")]
        client.storedByRequestedID[stranger] = "another-bot-durable"

        await model.selectBot(alpha)
        await model.select("\(alpha)-live")
        await expect(model, transcript: { $0.last?.text == "older reply" })

        client.emit(.messageComplete(session: stranger, text: "not alpha's conversation"))
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(model.selectedSessionID, "\(alpha)-live", "another conversation took the window")
        XCTAssertEqual(model.transcript.map(\.text), ["older reply"], "another conversation's rows were drawn")
        XCTAssertEqual(model.transcriptOwner, alpha)
    }

    /// A badge the thread cannot clear is the defect, not a cosmetic issue: cody's window was open on
    /// an unread of 1.
    func test_a_current_transcript_clears_its_badge() async {
        let alpha = "alpha-\(UUID().uuidString)"
        let (model, client) = await self.model(alpha: alpha, beta: nil)

        await model.selectBot(alpha)
        await model.select("\(alpha)-live")
        model.markUnread(alpha)
        XCTAssertTrue(model.hasUnread(alpha), "the fixture could not raise a badge to clear")

        client.emit(.messageComplete(session: "\(alpha)-live", text: "the new reply"))
        await expect(model, transcript: { $0.last?.text == "the new reply" })
        try? await Task.sleep(for: .milliseconds(60))

        XCTAssertFalse(model.hasUnread(alpha), "the open conversation kept its unread badge")
        XCTAssertEqual(model.unreadCounts[alpha] ?? 0, 0)
    }

    /// Resolving another bot's conversation is a read. Only navigation moves the screen.
    func test_looking_up_another_bots_conversation_does_not_move_the_screen() async {
        let alpha = "alpha-\(UUID().uuidString)"
        let beta = "beta-\(UUID().uuidString)"
        let (model, client) = await self.model(alpha: alpha, beta: beta)

        await model.selectBot(alpha)
        await model.select("\(alpha)-live")
        await expect(model, transcript: { $0.last?.text == "older reply" })
        let resumes = client.resumed.count
        UserDefaults.standard.set("\(beta)-stored", forKey: "hermes.endlessSession.\(beta)")

        let resolved = await model.conversationID(for: beta)

        XCTAssertEqual(resolved, "\(beta)-stored", "the lookup did not answer for the bot it was asked about")
        XCTAssertEqual(model.selectedBotID, alpha, "a background lookup moved the selection")
        XCTAssertEqual(model.selectedSessionID, "\(alpha)-live", "a background lookup moved the conversation")
        XCTAssertEqual(model.transcript.map(\.text), ["older reply"], "a background lookup repainted the pane")
        XCTAssertEqual(client.resumed.count, resumes, "the lookup resumed something")
    }
}
#endif
