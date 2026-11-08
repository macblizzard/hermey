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

    private struct Icons: Decodable { let icons: [String: String] }
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
    private struct Change: Encodable { let icon: String?; enum CodingKeys: String, CodingKey { case icon }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if let icon { try c.encode(icon, forKey: .icon) } else { try c.encodeNil(forKey: .icon) }
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
    func load() async throws -> [String: BotIcon] {
        let data = try await request(baseURL.appendingPathComponent("v1/bot-icons"), method: "GET")
        return try JSONDecoder().decode(Icons.self, from: data).icons.compactMapValues(BotIcon.init(rawValue:))
    }
    func save(botID: String, icon: BotIcon?) async throws {
        let url = baseURL.appendingPathComponent("v1/bot-icons").appendingPathComponent(try BotIconPath.component(for: botID))
        _ = try await request(url, method: "PUT", body: JSONEncoder().encode(Change(icon: icon?.rawValue)))
    }
}

/// Caller refreshes its shared dictionary after saving; errors stay visible.
struct BotIconPicker: View {
    let botName: String
    let selected: BotIcon?
    let save: (BotIcon?) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Choose an original robot portrait for \(botName). Your paired devices share this choice.")
                        .foregroundStyle(Tokens.textSecondary)
                    BotIconGallery(selected: selected) { icon in
                        guard !saving else { return }
                        saving = true
                        Task {
                            do { try await save(icon); dismiss() }
                            catch { self.error = error.localizedDescription; saving = false }
                        }
                    }.disabled(saving)
                    if saving { ProgressView("Saving…") }
                    if let error { Text(error).foregroundStyle(Tokens.danger) }
                }.padding()
            }
            .navigationTitle("Bot icon")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) } }
        }
    }
}
