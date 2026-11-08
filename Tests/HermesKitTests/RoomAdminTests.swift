import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import HermesKit

/// The bridge's room *admin* routes — rename and disband.
///
/// These two are the ones a protocol-extension default can silently swallow: `Rooms.swift`
/// declares defaults (`func renameRoom(…) async throws {}`) for stores that have no admin routes,
/// and a concrete store that forgets to implement one inherits a no-op. The app then "succeeds",
/// refreshes from the host, and shows the old name — a bug with no error in it anywhere. So the
/// assertion here is the request itself: method, path, body, one fresh ticket.
final class RoomAdminTests: XCTestCase {

    private var issuedTickets = 0

    override func setUp() {
        super.setUp()
        RoomAdminStub.reset()
        issuedTickets = 0
    }

    override func tearDown() {
        RoomAdminStub.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func pointer(session: URLSession) -> BridgeBotSessionPointer {
        let base = URL(string: "https://host.example")!
        return BridgeBotSessionPointer(endpoint: { [weak self] in
            guard let self else { throw BridgeBotSessionPointer.Failure.noProfile }
            self.issuedTickets += 1
            return (baseURL: base, ticket: "ticket-\(self.issuedTickets)")
        }, session: session)
    }

    private func stubbed(reply: RoomAdminStub.Reply) -> BridgeBotSessionPointer {
        RoomAdminStub.reply = reply
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoomAdminStub.self]
        return pointer(session: URLSession(configuration: configuration))
    }

    private func json(_ object: [String: Any], status: Int = 200) -> RoomAdminStub.Reply {
        RoomAdminStub.Reply(status: status,
                            headers: ["Content-Type": "application/json"],
                            body: try! JSONSerialization.data(withJSONObject: object))
    }

    // MARK: - Rename

    func testRenamePostsTheNameToTheRoomRoute() async throws {
        // The bridge answers the route it documents: `{"room_id": …, "name": …}`.
        let pointer = stubbed(reply: json(["room_id": "room-1", "name": "Renamed by the app"]))

        try await pointer.renameRoom("room-1", name: "Renamed by the app")

        let request = try XCTUnwrap(RoomAdminStub.requests.first, "rename made no request at all")
        XCTAssertEqual(RoomAdminStub.requests.count, 1, "one rename is one request")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/rooms/room-1/rename")
        XCTAssertEqual(request.authorization, "Bearer ticket-1", "a single-use ticket, minted once")
        let body = try XCTUnwrap(request.jsonBody)
        XCTAssertEqual(body["name"] as? String, "Renamed by the app")
    }

    func testRenameSurfacesARefusalInsteadOfPretendingItWorked() async throws {
        // A name the host rejects must reach the user as an error, not as a silent no-op: the
        // inline rename bar in the room shows `error.localizedDescription`.
        let pointer = stubbed(reply: json(["detail": "name is too long"], status: 422))

        do {
            try await pointer.renameRoom("room-1", name: String(repeating: "x", count: 200))
            XCTFail("a 422 must throw")
        } catch {
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("422"), "the status belongs in the message: \(text)")
            XCTAssertTrue(text.contains("name is too long"), "the host's reason belongs in it: \(text)")
        }
    }

    // MARK: - Disband

    func testDisbandPostsToTheDisbandRoute() async throws {
        let pointer = stubbed(reply: json(["room_id": "room-2", "disbanded": true]))

        try await pointer.disbandRoom("room-2")

        let request = try XCTUnwrap(RoomAdminStub.requests.first, "disband made no request at all")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/rooms/room-2/disband")
        XCTAssertEqual(request.authorization, "Bearer ticket-1")
    }

    func testDisbandSurfacesARefusal() async throws {
        let pointer = stubbed(reply: json(["detail": "hosted room not found"], status: 502))

        do {
            try await pointer.disbandRoom("room-2")
            XCTFail("a 502 must throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("hosted room not found"),
                          error.localizedDescription)
        }
    }
}

// MARK: - Stub transport

/// Answers one canned reply and records what the client sent. Mirrors `StubURLProtocol` in
/// `HermesVoiceTests`: same reason — the request *is* the contract here.
final class RoomAdminStub: URLProtocol {

    struct Reply {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    struct Recorded {
        let method: String
        let path: String
        let authorization: String?
        let body: Data?

        var jsonBody: [String: Any]? {
            guard let body else { return nil }
            return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
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
        let body = request.httpBody ?? request.httpBodyStream.flatMap(Self.drain)
        Self.lock.lock()
        Self.requests.append(Recorded(method: request.httpMethod ?? "",
                                      path: request.url?.path ?? "",
                                      authorization: request.value(forHTTPHeaderField: "Authorization"),
                                      body: body))
        let reply = Self.reply
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
