import Foundation
import HermesKit

/// Fetches a picture back from the paired host.
///
/// The bytes of an attachment live on the host; the transcript only names them. A device that
/// reinstalled, reaped its cache, or never sent the picture in the first place (the Mac reading a
/// conversation the phone started) asks here instead of guessing.
struct AttachmentImageService {
    let baseURL: URL
    let freshTicket: () async throws -> String
    var session: URLSession = .shared

    private struct Failure: LocalizedError {
        let status: Int
        var errorDescription: String? { "Attachment request failed (HTTP \(status))." }
    }

    func load(profile: String, name: String) async throws -> Data {
        // Both segments are single path components on the host; percent-encoding keeps a name with
        // a space or an odd character from being read as a path.
        guard let encodedProfile = profile.addingPercentEncoding(withAllowedCharacters: URLPath.componentAllowed),
              let encodedName = name.addingPercentEncoding(withAllowedCharacters: URLPath.componentAllowed)
        else { throw URLError(.badURL) }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/attachments/\(encodedProfile)/\(encodedName)"))
        request.setValue("Bearer \(try await freshTicket())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else { throw Failure(status: http.statusCode) }
        return data
    }
}
