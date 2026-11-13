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

    /// `faces` is what this build writes and reads; `icons` is the pre-shape-pair payload, read so
    /// a host that has not been upgraded yet still shows every bot's own face.
    private struct Payload: Decodable {
        struct Face: Decodable { let shape: String; let color: String }
        let faces: [String: Face]?
        let icons: [String: String]?
    }
    private struct Change: Encodable {
        let shape: String?
        let color: String?
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if let shape, let color {
                try container.encode(shape, forKey: .shape)
                try container.encode(color, forKey: .color)
            } else {
                // Nothing of either: the host reads that as "clear the face".
                try container.encodeNil(forKey: .shape)
                try container.encodeNil(forKey: .color)
            }
        }
        enum CodingKeys: String, CodingKey { case shape, color }
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

    func load() async throws -> [String: BotFace] {
        let url = try address.apiOrigin().appendingPathComponent("v1/bot-icons")
        let data = try await request(url: url, method: "GET")
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        var faces: [String: BotFace] = [:]
        // An icon-only row (a host before the pair) maps to the colour that icon was drawn in, so
        // no bot's face changes across the upgrade.
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
        let url = try address.apiOrigin().appendingPathComponent("v1/bot-icons")
            .appendingPathComponent(BotIconPath.component(for: botID))
        let change = Change(shape: face?.shape.rawValue, color: face?.color.rawValue)
        _ = try await request(url: url, method: "PUT", body: JSONEncoder().encode(change))
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
                Text("Portrait for \(bot.displayName)")
                    .font(TypeScale.font(Tokens.textLG, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                Spacer()
                OpenBotButton("Cancel", kind: .secondary, size: .small) { dismiss() }
                    .disabled(saving)
            }
            Text("Any shape, any colour. Your paired devices share this choice, and your own message bubbles take the colour.")
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textMuted)
            ScrollView {
                BotFacePicker(face: store.botFaces[bot.id]) { face in
                    guard !saving else { return }
                    saving = true
                    error = nil
                    Task {
                        do {
                            try await store.saveBotFace(botID: bot.id, face: face)
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
        .frame(width: 520, height: 520)
        .background(Tokens.canvas)
        .preferredColorScheme(.dark)
    }
}
