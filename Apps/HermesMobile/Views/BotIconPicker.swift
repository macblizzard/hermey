import Foundation
import SwiftUI
import HermeyUI
import HermesKit

/// One request consumes one freshly minted bridge ticket. Never pass a ticket
/// already used for a websocket, or put credentials in the URL.
struct BotIconService {
    let baseURL: URL
    let freshTicket: () async throws -> String
    var session: URLSession = .shared

    /// `faces` carries the stored `#RRGGBB::shape_N`; `shape`/`color` are what a host that has not
    /// been upgraded answers, and `icons` is the pre-pair payload. All three are read so no bot
    /// loses its face to an older bridge.
    private struct Payload: Decodable {
        struct Face: Decodable {
            let avatar: String?
            let shape: String?
            let color: String?
        }
        let faces: [String: Face]?
        let icons: [String: String]?
    }
    private struct TokenRequest: Encodable {
        let device_id: String
        let refresh_token: String
    }
    private struct TokenResponse: Decodable { let ws_ticket: String }
    private struct HTTPFailure: LocalizedError {
        let operation: String
        let status: Int
        var errorDescription: String? { "\(operation) failed (HTTP \(status))." }
    }

    /// Obtain a separate one-use ticket for this request using Keychain credentials.
    static func mintTicket(baseURL: URL, deviceID: String, refreshToken: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(TokenRequest(device_id: deviceID, refresh_token: refreshToken))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else { throw HTTPFailure(operation: "Ticket request", status: http.statusCode) }
        return try JSONDecoder().decode(TokenResponse.self, from: data).ws_ticket
    }
    private struct Change: Encodable {
        /// The stored `#RRGGBB::shape_N`. `nil` clears the face on the host.
        let avatar: String?
        enum CodingKeys: String, CodingKey { case avatar }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(avatar, forKey: .avatar)
        }
    }
    private func request(_ url: URL, method: String, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try await freshTicket())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else { throw HTTPFailure(operation: "Bot icon request", status: http.statusCode) }
        return data
    }
    func load() async throws -> [String: BotFaceChoice] {
        let data = try await request(baseURL.appendingPathComponent("v1/bot-icons"), method: "GET")
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        var faces: [String: BotFaceChoice] = [:]
        // The pre-pair ids first: a host that only knows them still gets a face, and a pair written
        // later on the same row overwrites it.
        for (botID, icon) in payload.icons ?? [:] {
            if let choice = BotFaceChoice.migrated(legacyIcon: icon) { faces[botID] = choice }
        }
        for (botID, face) in payload.faces ?? [:] {
            // The stored string wins; a pair without one is a choice made before this build, and
            // it is migrated rather than dropped.
            if let avatar = face.avatar, let choice = BotFaceChoice(rawValue: avatar) {
                faces[botID] = choice
            } else if let choice = BotFaceChoice.migrated(legacyShape: face.shape, legacyColor: face.color) {
                faces[botID] = choice
            }
        }
        return faces
    }

    func save(botID: String, face: BotFaceChoice?) async throws {
        let url = baseURL.appendingPathComponent("v1/bot-icons").appendingPathComponent(try BotIconPath.component(for: botID))
        _ = try await request(url, method: "PUT", body: JSONEncoder().encode(Change(avatar: face?.raw)))
    }

    /// The bots' own generated avatars, from the same document `load()` reads.
    ///
    /// The definition is arbitrary JSON, so it is read with `JSONSerialization` and handed to the
    /// avatar model: its shape belongs to the avatar contract, not to a struct declared here.
    func loadAvatars() async throws -> [String: BotAvatarDocument] {
        let data = try await request(baseURL.appendingPathComponent("v1/bot-icons"), method: "GET")
        return Self.avatars(in: data)
    }

    static func avatars(in data: Data) -> [String: BotAvatarDocument] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let faces = root["faces"] as? [String: Any] else { return [:] }
        var documents: [String: BotAvatarDocument] = [:]
        for (botID, value) in faces {
            guard let face = value as? [String: Any],
                  let definition = face["definition"],
                  JSONSerialization.isValidJSONObject(definition),
                  let encoded = try? JSONSerialization.data(withJSONObject: definition,
                                                            options: [.sortedKeys, .withoutEscapingSlashes]),
                  let text = String(data: encoded, encoding: .utf8),
                  let document = BotAvatarDocument(json: text,
                                                   color: face["color"] as? String,
                                                   material: face["material"] as? String) else { continue }
            documents[botID] = document
        }
        return documents
    }

    /// Save or clear one bot's avatar, sending only the avatar's two fields.
    func saveAvatar(botID: String, document: BotAvatarDocument?) async throws {
        let url = baseURL.appendingPathComponent("v1/bot-icons").appendingPathComponent(try BotIconPath.component(for: botID))
        let definition: Any
        if let document,
           let parsed = try? JSONSerialization.jsonObject(with: Data(document.definitionJSON().utf8)) {
            definition = parsed
        } else {
            definition = NSNull()
        }
        // `material` travels with the definition and is cleared with it: the host drops the
        // material when the definition is null, so a reset leaves nothing behind.
        let body: [String: Any] = ["definition": definition,
                                   "color": document?.color ?? NSNull(),
                                   "material": document?.material.rawValue ?? NSNull()]
        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        _ = try await request(url, method: "PUT", body: data)
    }
}

// `BotIconPicker` used to live here: a shape-and-colour chooser offered beside the Avatar tab's
// own editor, so a bot had two doors to its face and they could disagree. The Avatar tab is the
// only one now. The `BotIconService` above is what both shells' writes go through, so the file
// (and its name) stay.
