import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import HermesKit

/// `POST /v1/bots/{profile}/ask` — the wire contract the desktop pet is built on.
///
/// The request *is* the contract here: route, method, ticket, and the three body fields. The answer
/// half pins the two things the balloon distinguishes: a reply, and a timeout that is an answer in
/// its own right.
final class BotAskTests: XCTestCase {

    private var issuedTickets = 0

    override func setUp() {
        super.setUp()
        BotAskStub.reset()
        issuedTickets = 0
    }

    override func tearDown() {
        BotAskStub.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func pointer() -> BridgeBotSessionPointer {
        let base = URL(string: "http://127.0.0.1:8765")!
        return BridgeBotSessionPointer(endpoint: { [weak self] in
            guard let self else { throw BotAskError.unreachable }
            self.issuedTickets += 1
            return (baseURL: base, ticket: "ticket-\(self.issuedTickets)")
        }, session: stubbedSession())
    }

    private func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotAskStub.self]
        return URLSession(configuration: configuration)
    }

    private func json(_ object: [String: Any], status: Int = 200) -> BotAskStub.Reply {
        BotAskStub.Reply(status: status,
                         headers: ["Content-Type": "application/json"],
                         body: try! JSONSerialization.data(withJSONObject: object))
    }

    // MARK: - The route

    func testAskPostsTheDocumentedRouteAndBody() async throws {
        BotAskStub.reply = json([
            "profile": "cody",
            "from": "desktop-pet",
            "session_id": "abc123",
            "question": "what are you doing?",
            "reply": "reading the changelog",
            "answered": true,
        ])

        let answer = try await pointer().ask(profile: "cody",
                                             question: "what are you doing?",
                                             from: BotAsk.fromDesktopPet,
                                             timeout: 120)

        let request = try XCTUnwrap(BotAskStub.requests.first, "ask made no request at all")
        XCTAssertEqual(BotAskStub.requests.count, 1, "one question is one request")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/bots/cody/ask")
        XCTAssertEqual(request.ticket, "Bearer ticket-1", "a single-use ticket, minted once")

        let body = try XCTUnwrap(request.jsonBody)
        XCTAssertEqual(body["question"] as? String, "what are you doing?")
        XCTAssertEqual(body["from"] as? String, "desktop-pet",
                       "the host's transcript has to show the question came from the pet")
        XCTAssertEqual(body["timeout"] as? Double, 120.0)

        XCTAssertEqual(answer.reply, "reading the changelog")
        XCTAssertTrue(answer.answered)
        XCTAssertEqual(answer.sessionID, "abc123")
        XCTAssertEqual(answer.profile, "cody")
    }

    func testThePetLabelIsTheDocumentedOne() {
        XCTAssertEqual(BotAsk.fromDesktopPet, "desktop-pet")
        XCTAssertEqual(BotAsk.defaultTimeout, 120)
    }

    func testAProfileWithASlashIsRefusedRatherThanReshapingThePath() {
        XCTAssertThrowsError(try BotAsk.url(base: URL(string: "http://host")!, profile: "../etc"))
        XCTAssertThrowsError(try BotAsk.url(base: URL(string: "http://host")!, profile: "  "))
    }

    // MARK: - The answer

    func testATimeoutIsAnAnswerWithNoReply() async throws {
        // What the host sends when it delivered the question but the bot had not finished.
        BotAskStub.reply = json([
            "profile": "cody",
            "from": "desktop-pet",
            "session_id": "abc123",
            "question": "are you there?",
            "reply": NSNull(),
            "answered": false,
        ])

        let answer = try await pointer().ask(profile: "cody", question: "are you there?",
                                             from: BotAsk.fromDesktopPet, timeout: 120)
        XCTAssertFalse(answer.answered)
        XCTAssertNil(answer.reply)
        XCTAssertEqual(answer.sessionID, "abc123")
    }

    func testABlankReplyIsNotAnAnswer() {
        let decoded = BotAnswer.decode(Data(#"{"reply":"   ","answered":true}"#.utf8),
                                       fallbackProfile: "cody",
                                       fallbackFrom: "desktop-pet",
                                       fallbackQuestion: "hello")
        XCTAssertEqual(decoded?.answered, false)
        XCTAssertNil(decoded?.reply)
    }

    func testTheAnswerFallsBackToWhatWasAskedWhenTheHostEchoesNothing() {
        let decoded = BotAnswer.decode(Data(#"{"reply":"hi"}"#.utf8),
                                       fallbackProfile: "cody",
                                       fallbackFrom: "desktop-pet",
                                       fallbackQuestion: "hello")
        XCTAssertEqual(decoded?.profile, "cody")
        XCTAssertEqual(decoded?.from, "desktop-pet")
        XCTAssertEqual(decoded?.question, "hello")
        XCTAssertEqual(decoded?.answered, true)
    }

    // MARK: - Refusals

    func testARefusalCarriesTheHostsOwnSentenceUnchanged() async throws {
        BotAskStub.reply = json(["detail": "this bot has no conversation yet"], status: 409)

        do {
            _ = try await pointer().ask(profile: "cody", question: "hello",
                                        from: BotAsk.fromDesktopPet, timeout: 120)
            XCTFail("a 409 must throw")
        } catch let error as BotAskError {
            XCTAssertEqual(error, .host("this bot has no conversation yet"))
            XCTAssertEqual(error.localizedDescription, "this bot has no conversation yet",
                           "the balloon shows the host's sentence, not a decorated version of it")
        }
    }

    func testARefusalWithoutADetailStillNamesTheStatus() async throws {
        BotAskStub.reply = json([:], status: 404)

        do {
            _ = try await pointer().ask(profile: "cody", question: "hello",
                                        from: BotAsk.fromDesktopPet, timeout: 120)
            XCTFail("a 404 must throw")
        } catch let error as BotAskError {
            XCTAssertTrue(error.localizedDescription.contains("404"),
                          error.localizedDescription)
        }
    }

    func testAnUnreadableAnswerIsAFailureNotAnEmptyBubble() async throws {
        BotAskStub.reply = BotAskStub.Reply(status: 200, headers: [:], body: Data("<html>".utf8))

        do {
            _ = try await pointer().ask(profile: "cody", question: "hello",
                                        from: BotAsk.fromDesktopPet, timeout: 120)
            XCTFail("an unreadable body must throw")
        } catch let error as BotAskError {
            XCTAssertEqual(error, .host("the host's answer was not readable"))
        }
    }

    func testTheUnreachableSentenceIsTheDesignsWords() {
        XCTAssertEqual(BotAskError.unreachable.localizedDescription,
                       "Can't reach the host right now.")
    }
}

// MARK: - Stub transport

/// Answers one canned reply and records what the client sent. The same shape as `RoomAdminStub`:
/// the request is the contract, so the request is what the test reads.
final class BotAskStub: URLProtocol {

    struct Reply {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    struct Recorded {
        let method: String
        let path: String
        let ticket: String?
        let body: Data?

        var jsonBody: [String: Any]? {
            guard let body else { return nil }
            return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }
    }

    private static let lock = NSLock()
    private static var storedReply = Reply(status: 200, headers: [:], body: Data("{}".utf8))
    private static var recorded: [Recorded] = []

    static var reply: Reply {
        get { lock.lock(); defer { lock.unlock() }; return storedReply }
        set { lock.lock(); storedReply = newValue; lock.unlock() }
    }

    static var requests: [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func reset() {
        lock.lock()
        storedReply = Reply(status: 200, headers: [:], body: Data("{}".utf8))
        recorded = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.flatMap(Self.drain)
        let header = request.value(forHTTPHeaderField: "Authorization")

        Self.lock.lock()
        Self.recorded.append(Recorded(method: request.httpMethod ?? "",
                                      path: request.url?.path ?? "",
                                      ticket: header,
                                      body: body))
        let reply = Self.storedReply
        Self.lock.unlock()

        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}
