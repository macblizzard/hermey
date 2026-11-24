import Foundation
import HermesKit
import HermeyUI
import SwiftUI

/// The bridge consumes a fresh ticket for every HTTP request, including refreshes.
struct MacBotIconService {
    let address: PairingAddress

    enum Failure: LocalizedError {
        case devicePairingRequired
        case response(Int)
        case refresh(String)

        var errorDescription: String? {
            switch self {
            case .devicePairingRequired: return "Bot icons require a paired device, not a one-use ticket."
            case .response(let status): return "Bot icon request failed (HTTP \(status))."
            case .refresh(let message): return "Saved, but could not refresh icons: \(message)"
            }
        }
    }

    /// `faces` carries the stored `#RRGGBB::shape_N`; `shape`/`color` are what a host that has not
    /// been upgraded answers, and `icons` is the pre-pair payload. All three are read, so no bot
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
    private struct Change: Encodable {
        /// The stored `#RRGGBB::shape_N`. `nil` clears the face on the host.
        let avatar: String?
        enum CodingKeys: String, CodingKey { case avatar }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            // Always present: the host reads an explicit null as "clear the face".
            try container.encode(avatar, forKey: .avatar)
        }
    }

    private func request(url: URL, method: String, body: Data? = nil) async throws -> Data {
        guard !address.isTicketOnly else { throw Failure.devicePairingRequired }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try await address.mintedTicket())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else { throw Failure.response(http.statusCode) }
        return data
    }

    func load() async throws -> [String: BotFaceChoice] {
        let url = try address.apiOrigin().appendingPathComponent("v1/bot-icons")
        let data = try await request(url: url, method: "GET")
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        var faces: [String: BotFaceChoice] = [:]
        // An icon-only row (a host before the pair) maps to the colour that icon was drawn in, so
        // no bot's face changes across the upgrade.
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
        let url = try address.apiOrigin().appendingPathComponent("v1/bot-icons")
            .appendingPathComponent(BotIconPath.component(for: botID))
        _ = try await request(url: url, method: "PUT", body: JSONEncoder().encode(Change(avatar: face?.raw)))
    }

    /// The avatars the host has, from the same document `load()` reads.
    ///
    /// Parsed with `JSONSerialization` rather than `Decodable` because a definition is arbitrary
    /// JSON: its shape belongs to the avatar contract, not to a struct this app declares for it.
    func loadAvatars() async throws -> [String: BotAvatarDocument] {
        let url = try address.apiOrigin().appendingPathComponent("v1/bot-icons")
        let data = try await request(url: url, method: "GET")
        return Self.avatars(in: data)
    }

    /// One document per bot, from a `GET /v1/bot-icons` answer. Static so the shape can be tested
    /// without a host.
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
                  let document = BotAvatarDocument(json: text, color: face["color"] as? String) else { continue }
            documents[botID] = document
        }
        return documents
    }

    /// Save or clear one bot's avatar. Only `definition` and `color` are sent: the chosen face is
    /// the picker's, and a save here must not disturb it.
    func saveAvatar(botID: String, document: BotAvatarDocument?) async throws {
        let url = try address.apiOrigin().appendingPathComponent("v1/bot-icons")
            .appendingPathComponent(BotIconPath.component(for: botID))
        let definition: Any
        if let document,
           let parsed = try? JSONSerialization.jsonObject(with: Data(document.definitionJSON().utf8)) {
            definition = parsed
        } else {
            definition = NSNull()
        }
        let body: [String: Any] = ["definition": definition, "color": document?.color ?? NSNull()]
        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        _ = try await request(url: url, method: "PUT", body: data)
    }
}

// The face picker that used to live here (`MacBotIconPicker`) is gone: the bot settings sheet's
// Avatar tab is the one place a bot's face is chosen, and the About tab no longer offers a second
// chooser. The service above is what both doors write through, so it stays.
