import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HermesKit

/// The host update client's wire contract, and the one URL bug that made Settings ▸ About's
/// **Check now** a no-op.
///
/// The press asks for a fresh answer with `?refresh=1`. That is a *query*, and the first version of
/// this client appended `"v1/update?refresh=1"` as a **path component**, which percent-encodes the
/// question mark: `GET /v1/update%3Frefresh=1`. The host answered 404, the caller treated 404 as
/// "this host has no updater" and stayed silent, and the row kept showing the version it already
/// had — so a button labelled Check now did nothing visible, on every press. The host's audit log
/// had no `/v1/update` entry for those presses at all: an unparseable path is logged as `invalid`.
///
/// These tests fail if that shape comes back.
final class HostUpdateClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HostUpdateStub.reset()
    }

    override func tearDown() {
        HostUpdateStub.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func client(base: String = "https://hermes.example.ts.net") -> HostUpdateClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HostUpdateStub.self]
        return HostUpdateClient(endpoint: { (URL(string: base)!, "device-ticket") },
                                session: URLSession(configuration: configuration))
    }

    private func json(_ object: [String: Any], status: Int = 200) {
        HostUpdateStub.reply = .init(status: status,
                                     headers: ["Content-Type": "application/json"],
                                     body: try! JSONSerialization.data(withJSONObject: object))
    }

    /// The answer the deployed host actually gives (0.8.14 running, newest published tag 0.4.0).
    private var liveHostBody: [String: Any] {
        ["current": "0.8.14", "latest": "0.4.0", "available": false,
         "can_self_update": true, "arch": "linux-x86_64", "checked_at": 1_795_705_672.5,
         "notes_url": "https://github.com/macblizzard/hermey/releases/tag/hermeyd-v0.4.0",
         "error": NSNull(), "progress": NSNull(), "last_update": NSNull()]
    }

    // MARK: - The URL

    func testTheQuietCheckAsksTheRouteWithNoQuery() {
        let url = HostUpdateClient.statusURL(base: URL(string: "https://host.example")!, refresh: false)
        XCTAssertEqual(url.absoluteString, "https://host.example/v1/update")
        XCTAssertEqual(url.path, "/v1/update")
        XCTAssertNil(url.query)
    }

    func testThePressSendsRefreshAsAQueryAndNeverAsAnEscapedPath() {
        let url = HostUpdateClient.statusURL(base: URL(string: "https://host.example")!, refresh: true)
        XCTAssertEqual(url.absoluteString, "https://host.example/v1/update?refresh=1")
        XCTAssertEqual(url.path, "/v1/update",
                       "the path is the route; the refresh flag must not be part of it")
        XCTAssertEqual(url.query, "refresh=1")
        XCTAssertFalse(url.absoluteString.contains("%3F"),
                       "an escaped question mark is a 404 on the host, not a refresh")
    }

    func testTheBaseUrlsTrailingSlashDoesNotDoubleTheSlash() {
        let url = HostUpdateClient.statusURL(base: URL(string: "https://host.example/")!, refresh: true)
        XCTAssertEqual(url.absoluteString, "https://host.example/v1/update?refresh=1")
    }

    func testTheRequestThatActuallyLeavesCarriesTheQueryAndTheBearer() async throws {
        json(liveHostBody)
        _ = try await client().status(refresh: true)
        let request = try XCTUnwrap(HostUpdateStub.requests.first)
        XCTAssertEqual(request.url?.absoluteString,
                       "https://hermes.example.ts.net/v1/update?refresh=1",
                       "this is the string the host has to route")
        XCTAssertEqual(request.url?.query, "refresh=1")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer device-ticket")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testTheQuietRequestCarriesNoQuery() async throws {
        json(liveHostBody)
        _ = try await client().status()
        let request = try XCTUnwrap(HostUpdateStub.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://hermes.example.ts.net/v1/update")
        XCTAssertNil(request.url?.query)
    }

    // MARK: - The answer

    func testTheHostsOwnCurrentIsWhatComesBack() async throws {
        json(liveHostBody)
        let status = try await client().status(refresh: true)
        XCTAssertEqual(status.current, "0.8.14")
        XCTAssertEqual(status.latest, "0.4.0")
        XCTAssertFalse(status.available)
        XCTAssertTrue(status.canSelfUpdate)
        XCTAssertEqual(status.arch, "linux-x86_64")
        XCTAssertEqual(status.notesURL?.lastPathComponent, "hermeyd-v0.4.0")
    }

    func testAFeedBehindTheRunningBuildIsNotAnUpdate() async throws {
        // The deployed state: `available: false` and a `latest` that is *older* than `current`.
        json(liveHostBody)
        let status = try await client().status()
        XCTAssertFalse(status.hasNewerRelease,
                       "0.4.0 is not newer than 0.8.14; the row must read as up to date")
    }

    func testAFeedAheadOfTheRunningBuildIsAnUpdate() {
        let status = HostUpdateStatus(current: "0.8.14", latest: "0.9.0", available: true,
                                      canSelfUpdate: true)
        XCTAssertTrue(status.hasNewerRelease)
    }

    func testVersionOrdering() {
        XCTAssertTrue(HostVersion.isNewer("0.8.14", than: "0.8.9"),
                      "14 is greater than 9, not a string comparison")
        XCTAssertTrue(HostVersion.isNewer("0.9.0", than: "0.8.14"))
        XCTAssertTrue(HostVersion.isNewer("1.0", than: "0.99.99"))
        XCTAssertFalse(HostVersion.isNewer("0.4.0", than: "0.8.14"))
        XCTAssertFalse(HostVersion.isNewer("0.8.14", than: "0.8.14"))
        XCTAssertFalse(HostVersion.isNewer("0.8", than: "0.8.0"),
                       "a missing segment is zero; the same build is not newer than itself")
    }

    func testAnAnswerWithoutTheRouteIsReportedAs404() async throws {
        json(["detail": "not found"], status: 404)
        do {
            _ = try await client().status(refresh: true)
            XCTFail("a 404 must surface, or the caller cannot tell the press failed")
        } catch let error as HostUpdateError {
            guard case .rejected(let status, _) = error else {
                return XCTFail("expected .rejected, got \(error)")
            }
            XCTAssertEqual(status, 404)
        }
    }

    func testAnUnreadableBodyIsMalformedRatherThanAnEmptyVersion() async throws {
        HostUpdateStub.reply = .init(status: 200, headers: [:], body: Data("nope".utf8))
        do {
            _ = try await client().status()
            XCTFail("an unreadable answer must not be read as a version")
        } catch let error as HostUpdateError {
            XCTAssertEqual(error, .malformedResponse)
        }
    }
}

// MARK: - Stub transport

/// Records every request the client sends and answers from a script, so the test asserts the URL
/// that actually left rather than the one the test hoped for.
final class HostUpdateStub: URLProtocol {
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
}
