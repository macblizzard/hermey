import AppKit
import HermesAppKit
import HermesKit
import HermeyUI
import SwiftUI

/// Settings → Integrations: connect a Google account to this host through Composio.
///
/// A card per service, with the service's own mark, because a list of names is unreadable at a glance
/// when six of them are Google. The screen never sees a token: Connect asks the bridge for Composio's
/// hosted page, opens it in the browser, and then polls until the service reports connected — the tap
/// does not finish the job, and the card says so rather than pretending.
struct IntegrationsTab: View {
    @ObservedObject var store: WorkspaceStore

    @State private var state: IntegrationsState?
    @State private var busy: String?
    @State private var error: String?
    @State private var waiting: String?

    private let columns = [GridItem(.adaptive(minimum: 232), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let state {
                if !state.configured {
                    notice("No Composio key on this host yet. Put one in /etc/hermey/composio.key "
                           + "or COMPOSIO_API_KEY, then press Refresh.")
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(state.services) { service in
                        card(service, configured: state.configured)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking…").foregroundStyle(Tokens.textMuted)
                }
                .padding(.vertical, 8)
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Refresh") { Task { await refresh() } }
                    .disabled(busy != nil)
                Spacer()
                if let state, state.services.contains(where: \.connected) {
                    Text("Connections are held by Composio, never by this app.")
                        .font(.caption2)
                        .foregroundStyle(Tokens.textMuted)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 560, alignment: .leading)
        .task { await refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Integrations")
                .font(.title3.weight(.semibold))
            Text("Let your bots read and act in your own accounts. The connection is made on Composio's page — "
                 + "this app and your bots never see a password or a token.")
                .font(.callout)
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - One service

    private func card(_ service: IntegrationService, configured: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                mark(for: service)
                Text(service.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }

            statusDot(service)

            Text(service.blurb)
                .font(.caption)
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            footer(service, configured: configured)
        }
        .padding(12)
        .frame(minHeight: 148, alignment: .topLeading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Tokens.radiusGrouped))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusGrouped)
                .strokeBorder(service.connected ? Color.green.opacity(0.35) : Color.clear, lineWidth: 1)
        )
    }

    /// The service's own mark, from the asset catalog (`brand-<slug>`). A missing logo would be an empty
    /// box, so the size and aspect are fixed here rather than left to whatever the bundle happens to hold.
    private func mark(for service: IntegrationService) -> some View {
        Image("brand-\(service.slug)")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: 22, height: 22)
            .opacity(service.available ? 1 : 0.4)
            .accessibilityHidden(true)
    }

    private func statusDot(_ service: IntegrationService) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(service.connected ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 7, height: 7)
            Text(statusText(service))
                .font(.caption2)
                .foregroundStyle(Tokens.textMuted)
        }
    }

    private func statusText(_ service: IntegrationService) -> String {
        if service.accounts.count > 1 { return "\(service.accounts.count) accounts" }
        return service.connected ? "Connected" : (service.available ? "Not connected" : "Unavailable")
    }

    @ViewBuilder
    private func footer(_ service: IntegrationService, configured: Bool) -> some View {
        if !service.accounts.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(service.accounts) { account in
                    HStack(spacing: 6) {
                        Text(account.label).font(.caption).lineLimit(1)
                        Spacer(minLength: 4)
                        Button("Remove") { Task { await disconnect(service, account) } }
                            .buttonStyle(.link)
                            .font(.caption2)
                            .disabled(busy != nil)
                    }
                }
                Button("Add another") { Task { await connect(service) } }
                    .controlSize(.mini)
                    .disabled(busy != nil || !configured || !service.available)
            }
        } else if busy == service.slug || waiting == service.slug {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for the browser…").font(.caption2).foregroundStyle(Tokens.textMuted)
            }
        } else {
            Button("Connect") { Task { await connect(service) } }
                .controlSize(.small)
                .disabled(busy != nil || !configured || !service.available)
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Actions

    private func refresh() async {
        do {
            state = try await store.model.integrations()
            error = nil
        } catch {
            self.error = "Could not reach the bridge."
        }
    }

    private func connect(_ service: IntegrationService) async {
        busy = service.slug
        error = nil
        defer { busy = nil }
        do {
            let link = try await store.model.connectIntegration(slug: service.slug)
            guard let url = URL(string: link) else {
                error = "The bridge returned a link that is not a URL."
                return
            }
            NSWorkspace.shared.open(url)
            waiting = service.slug
            defer { waiting = nil }
            // The sign-in happens in the browser, where this app cannot see it. Poll for a minute so the
            // card flips on its own instead of asking the owner to come back and press Refresh.
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await refresh()
                if state?.services.first(where: { $0.slug == service.slug })?.connected == true { return }
            }
            error = "Still not connected — finish the page in your browser, then press Refresh."
        } catch {
            self.error = "Could not start the connection."
        }
    }

    private func disconnect(_ service: IntegrationService, _ account: IntegrationAccount) async {
        busy = service.slug
        defer { busy = nil }
        do {
            try await store.model.disconnectIntegration(slug: service.slug, accountID: account.id)
            await refresh()
        } catch {
            self.error = "Could not disconnect."
        }
    }
}
