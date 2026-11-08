import Foundation
import XCTest
@testable import HermesVoiceCore

/// The bridge voice client's wire contract, with no network and no paid provider.
///
/// `VoiceService` takes its ticket closure and its `URLSession`, so a stub protocol can
/// answer every request and record what the app actually sent: the Authorization header
/// (a different ticket every time), the JSON body, and the endpoint.
final class VoiceServiceTests: XCTestCase {

    private var issuedTickets = 0

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        issuedTickets = 0
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeService() -> VoiceService {
        let base = URL(string: "https://host.example")!
        return VoiceService(baseURL: base, freshTicket: { [weak self] in
            guard let self else { throw VoiceTransportError.unavailable }
            self.issuedTickets += 1
            return "ticket-\(self.issuedTickets)"
        })
    }

    private func stubbedService(reply: StubURLProtocol.Reply) -> VoiceService {
        StubURLProtocol.reply = reply
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        var service = makeService()
        service.session = URLSession(configuration: configuration)
        return service
    }

    private func json(_ object: [String: Any], status: Int = 200) -> StubURLProtocol.Reply {
        StubURLProtocol.Reply(status: status,
                              headers: ["Content-Type": "application/json"],
                              body: try! JSONSerialization.data(withJSONObject: object))
    }

    private func bodyJSON(_ request: URLRequest) throws -> [String: Any] {
        let data = StubURLProtocol.bodyData(of: request)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    // MARK: - Transcription

    func testTranscribeSendsBytesAndMimeAndReturnsTheTranscript() async throws {
        let audio = Data([0x00, 0x01, 0x02, 0x03, 0xFF])
        let service = stubbedService(reply: json(["transcript": "  hello from the phone  "]))

        let transcript = try await service.transcribe(audio: audio, mimeType: "audio/mp4")

        XCTAssertEqual(transcript, "hello from the phone")
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/voice/transcribe")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ticket-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try bodyJSON(request)
        XCTAssertEqual(body["mime_type"] as? String, "audio/mp4")
        XCTAssertEqual(body["content_base64"] as? String, audio.base64EncodedString())
        XCTAssertNil(body["url"])
    }

    func testEveryRequestUsesItsOwnTicket() async throws {
        StubURLProtocol.reply = json(["transcript": "one"])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        var service = makeService()
        service.session = URLSession(configuration: configuration)

        _ = try await service.transcribe(audio: Data([1]), mimeType: "audio/mpeg")
        _ = try await service.transcribe(audio: Data([2]), mimeType: "audio/mpeg")

        let headers = StubURLProtocol.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
        XCTAssertEqual(headers, ["Bearer ticket-1", "Bearer ticket-2"])
    }

    func testEmptyTranscriptIsAnError() async {
        let service = stubbedService(reply: json(["transcript": "   "]))
        do {
            _ = try await service.transcribe(audio: Data([1]), mimeType: "audio/mpeg")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? VoiceTransportError, .emptyTranscript)
        }
    }

    // MARK: - Synthesis

    func testSynthesizeDecodesMp3FromBase64() async throws {
        let audio = Data("ID3fake-mp3".utf8)
        let service = stubbedService(reply: json([
            "mime_type": "audio/mpeg",
            "content_base64": audio.base64EncodedString(),
        ]))

        let spoken = try await service.synthesize(text: "  Hello there.  ")

        XCTAssertEqual(spoken, audio)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/voice/synthesize")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ticket-1")
        let body = try bodyJSON(request)
        XCTAssertEqual(body["text"] as? String, "Hello there.")
    }

    func testSynthesizeRefusesANonAudioReply() async {
        let service = stubbedService(reply: json([
            "mime_type": "audio/wav",
            "content_base64": Data([1, 2, 3]).base64EncodedString(),
        ]))
        do {
            _ = try await service.synthesize(text: "hello")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? VoiceTransportError, .unsupportedAudio)
        }
    }

    func testSynthesizeRefusesAnEmptyAudioReply() async {
        let service = stubbedService(reply: json(["mime_type": "audio/mpeg", "content_base64": ""]))
        do {
            _ = try await service.synthesize(text: "hello")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? VoiceTransportError, .emptyAudio)
        }
    }

    // MARK: - Failure mapping

    func testHTTPFailuresMapToTypedErrors() async {
        await assertThrows(.unauthorized, status: 401, body: [:])
        await assertThrows(.tooLarge, status: 413, body: ["detail": "audio is too large"])
        await assertThrows(.unsupportedAudio, status: 415, body: [:])
        await assertThrows(.providerUnavailable("Voice provider failed."),
                           status: 502, body: ["detail": "Voice provider failed."])
    }

    func testUnreadableSuccessBodyIsMalformed() async {
        StubURLProtocol.reply = StubURLProtocol.Reply(status: 200,
                                                      headers: ["Content-Type": "text/html"],
                                                      body: Data("<html>no</html>".utf8))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        var service = makeService()
        service.session = URLSession(configuration: configuration)
        do {
            _ = try await service.transcribe(audio: Data([1]), mimeType: "audio/mpeg")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? VoiceTransportError, .malformedResponse)
        }
    }

    // MARK: - Local limits (the host enforces them too; the app fails fast)

    func testOversizedAudioAndTextAreRefusedBeforeAnyRequest() async {
        let service = stubbedService(reply: json(["transcript": "never sent"]))

        do {
            _ = try await service.transcribe(audio: Data(count: VoiceService.maxAudioBytes + 1),
                                             mimeType: "audio/mpeg")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? VoiceTransportError, .tooLarge)
        }

        do {
            _ = try await service.synthesize(text: String(repeating: "a",
                                                          count: VoiceService.maxTextCharacters + 1))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? VoiceTransportError, .textTooLong)
        }

        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testUnsupportedAudioTypeIsRefusedBeforeAnyRequest() async {
        let service = stubbedService(reply: json(["transcript": "never sent"]))
        do {
            _ = try await service.transcribe(audio: Data([1]), mimeType: "audio/flac")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? VoiceTransportError, .unsupportedAudio)
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testBlankSynthesisTextIsRefused() async {
        let service = stubbedService(reply: json(["mime_type": "audio/mpeg", "content_base64": "AA=="]))
        do {
            _ = try await service.synthesize(text: "   \n ")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? VoiceTransportError, .emptyText)
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    // MARK: - Await helper

    private func assertThrows(_ expected: VoiceTransportError,
                              status: Int,
                              body: [String: Any],
                              file: StaticString = #filePath,
                              line: UInt = #line) async {
        let service = stubbedService(reply: json(body, status: status))
        do {
            _ = try await service.transcribe(audio: Data([1]), mimeType: "audio/mpeg")
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? VoiceTransportError, expected, file: file, line: line)
        }
    }
}

// MARK: - Stub transport

/// Answers every request in-process. `URLSession` hands this protocol the body as a
/// stream, not `httpBody`, which is why `bodyData(of:)` exists.
final class StubURLProtocol: URLProtocol {
    struct Reply {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    static var reply: Reply?
    static var requests: [URLRequest] = []

    static func reset() {
        reply = nil
        requests = []
    }

    static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StubURLProtocol.requests.append(request)
        guard let reply = StubURLProtocol.reply, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: url,
                                       statusCode: reply.status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
