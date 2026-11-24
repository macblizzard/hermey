import HermesAppKit
import HermesKit
import HermeyUI
import SwiftUI

/// The login cards, as the Mac shows them.
///
/// A card is asked for by a bot and answered by the owner. The value the owner types goes straight from
/// this view to the bridge: it is never put in `@State` that outlives the submit, never logged, and never
/// handed to the model. That is why the field bindings are cleared the moment they are sent.
@MainActor
final class CredentialCardCenter: ObservableObject {
    @Published var card: CredentialCard?
    @Published var failure: String?

    private var polling: Task<Void, Never>?
    private var lastSeen: String?

    /// Poll while the window is up: a card lives two minutes and asking every couple of seconds costs
    /// nothing next to a second transport to keep healthy.
    func watch(model: AppModel) {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(model: model)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        polling?.cancel()
        polling = nil
    }

    func refresh(model: AppModel) async {
        guard let cards = try? await model.credentialCards() else { return }
        // Oldest first: if two are open, the owner should answer the one asked for first.
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
            failure = "Could not send that. The card may have expired."
        }
    }

    func cancel(model: AppModel) async {
        guard let card else { return }
        try? await model.cancelCredentialCard(id: card.id)
        self.card = nil
    }
}

/// One card, in whichever shape it asked for.
struct CredentialCardSheet: View {
    let card: CredentialCard
    let model: AppModel
    @ObservedObject var center: CredentialCardCenter

    @State private var values: [String: String] = [:]
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(Tokens.accent)
                Text("Sign in to \(card.site)")
                    .font(.headline)
                Spacer()
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

            HStack {
                Text("Expires in \(max(0, Int(card.expiresAt - Date().timeIntervalSince1970)))s")
                    .font(.caption)
                    .foregroundStyle(Tokens.textMuted)
                Spacer()
                Button("Cancel") {
                    Task { await center.cancel(model: model) }
                }
                .keyboardShortcut(.cancelAction)
                .hermeyFocusQuiet()
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var choice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How would you like to sign in?").font(.subheadline)
            ForEach(card.options, id: \.self) { option in
                Button {
                    send(["choice": option])
                } label: {
                    Text(option).frame(maxWidth: .infinity, alignment: .leading)
                }
                .hermeyFocusQuiet()
            }
        }
    }

    private var confirm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.options.first ?? "Use your saved connection?")
                .font(.subheadline)
            HStack {
                Button("Use it") { send(["choice": "yes"]) }
                .hermeyFocusQuiet()
                Button("Not now") { Task { await center.cancel(model: model) } }
                .hermeyFocusQuiet()
            }
        }
    }

    private var secret: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(card.fields, id: \.self) { field in
                Group {
                    if field == "password" {
                        SecureField(field.capitalized, text: binding(field))
                    } else {
                        TextField(field.capitalized, text: binding(field))
                    }
                }
                .textFieldStyle(.roundedBorder)
            }
            Button(sending ? "Sending…" : "Fill it in") {
                let payload = values
                send(payload)
            }
            .keyboardShortcut(.defaultAction)
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
            values = [:]                     // nothing typed stays in this view
            sending = false
        }
    }
}
