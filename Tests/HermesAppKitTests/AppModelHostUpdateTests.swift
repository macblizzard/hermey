#if canImport(Combine)
import Foundation
import XCTest
@testable import HermesAppKit
import HermesKit

/// The host version and the **Check now** press, driven through the model.
///
/// Two reports from the owner, one cause: the host ran 0.8.14 while Settings ▸ About said
/// `0.8.9 · up to date`, and pressing **Check now** changed nothing at all. The press was building
/// `/v1/update%3Frefresh=1` (a query appended as a path component), the host answered 404, and the
/// model treated 404 as "this host has no updater" — so it drew nothing, logged nothing, and kept the
/// number it already had. A press that cannot be answered must say so; a version the host reports
/// must be shown, whatever the feed says about it.
@MainActor
final class AppModelHostUpdateTests: XCTestCase {

    private func model(_ label: String) -> AppModel {
        AppModel(client: ScriptedHost(session: "s1"),
                 hostName: "test-update-\(label)-\(UUID().uuidString)")
    }

    /// The deployed host's answer: 0.8.14 running, newest published tag 0.4.0.
    private func liveAnswer(_ current: String = "0.8.14") -> HostUpdateStatus {
        HostUpdateStatus(current: current, latest: "0.4.0", available: false,
                         notesURL: nil, checkedAt: Date(), canSelfUpdate: true,
                         arch: "linux-x86_64")
    }

    private func client(_ answers: HostUpdateStatus...) -> HostUpdateClient {
        let queue = AnswerQueue(answers)
        return HostUpdateClient(endpoint: { (URL(string: "https://host.example")!, "ticket") },
                                session: ScriptedUpdateSession.answering(queue).session)
    }

    // MARK: - The row reads the host's own current

    func testAnAnswerOlderLatestIsStillShownAsTheHostsVersion() async {
        let model = model("shown")
        model.hostUpdateClient = client(liveAnswer())
        await model.checkHostUpdate(refresh: true)
        XCTAssertEqual(model.hostVersion, "0.8.14",
                       "the version the host reported is the version the row shows")
        XCTAssertNil(model.hostUpdate, "0.4.0 is behind 0.8.14, so there is nothing to offer")
        XCTAssertNil(model.hostCheckFailure)
    }

    func testAFailedCheckKeepsTheLastVersionAndSaysSoRatherThanLookingUpToDate() async {
        let model = model("failed")
        model.hostUpdateClient = client(liveAnswer("0.8.14"))
        await model.checkHostUpdate()
        XCTAssertEqual(model.hostVersion, "0.8.14")

        model.hostUpdateClient = clientFailing()
        await model.checkHostUpdate(refresh: true)
        XCTAssertEqual(model.hostVersion, "0.8.14",
                       "a failed check does not erase the build the host last reported")
        XCTAssertNotNil(model.hostCheckFailure,
                        "a press that could not be answered must be able to say why")
        XCTAssertFalse(model.hostCheckFailure?.isEmpty ?? true)
    }

    func testAPressWithNoClientRecordsAReasonAndFinishes() async {
        let model = model("noclient")
        model.hostUpdateClient = nil
        await model.checkHostUpdate(refresh: true)
        XCTAssertEqual(model.hostCheckFailure, "no update client for this window")
        XCTAssertFalse(model.hostCheckRunning,
                       "the press must clear its own flag, or the button stays Checking… forever")
    }

    func testThePressFlagIsClearedEvenWhenTheRequestThrows() async {
        let model = model("throws")
        model.hostUpdateClient = clientFailing()
        await model.checkHostUpdate(refresh: true)
        XCTAssertFalse(model.hostCheckRunning)
        XCTAssertNotNil(model.hostCheckFailure)
    }

    // MARK: - Waiting at the wrong number

    private func clientFailing() -> HostUpdateClient {
        HostUpdateClient(endpoint: { (URL(string: "https://host.example")!, "ticket") },
                         session: ScriptedUpdateSession.failing().session)
    }
}

// MARK: - A session that answers from a queue

/// One answer per request, so a test can model "this check answered, the next one did not".
private final class AnswerQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [HostUpdateStatus?]

    init(_ answers: [HostUpdateStatus]) { self.answers = answers }

    func next() -> HostUpdateStatus? {
        lock.lock(); defer { lock.unlock() }
        guard !answers.isEmpty else { return nil }
        return answers.removeFirst()
    }
}

/// A `URLSession` whose protocol returns a scripted status body, or fails the connection.
private struct ScriptedUpdateSession {
    let session: URLSession

    static func answering(_ queue: AnswerQueue) -> ScriptedUpdateSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateAnswerStub.self]
        UpdateAnswerStub.mode = { _ in
            guard let status = queue.next() else { return (.init(status: 404, body: Data())) }
            return (body(for: status))
        }
        return ScriptedUpdateSession(session: URLSession(configuration: configuration))
    }

    static func failing() -> ScriptedUpdateSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateAnswerStub.self]
        UpdateAnswerStub.mode = { _ in nil }
        return ScriptedUpdateSession(session: URLSession(configuration: configuration))
    }

    /// The host's wire shape, written by hand: this test asserts what the model does with an answer,
    /// not how the client decodes one (that is `HostUpdateClientTests`).
    private static func body(for status: HostUpdateStatus) -> UpdateAnswerStub.Answer {
        var object: [String: Any] = ["current": status.current,
                                     "available": status.available,
                                     "can_self_update": status.canSelfUpdate,
                                     "arch": status.arch]
        object["latest"] = status.latest ?? NSNull()
        let data = try! JSONSerialization.data(withJSONObject: object)
        return UpdateAnswerStub.Answer(status: 200, body: data)
    }
}

private final class UpdateAnswerStub: URLProtocol {
    struct Answer {
        let status: Int
        let body: Data
    }

    private static let lock = NSLock()
    private static var storedMode: (@Sendable (URLRequest) -> Answer?)?

    /// Set per test; `nil` (or a `nil` answer) fails the connection.
    static var mode: (@Sendable (URLRequest) -> Answer?)? {
        get { lock.lock(); defer { lock.unlock() }; return storedMode }
        set { lock.lock(); storedMode = newValue; lock.unlock() }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let answer = Self.mode?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

#endif
