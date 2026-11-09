import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HermesKit

/// The Bot Computer client's wire contract: the bridge's snake_case shapes, one ticket per request,
/// and the scheme upgrade the viewer dials. No network, no host.
final class BotComputerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        BotComputerStub.reset()
    }

    override func tearDown() {
        BotComputerStub.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func client(tickets: TicketCounter = TicketCounter(), base: String = "https://host.example")
        -> BotComputerClient {
        // The endpoint closure is `@Sendable`, so the counter is a reference type with a lock
        // rather than a captured `var` (which does not compile in a concurrently-executing closure).
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotComputerStub.self]
        return BotComputerClient(endpoint: {
            (URL(string: base)!, tickets.next())
        }, session: URLSession(configuration: configuration))
    }

    private func json(_ object: [String: Any], status: Int = 200) {
        BotComputerStub.reply = .init(status: status,
                                      headers: ["Content-Type": "application/json"],
                                      body: try! JSONSerialization.data(withJSONObject: object))
    }

    // MARK: - Decoding

    func testStatusDecodesTheBridgesSnakeCaseShape() async throws {
        json(["profile": "cody", "running": true, "installed": true, "display": ":20",
              "geometry": "1440x900",
              "lease": ["holder": "human", "epoch": 3, "since": 1_794_258_638.9,
                        "viewer_hash": "46539bf7dc77"]])
        let status = try await client().status(profile: "cody")
        XCTAssertTrue(status.running)
        XCTAssertEqual(status.display, ":20")
        XCTAssertEqual(status.lease?.holder, "human")
        XCTAssertTrue(status.lease?.isHuman == true)
        XCTAssertEqual(status.lease?.epoch, 3)
        XCTAssertEqual(status.headline, "you are in control")
    }

    func testAStoppedScreenWithABlockerReadsAsTheBlockersSentence() async throws {
        json(["running": false, "installed": true,
              "blocker": "needs 1536 MB free, 400 MB available"])
        let status = try await client().status(profile: "fino")
        XCTAssertFalse(status.running)
        XCTAssertEqual(status.headline, "needs 1536 MB free, 400 MB available")
    }

    func testTicketKeepsTheViewerIdentityAndExpiry() async throws {
        json(["ticket": "bridge-ticket", "path": "/v1/display/ws", "viewer_id": "viewer-7",
              "expires_in": 60, "status": ["running": true, "installed": true]])
        let ticket = try await client().observe(profile: "cody")
        XCTAssertEqual(ticket.ticket, "bridge-ticket")
        XCTAssertEqual(ticket.viewerID, "viewer-7")
        XCTAssertEqual(ticket.path, "/v1/display/ws")
        XCTAssertEqual(ticket.expiresIn, 60)
        XCTAssertEqual(ticket.status?.running, true)
    }

    func testALeaseAnswerWithoutAViewerIdIsStillReadable() async throws {
        // The bridge never returns the viewer id to other clients; a release answer is exactly this.
        json(["lease": ["holder": "agent", "epoch": 4, "since": 1.0, "viewer_hash": NSNull()]])
        let lease = try await client().lease(profile: "cody", acquire: false, viewerID: "viewer-7")
        XCTAssertEqual(lease?.holder, "agent")
        XCTAssertFalse(lease?.isHuman == true)
    }

    // MARK: - The socket

    func testSocketURLUpgradesTheSchemeAndCarriesTheTicketOnce() {
        let client = client()
        let secure = client.socketURL(baseURL: URL(string: "https://host.example:8443")!,
                                      path: "/v1/display/ws", ticket: "abc-123")
        XCTAssertEqual(secure?.absoluteString,
                       "wss://host.example:8443/v1/display/ws?display_ticket=abc-123")
        let plain = client.socketURL(baseURL: URL(string: "http://127.0.0.1:8787")!,
                                     path: "/v1/display/ws", ticket: "abc")
        XCTAssertEqual(plain?.absoluteString, "ws://127.0.0.1:8787/v1/display/ws?display_ticket=abc")
    }

    func testStreamURLReportsTheSameBaseURLItObservedAgainst() async throws {
        json(["ticket": "t", "path": "/v1/display/ws", "viewer_id": "v", "expires_in": 60])
        let stream = try await client(base: "https://casa.example:8443").streamURL(profile: "atlas")
        XCTAssertEqual(stream.url.absoluteString,
                       "wss://casa.example:8443/v1/display/ws?display_ticket=t")
        XCTAssertEqual(stream.ticket.viewerID, "v")
    }

    // MARK: - Tickets and errors

    func testEveryRequestSpendsItsOwnTicket() async throws {
        json(["running": false, "installed": true])
        let tickets = TicketCounter()
        let client = client(tickets: tickets)

        _ = try await client.status(profile: "cody")
        _ = try await client.status(profile: "cody")
        XCTAssertEqual(tickets.value, 2)
        XCTAssertEqual(BotComputerStub.requests.map { $0.value(forHTTPHeaderField: "Authorization") ?? "" },
                       ["Bearer ticket-1", "Bearer ticket-2"])
    }

    func testAGatewayRefusalSurfacesItsOwnSentence() async throws {
        json(["detail": "this profile's Bot Desktop is not running; call display.start first"],
             status: 502)
        do {
            _ = try await client().observe(profile: "cody")
            XCTFail("a 502 must not look like a success")
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(text.contains("display.start first"), text)
            XCTAssertTrue(text.contains("502"), text)
        }
    }

    func testAnUnreadableBodyIsMalformedRatherThanSilent() async throws {
        BotComputerStub.reply = .init(status: 200, headers: ["Content-Type": "application/json"],
                                      body: Data("not json".utf8))
        do {
            _ = try await client().status(profile: "cody")
            XCTFail("an unreadable body must be reported")
        } catch let error as BotComputerError {
            XCTAssertEqual(error, .malformedResponse)
        }
    }
}

/// A ticket source a `@Sendable` closure can call: a value `var` cannot be mutated there.
final class TicketCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }; return count
    }

    func next() -> String {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return "ticket-\(count)"
    }
}

// MARK: - Stub transport

final class BotComputerStub: URLProtocol {
    struct Reply {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private static let lock = NSLock()
    private static var storedReply = Reply(status: 200, headers: [:], body: Data("{}".utf8))
    private static var recorded: [URLRequest] = []

    static var reply: Reply {
        get { lock.lock(); defer { lock.unlock() }; return storedReply }
        set { lock.lock(); storedReply = newValue; lock.unlock() }
    }

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
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
        var request = request
        if let body = request.httpBodyStream.map(Self.drain) {
            // A body sent as a stream is invisible to a URLProtocol; keep it readable for assertions.
            request.httpBody = body
        }
        Self.lock.lock()
        Self.recorded.append(request)
        let reply = Self.storedReply
        Self.lock.unlock()

        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
