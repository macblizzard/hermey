import HermesAppKit
import HermesKit
import HermeyUI
import SwiftUI

/// Login cards on the phone: the same door the Mac has, at a different size.
///
/// A bot asks, the owner answers here, and the value goes from this sheet straight to the host — it is
/// never put in the conversation, and it is cleared from the view the moment it is sent.
@MainActor
final class MobileCredentialCenter: ObservableObject {
    @Published var card: CredentialCard?
    @Published var failure: String?

    private var polling: Task<Void, Never>?

    func watch(model: AppModel) {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(model: model)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func refresh(model: AppModel) async {
        guard let cards = try? await model.credentialCards() else { return }
        let next = cards.filter { !$0.isExpired }.sorted { $0.expiresAt < $1.expiresAt }.first
        if next?.id != card?.id { card = next }
    }

    func answer(_ values: [String: String], model: AppModel) async {
        guard let card else { return }
        do {
            try await model.answerCredentialCard(id: card.id, values: values)
            self.card = nil
            failure = nil
        } catch {
            failure = "Could not send that — the card may have expired."
        }
    }

    func cancel(model: AppModel) async {
        guard let card else { return }
        try? await model.cancelCredentialCard(id: card.id)
        self.card = nil
    }
}

/// One card, in whichever shape it asked for.
struct MobileCredentialCardSheet: View {
    let card: CredentialCard
    let model: AppModel
    @ObservedObject var center: MobileCredentialCenter

    @State private var values: [String: String] = [:]
    @State private var sending = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(Tokens.accent)
                    Text("Sign in to \(card.site)")
                        .font(.headline)
                }

                if !card.note.isEmpty {
                    Text(card.note)
                        .font(.callout)
                        .foregroundStyle(Tokens.textMuted)
                }

                switch card.kind {
                case "choice": choice
                case "confirm": confirm
                default: secret
                }

                if let failure = center.failure {
                    Text(failure).font(.caption).foregroundStyle(.red)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.canvas)
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { Task { await center.cancel(model: model) } }
                    .hermeyFocusQuiet()
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var choice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How would you like to sign in?").font(.subheadline)
            ForEach(card.options, id: \.self) { option in
                Button {
                    send(["choice": option])
                } label: {
                    Text(option).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .hermeyFocusQuiet()
            }
        }
    }

    private var confirm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(card.options.first ?? "Use your saved connection?").font(.subheadline)
            HStack {
                Button("Use it") { send(["choice": "yes"]) }
                    .buttonStyle(.borderedProminent)
                    .hermeyFocusQuiet()
                Button("Not now") { Task { await center.cancel(model: model) } }
                    .buttonStyle(.bordered)
                    .hermeyFocusQuiet()
            }
        }
    }

    private var secret: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(card.fields, id: \.self) { field in
                Group {
                    if field == "password" {
                        SecureField(field.capitalized, text: binding(field))
                    } else {
                        TextField(field.capitalized, text: binding(field))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
            Button(sending ? "Sending…" : "Fill it in") {
                let payload = values
                send(payload)
            }
            .buttonStyle(.borderedProminent)
            .disabled(sending || values.values.allSatisfy(\.isEmpty))
            .hermeyFocusQuiet()
            Text("Goes straight into the page — the bot never sees it.")
                .font(.caption)
                .foregroundStyle(Tokens.textMuted)
        }
    }

    private func binding(_ field: String) -> Binding<String> {
        Binding(get: { values[field] ?? "" }, set: { values[field] = $0 })
    }

    private func send(_ payload: [String: String]) {
        sending = true
        Task {
            await center.answer(payload, model: model)
            values = [:]          // nothing typed stays in this view
            sending = false
        }
    }
}
