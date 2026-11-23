import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import HermesKit

/// The card read's one request: `GET /v1/cards/{id}?session=…&message=…`.
///
/// The message id is the point of this file. The host snapshots a card per
/// `(session, message, card)`, and an omitted `message` collapses every transcript row onto the
/// same snapshot — the collision the route was written to avoid. A grep can see that the parameter
/// is in the source; only a request can see that it is in the URL, so this pins the URL itself.
final class CardRouteTests: XCTestCase {

    private let session = "20261122_120000_abcdef"

    override func setUp() {
        super.setUp()
        CardRouteStub.reset()
    }

    override func tearDown() {
        CardRouteStub.reset()
        super.tearDown()
    }

    private func pointer() -> BridgeBotSessionPointer {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CardRouteStub.self]
        // A literal that cannot fail; the assertions below would say so loudly if it did. Held in a
        // local so the `@Sendable` endpoint closure captures a URL, not this test case.
        let baseURL = URL(string: "https://host.example") ?? URL(fileURLWithPath: "/")
        return BridgeBotSessionPointer(endpoint: { (baseURL: baseURL, ticket: "ticket-1") },
                                       session: URLSession(configuration: configuration))
    }

    private func cardReply(_ object: [String: Any]) -> CardRouteStub.Reply {
        CardRouteStub.Reply(status: 200,
                            headers: ["Content-Type": "application/json"],
                            body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    private func document(title: String = "Book the cabin") -> [String: Any] {
        [
            "schema": "card.v1",
            "kind": "approval",
            "title": title,
            "status": ["state": "awaiting-approval"],
            "actions": [["label": "Approve", "send": "APPROVE c-9b", "style": "primary"]],
        ]
    }

    func testTheCardRequestCarriesTheSessionAndTheMessage() async throws {
        CardRouteStub.reply = cardReply(["card": document(), "mtime": "2026-11-22T21:04:06.120Z", "final": false])

        _ = try await pointer().card(id: "c-9b", session: session, message: "row:42")

        let request = try XCTUnwrap(CardRouteStub.requests.first, "the card read made no request")
        XCTAssertEqual(CardRouteStub.requests.count, 1, "one card is one request")
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/v1/cards/c-9b")
        XCTAssertEqual(request.query["session"], session)
        XCTAssertEqual(request.query["message"], "row:42",
                       "without the message id every row shares one snapshot")
        XCTAssertEqual(request.authorization, "Bearer ticket-1", "a single-use ticket, minted once")
        XCTAssertTrue(request.queryString.hasPrefix("session="),
                      "session first, then message: \(request.queryString)")
    }

    /// Two messages naming one file are two different reads, with two different URLs.
    func testTwoMessagesAskForTheirOwnSnapshots() async throws {
        CardRouteStub.reply = cardReply(["card": document(), "mtime": "", "final": false])

        _ = try await pointer().card(id: "c-9b", session: session, message: "row:42")
        _ = try await pointer().card(id: "c-9b", session: session, message: "row:43")

        XCTAssertEqual(CardRouteStub.requests.map { $0.query["message"] }, ["row:42", "row:43"])
    }

    func testTheAnswerKeepsItsMtimeAndItsFinalFlag() async throws {
        CardRouteStub.reply = cardReply(["card": document(title: "From the snapshot"),
                                         "mtime": "2026-11-22T21:04:06.120Z",
                                         "final": true])

        let fetch = try await pointer().card(id: "c-9b", session: session, message: "row:42")

        XCTAssertEqual(fetch.mtime, "2026-11-22T21:04:06.120Z")
        XCTAssertTrue(fetch.final)
        // The document is handed on exactly as the host wrote it: `HermesKit` does not decode a
        // card, it only carries it to whoever can draw one.
        let object = try? JSONSerialization.jsonObject(with: fetch.card) as? [String: Any]
        XCTAssertEqual(object?["title"] as? String, "From the snapshot")
    }

    func testARefusalKeepsItsOwnCode() async throws {
        CardRouteStub.reply = CardRouteStub.Reply(status: 404,
                                                  headers: ["Content-Type": "application/json"],
                                                  body: Data(#"{"error":"no_such_card","detail":"gone"}"#.utf8))

        do {
            _ = try await pointer().card(id: "c-9b", session: session, message: "row:42")
            XCTFail("a 404 must throw")
        } catch {
            XCTAssertEqual(error as? CardFetchError, .noSuchCard,
                           "the transcript draws one line for every refusal, but they are not one fact")
        }
    }

    func testAnIDThatCouldBeAPathIsRefusedBeforeARequestExists() async throws {
        do {
            _ = try await pointer().card(id: "../c-9b", session: session, message: "row:42")
            XCTFail("an id with a path in it must throw")
        } catch {
            XCTAssertEqual(error as? CardFetchError, .badId)
        }
        XCTAssertTrue(CardRouteStub.requests.isEmpty, "no request is built for a refused id")
    }

    func testAnEmptyMessageStillAsksForTheEmptyKey() async throws {
        // The route reads a missing `message` as `""`; sending it explicitly is the same row, and
        // is what keeps the client honest about which message it is drawing.
        CardRouteStub.reply = cardReply(["card": document(), "mtime": "", "final": false])

        _ = try await pointer().card(id: "c-9b", session: session, message: "")

        let request = try XCTUnwrap(CardRouteStub.requests.first)
        XCTAssertEqual(request.query["message"], "")
        XCTAssertTrue(request.queryString.contains("message="), request.queryString)
    }
}

/// One recorded card request, and one canned answer. The same shape as `RoomAdminStub`.
final class CardRouteStub: URLProtocol {

    struct Reply {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    struct Recorded {
        let method: String
        let path: String
        let queryString: String
        let authorization: String?

        /// The query as a dictionary, so an assertion is about a value rather than its encoding.
        var query: [String: String] {
            guard let items = URLComponents(string: "https://host.example" + path + "?" + queryString)?.queryItems
            else { return [:] }
            var values: [String: String] = [:]
            for item in items {
                values[item.name] = item.value ?? ""
            }
            return values
        }
    }

    static var reply = Reply(status: 200, headers: [:], body: Data())
    private(set) static var requests: [Recorded] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        requests = []
        reply = Reply(status: 200, headers: [:], body: Data())
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(Recorded(method: request.httpMethod ?? "",
                                      path: request.url?.path ?? "",
                                      queryString: request.url?.query ?? "",
                                      authorization: request.value(forHTTPHeaderField: "Authorization")))
        let reply = Self.reply
        Self.lock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(url: url,
                                             statusCode: reply.status,
                                             httpVersion: "HTTP/1.1",
                                             headerFields: reply.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
