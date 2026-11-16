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
                HermeyButton("Cancel", kind: .secondary, size: .small) { dismiss() }
                    .disabled(saving)
            }
            Text("Any body, any colour. Your paired devices share this choice, and your own message bubbles take the colour.")
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textMuted)
            ScrollView {
                BotFacePicker(identity: bot.id, value: store.botFaces[bot.id]) { face in
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
