#if canImport(Combine)
import Foundation
import XCTest
@testable import HermesAppKit
import HermesKit

/// A host error belongs to the conversation its frame named — not to whatever pane is open.
///
/// From the owner's screenshot: the `cody` pane carried "Hermes could not start the assistant for this
/// session … No LLM provider configured" while cody's own conversation was fine. One socket serves
/// every bot the app opens, including the background sessions it opens to read previews, so an error
/// from one of those was painted over the transcript on screen. The frame's `session_id` is the only
/// thing that can tell them apart, and it now travels with the event.
@MainActor
final class HostErrorScopeTests: XCTestCase {

    private static let sessionID = "stored-error-scope"

    private func opened(_ label: String) async -> (AppModel, ScriptedHost) {
        let host = ScriptedHost(session: Self.sessionID,
                                entries: [TranscriptEntry(id: "row-1", role: .user, text: "are you there")])
        let model = AppModel(client: host, hostName: "errors-\(label)-\(UUID().uuidString)")
        await model.start()
        await model.select(Self.sessionID)
        return (model, host)
    }

    func testAnErrorForAnotherSessionIsNotPaintedHere() async {
        let (model, host) = await opened("other")
        XCTAssertEqual(model.selectedSessionID, Self.sessionID, "the pane has to be showing a conversation")

        host.emit(.error(session: "another-bots-session", code: nil,
                         message: "could not start the assistant: no LLM provider configured"))
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertNil(model.lastSendError, "another session's failure must not be painted in this one")
        XCTAssertEqual(model.transcript.map(\.text), ["are you there"], "the pane kept its own rows")
        await model.stop()
    }

    func testAnErrorForTheOpenSessionStillShows() async {
        let (model, host) = await opened("same")
        let open = model.selectedSessionID ?? ""

        host.emit(.error(session: open, code: 5001,
                         message: "session busy — Hermes is still replying…"))

        let shown = await waitUntil { model.lastSendError != nil }
        XCTAssertTrue(shown, "the conversation on screen is never silenced")
        XCTAssertEqual(model.lastSendError, "session busy — Hermes is still replying…")
        await model.stop()
    }

    func testAnErrorThatNamesNoSessionIsNotPaintedEither() async {
        let (model, host) = await opened("nameless")

        host.emit(.error(session: "", code: nil, message: "no LLM provider configured"))
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertNil(model.lastSendError,
                     "an error with no session cannot be placed, so it is logged and dropped")
        await model.stop()
    }

    private func waitUntil(timeout: Duration = .seconds(3),
                           _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
#endif
