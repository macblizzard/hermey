import Foundation

/// `POST /v1/voice/transcribe` and `POST /v1/voice/synthesize` on the paired bridge.
///
/// One request, one freshly minted single-use `ws_ticket` in `Authorization: Bearer`.
/// Nothing is cached: a ticket that went to a websocket, or to the previous voice
/// request, is already spent. Audio and text travel in the body only — there is no
/// URL field, so the phone cannot point the host at another server.
///
/// The limits below mirror the bridge's: the app refuses locally what the host would
/// reject anyway, with a message the user can act on instead of an HTTP code.
struct VoiceService {
    static let maxAudioBytes = 10 * 1024 * 1024
    static let maxTextCharacters = 4_000
    static let acceptedAudioMimeTypes: Set<String> = [
        "audio/mpeg", "audio/mp4", "audio/x-m4a", "audio/wav", "audio/x-wav", "audio/ogg",
    ]

    let baseURL: URL
    let freshTicket: () async throws -> String
    var session: URLSession = .shared

    // MARK: - Endpoints

    func transcribe(audio: Data, mimeType: String) async throws -> String {
        guard Self.acceptedAudioMimeTypes.contains(mimeType) else {
            throw VoiceTransportError.unsupportedAudio
        }
        guard !audio.isEmpty else { throw VoiceTransportError.emptyAudio }
        guard audio.count <= Self.maxAudioBytes else { throw VoiceTransportError.tooLarge }

        let body = TranscribeBody(mimeType: mimeType,
                                  contentBase64: audio.base64EncodedString())
        let reply: TranscribeReply = try await post("v1/voice/transcribe", body: body)
        let text = reply.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VoiceTransportError.emptyTranscript }
        return text
    }

    func synthesize(text: String) async throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VoiceTransportError.emptyText }
        guard trimmed.count <= Self.maxTextCharacters else { throw VoiceTransportError.textTooLong }

        let reply: SynthesizeReply = try await post("v1/voice/synthesize",
                                                    body: SynthesizeBody(text: trimmed))
        guard reply.mimeType == "audio/mpeg" else { throw VoiceTransportError.unsupportedAudio }
        guard let audio = Data(base64Encoded: reply.contentBase64), !audio.isEmpty else {
            throw VoiceTransportError.emptyAudio
        }
        return audio
    }

    // MARK: - Plumbing

    private func post<Body: Encodable, Reply: Decodable>(_ path: String, body: Body) async throws -> Reply {
        // Minted inside this call: a ticket is spent by exactly one request, so it can
        // never be shared with a socket or with the previous voice request.
        let ticket = try await freshTicket()
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(ticket)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VoiceTransportError.malformedResponse
        }
        // URLSession follows redirects on its own; a redirected answer means the reply
        // did not come from the host this app is paired with. Refuse it.
        guard Self.sameEndpoint(http.url, request.url) else {
            throw VoiceTransportError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.failure(status: http.statusCode, data: data)
        }
        do {
            return try JSONDecoder().decode(Reply.self, from: data)
        } catch {
            throw VoiceTransportError.malformedResponse
        }
    }

    private static func sameEndpoint(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs,
              let left = URLComponents(url: lhs, resolvingAgainstBaseURL: false),
              let right = URLComponents(url: rhs, resolvingAgainstBaseURL: false) else {
            return false
        }
        return left.scheme?.lowercased() == right.scheme?.lowercased()
            && left.host?.lowercased() == right.host?.lowercased()
            && left.path == right.path
    }

    /// FastAPI answers failures with `{"detail": "..."}`. Those details are short,
    /// fixed sentences written by the bridge — never a provider body or a key.
    private static func failure(status: Int, data: Data) -> VoiceTransportError {
        switch status {
        case 401: return .unauthorized
        case 413: return .tooLarge
        case 415: return .unsupportedAudio
        default:
            if let detail = detail(from: data) {
                return .providerUnavailable(String(detail.prefix(160)))
            }
            return .providerUnavailable("The host's voice service failed (HTTP \(status)).")
        }
    }

    private static func detail(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = object["detail"] as? String else { return nil }
        return detail
    }

    // MARK: - Wire shapes

    private struct TranscribeBody: Encodable {
        let mimeType: String
        let contentBase64: String

        enum CodingKeys: String, CodingKey {
            case mimeType = "mime_type"
            case contentBase64 = "content_base64"
        }
    }

    private struct TranscribeReply: Decodable {
        let transcript: String
    }

    private struct SynthesizeBody: Encodable {
        let text: String
    }

    private struct SynthesizeReply: Decodable {
        let mimeType: String
        let contentBase64: String

        enum CodingKeys: String, CodingKey {
            case mimeType = "mime_type"
            case contentBase64 = "content_base64"
        }
    }
}
