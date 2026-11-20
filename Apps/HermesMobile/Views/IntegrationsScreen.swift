import HermesAppKit
import HermesKit
import HermeyUI
import SwiftUI

/// The phone's Integrations screen: the same six services the Mac shows, connected the same way.
///
/// Connect hands the owner to Composio's hosted page in Safari. The app cannot see what happens there, so
/// it polls until the service reports connected and keeps saying "Waiting" until then — the tap does not
/// finish the job.
struct IntegrationsScreen: View {
    let model: AppModel

    @Environment(\.openURL) private var openURL
    @State private var state: IntegrationsState?
    @State private var busy: String?
    @State private var waiting: String?
    @State private var error: String?
    /// A name being typed: for a new account, or for renaming an existing one.
    @State private var naming: String?
    @State private var namingAccount: IntegrationAccount?
    @State private var namingText = ""

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Let your bots read and act in your own accounts. The connection is made on Composio's "
                     + "page — this app and your bots never see a password or a token.")
                    .font(.callout)
                    .foregroundStyle(Tokens.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if let state {
                    if !state.configured {
                        Text("No Composio key on this host yet. Add one in /etc/hermey/composio.key, then pull to refresh.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 10))
                    }
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(state.services) { service in
                            card(service, configured: state.configured)
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking…").foregroundStyle(Tokens.textMuted)
                    }
                }

                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(16)
        }
        .background(Tokens.canvas)
        .alert(namingAccount == nil ? "Name this account" : "Rename account",
               isPresented: Binding(get: { naming != nil || namingAccount != nil },
                                    set: { if !$0 { naming = nil; namingAccount = nil } })) {
            TextField("work, personal", text: $namingText)
            Button("Cancel", role: .cancel) { naming = nil; namingAccount = nil }
            Button("Save") {
                let wanted = namingText
                let account = namingAccount
                let slug = naming ?? ""
                naming = nil
                namingAccount = nil
                Task {
                    if let account, let service = state?.services.first(where: { $0.accounts.contains(account) }) {
                        await rename(service, account, wanted)
                    } else if !slug.isEmpty, let service = state?.services.first(where: { $0.slug == slug }) {
                        await connect(service, alias: wanted)
                    }
                }
            }
        }
        .navigationTitle("Integrations")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .task { await refresh() }
    }

    private func card(_ service: IntegrationService, configured: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image("brand-\(service.slug)")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
                    .opacity(service.available ? 1 : 0.4)
                Text(service.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            HStack(spacing: 5) {
                Circle()
                    .fill(service.connected ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 6, height: 6)
                Text(service.accounts.count > 1 ? "\(service.accounts.count) accounts"
                     : (service.connected ? "Connected" : (service.available ? "Not connected" : "Unavailable")))
                    .font(.caption2)
                    .foregroundStyle(Tokens.textMuted)
            }

            Text(service.blurb)
                .font(.caption2)
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            action(service, configured: configured)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Tokens.radiusGrouped))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusGrouped)
                .strokeBorder(service.connected ? Color.green.opacity(0.35) : Color.clear, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func action(_ service: IntegrationService, configured: Bool) -> some View {
        if !service.accounts.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(service.accounts) { account in
                    HStack(spacing: 6) {
                        Text(account.label).font(.caption2).lineLimit(1)
                        Spacer(minLength: 4)
                        Button("Rename") {
                            namingAccount = account
                            namingText = account.label
                        }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                        .disabled(busy != nil)
                        Button("Remove", role: .destructive) { Task { await disconnect(service, account) } }
                            .font(.caption2)
                            .buttonStyle(.borderless)
                            .disabled(busy != nil)
                    }
                }
                Button("Add another") {
                    namingAccount = nil
                    namingText = ""
                    naming = service.slug
                }
                .font(.caption2)
                .buttonStyle(.borderless)
                .disabled(busy != nil || !configured || !service.available)
            }
        } else if waiting == service.slug {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Waiting…").font(.caption2).foregroundStyle(Tokens.textMuted)
            }
        } else {
            Button("Connect") { Task { await connect(service) } }
                .font(.caption)
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .disabled(busy != nil || !configured || !service.available)
        }
    }

    private func refresh() async {
        do {
            state = try await model.integrations()
            error = nil
        } catch {
            self.error = "Could not load integrations — \(error.localizedDescription)"
        }
    }

    private func rename(_ service: IntegrationService, _ account: IntegrationAccount, _ alias: String) async {
        let wanted = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return }
        busy = service.slug
        defer { busy = nil }
        do {
            try await model.renameIntegration(slug: service.slug, accountID: account.id, alias: wanted)
            await refresh()
        } catch {
            self.error = "Could not rename that account."
        }
    }

    private func connect(_ service: IntegrationService, alias: String? = nil) async {
        busy = service.slug
        error = nil
        defer { busy = nil }
        do {
            let clean = (alias ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let link = try await model.connectIntegration(slug: service.slug,
                                                          alias: clean.isEmpty ? nil : clean)
            guard let url = URL(string: link) else {
                error = "The host returned a link that is not a URL."
                return
            }
            openURL(url)
            waiting = service.slug
            defer { waiting = nil }
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await refresh()
                if state?.services.first(where: { $0.slug == service.slug })?.connected == true { return }
            }
            error = "Still not connected — finish in Safari, then pull to refresh."
        } catch {
            self.error = "Could not start the connection."
        }
    }

    private func disconnect(_ service: IntegrationService, _ account: IntegrationAccount) async {
        busy = service.slug
        defer { busy = nil }
        do {
            try await model.disconnectIntegration(slug: service.slug, accountID: account.id)
            await refresh()
        } catch {
            self.error = "Could not disconnect."
        }
    }
}
