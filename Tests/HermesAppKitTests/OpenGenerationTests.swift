#if canImport(Combine)
import Foundation
import XCTest
@testable import HermesAppKit
import HermesKit

/// One transcript, two bots, and a resume that answers after the user has moved on.
///
/// Reported 2026-11-20: *"a bot's window shows another bot's messages; sometimes self-corrects,
/// sometimes persists until the app is quit and reopened."* The model holds exactly one transcript
/// for whichever bot is on screen, and opening a bot awaits `session.resume` before writing it, with
/// no guard that the open is still the one the user is waiting for. Switch bots while that resume is
/// in flight and its answer lands in the window of the bot that replaced it — and because the rows
/// are drawn from `transcript`, nothing downstream can tell they are the wrong bot's.
///
/// The two facts these tests hold: a late answer is dropped (`botEpoch` still matches, or it does
/// not), and the transcript knows whose rows it is holding.
@MainActor
final class OpenGenerationTests: XCTestCase {

    private func row(_ text: String) -> TranscriptEntry {
        TranscriptEntry(id: "row-\(text)", role: .assistant, text: text)
    }

    /// An open model whose two bots answer with two different transcripts, the first one slowly.
    ///
    /// The endless-session key lives in `UserDefaults`, which outlives a test method: clearing it is
    /// what makes "the host has no Bot Chat yet" the state the test starts from.
    private func model() async -> (AppModel, ScriptedHost) {
        let alpha = "alpha-\(UUID().uuidString)"
        let beta = "beta-\(UUID().uuidString)"
        let client = ScriptedHost(session: "\(alpha)-session")
        client.bots = [Bot(id: alpha), Bot(id: beta)]
        client.entriesByProfile = [alpha: [row("alpha's reply")],
                                   beta: [row("beta's reply")]]
        client.sessionByProfile = [alpha: "\(alpha)-session", beta: "\(beta)-session"]
        client.resumeDelayByProfile = [alpha: .milliseconds(300), beta: .milliseconds(5)]
        UserDefaults.standard.removeObject(forKey: "hermes.endlessSession.\(alpha)")
        UserDefaults.standard.removeObject(forKey: "hermes.endlessSession.\(beta)")
        let model = AppModel(client: client, hostName: "generation-\(UUID().uuidString)")
        await model.start()
        return (model, client)
    }

    /// Two interleaved opens: only the last one lands.
    func test_a_resume_that_answers_after_the_bot_switch_is_dropped() async {
        let (model, client) = await self.model()
        let alpha = client.bots[0].id
        let beta = client.bots[1].id

        await model.selectBot(alpha)
        // Alpha's resume is in flight (300 ms) when the user picks beta.
        let opening = Task { await model.openStoredConversation("\(alpha)-session",
                                                                botID: alpha, publish: false) }
        try? await Task.sleep(for: .milliseconds(60))
        await model.selectBot(beta)
        let betaOutcome = await model.openStoredConversation("\(beta)-session",
                                                             botID: beta, publish: false)
        // The slow answer arrives *after* beta is on screen.
        let alphaOutcome = await opening.value
        try? await Task.sleep(for: .milliseconds(350))

        XCTAssertEqual(model.selectedBotID, beta)
        if case .opened = betaOutcome {} else { XCTFail("beta's own open did not land") }
        if case .opened = alphaOutcome { XCTFail("the stale open reported success") }
        XCTAssertEqual(model.transcript.map(\.text), ["beta's reply"],
                       "alpha's rows were drawn in beta's window")
        XCTAssertEqual(model.transcriptOwner, beta)
    }

    /// The stronger half: rows for a bot that is not on screen are refused even with the right epoch,
    /// because the check is on the transcript's owner and not only on a counter.
    func test_rows_for_a_bot_that_is_not_on_screen_are_refused() async {
        let (model, client) = await self.model()
        let alpha = client.bots[0].id
        let beta = client.bots[1].id

        await model.selectBot(alpha)
        _ = await model.openStoredConversation("\(alpha)-session", botID: alpha, publish: false)
        XCTAssertEqual(model.transcriptOwner, alpha)

        // Beta's transcript, asked for while alpha is the bot on screen: no epoch has moved, so only
        // the owner check can stop this one.
        _ = await model.openStoredConversation("\(beta)-session", botID: beta, publish: false)

        XCTAssertEqual(model.transcript.map(\.text), ["alpha's reply"])
        XCTAssertEqual(model.transcriptOwner, alpha)
    }
}
#endif
