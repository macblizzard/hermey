import Foundation
import HermesKit
import OpenBotUI
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

    private struct Icons: Decodable { let icons: [String: String] }
    private struct Change: Encodable {
        let icon: String?
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if let icon { try container.encode(icon, forKey: .icon) }
            else { try container.encodeNil(forKey: .icon) }
        }
        enum CodingKeys: String, CodingKey { case icon }
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

    func load() async throws -> [String: BotIcon] {
        let url = try address.apiOrigin().appendingPathComponent("v1/bot-icons")
        let data = try await request(url: url, method: "GET")
        return try JSONDecoder().decode(Icons.self, from: data).icons.compactMapValues(BotIcon.init(rawValue:))
    }

    func save(botID: String, icon: BotIcon?) async throws {
        let url = try address.apiOrigin().appendingPathComponent("v1/bot-icons")
            .appendingPathComponent(BotIconPath.component(for: botID))
        _ = try await request(url: url, method: "PUT", body: JSONEncoder().encode(Change(icon: icon?.rawValue)))
    }
}

struct MacBotIconPicker: View {
    let bot: Bot
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Bot icon for \(bot.displayName)")
                    .font(TypeScale.font(Tokens.textLG, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                Spacer()
                OpenBotButton("Cancel", kind: .secondary, size: .small) { dismiss() }
                    .disabled(saving)
            }
            Text("Your paired devices share this choice.")
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textMuted)
            ScrollView {
                BotIconGallery(selected: store.botIcons[bot.id]) { icon in
                    guard !saving else { return }
                    saving = true
                    error = nil
                    Task {
                        do {
                            try await store.saveBotIcon(botID: bot.id, icon: icon)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                            saving = false
                        }
                    }
                }.disabled(saving)
            }
            if saving { ProgressView("Saving…") }
            if let error {
                Text(error)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 500, height: 420)
        .background(Tokens.canvas)
        .preferredColorScheme(.dark)
    }
}
