import Foundation
import SwiftUI
import OpenBotUI
import HermesKit

/// One request consumes one freshly minted bridge ticket. Never pass a ticket
/// already used for a websocket, or put credentials in the URL.
struct BotIconService {
    let baseURL: URL
    let freshTicket: () async throws -> String
    var session: URLSession = .shared

    /// `faces` is what this build writes; `icons` is the pre-pair payload, read so an older host
    /// still shows every bot its own face.
    private struct Payload: Decodable {
        struct Face: Decodable { let shape: String; let color: String }
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
        let shape: String?
        let color: String?
        enum CodingKeys: String, CodingKey { case shape, color }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if let shape, let color {
                try c.encode(shape, forKey: .shape)
                try c.encode(color, forKey: .color)
            } else {
                try c.encodeNil(forKey: .shape)
                try c.encodeNil(forKey: .color)
            }
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
    func load() async throws -> [String: BotFace] {
        let data = try await request(baseURL.appendingPathComponent("v1/bot-icons"), method: "GET")
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        var faces: [String: BotFace] = [:]
        for (botID, icon) in payload.icons ?? [:] {
            if let shape = BotIcon(rawValue: icon) { faces[botID] = .legacy(shape) }
        }
        for (botID, face) in payload.faces ?? [:] {
            if let shape = BotIcon(rawValue: face.shape), let color = BotColor(rawValue: face.color) {
                faces[botID] = BotFace(shape: shape, color: color)
            }
        }
        return faces
    }
    func save(botID: String, face: BotFace?) async throws {
        let url = baseURL.appendingPathComponent("v1/bot-icons").appendingPathComponent(try BotIconPath.component(for: botID))
        let change = Change(shape: face?.shape.rawValue, color: face?.color.rawValue)
        _ = try await request(url, method: "PUT", body: JSONEncoder().encode(change))
    }
}

/// Caller refreshes its shared dictionary after saving; errors stay visible.
struct BotIconPicker: View {
    let botName: String
    let selected: BotFace?
    let save: (BotFace?) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Any shape, any colour. Your paired devices share this choice, and your own message bubbles take the colour.")
                        .font(TypeScale.font(TypeScale.sm))
                        .foregroundStyle(Tokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    BotFacePicker(face: selected) { face in
                        guard !saving else { return }
                        saving = true
                        error = nil
                        Task {
                            do {
                                try await save(face)
                                dismiss()
                            } catch {
                                self.error = error.localizedDescription
                            }
                            saving = false
                        }
                    }

                    if let error {
                        Text(error)
                            .font(TypeScale.font(TypeScale.sm))
                            .foregroundStyle(Tokens.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(18)
            }
            .background(Tokens.canvas)
            .navigationTitle("Portrait for \(botName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
