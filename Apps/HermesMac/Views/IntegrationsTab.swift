import AppKit
import HermesAppKit
import HermesKit
import HermeyUI
import SwiftUI

/// Settings → Integrations: connect a Google account to this host through Composio.
///
/// The screen never sees a token. Connect asks the bridge for a hosted Composio page, opens it in the
/// browser, and then waits for the answer to arrive the only way it can: by polling the bridge until the
/// service reports connected. That is why the button says "Waiting for the browser…" rather than
/// pretending the tap finished the job.
struct IntegrationsTab: View {
    @ObservedObject var store: WorkspaceStore

    @State private var state: IntegrationsState?
    @State private var busy: String?
    @State private var error: String?
    @State private var waiting: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Integrations")
                    .font(.title3.weight(.semibold))
                Text("Let your bots read and act in your own accounts. Connections are made on Composio's page — "
                     + "this app and your bots never see the password or the token.")
                    .font(.callout)
                    .foregroundStyle(Tokens.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let state {
                if !state.configured {
                    notice("No Composio key on this host yet. Put one in /etc/hermey/composio.key "
                           + "or COMPOSIO_API_KEY, then reopen this tab.", tone: .warn)
                }
                VStack(spacing: 0) {
                    ForEach(state.services) { service in
                        row(service, configured: state.configured)
                        if service.id != state.services.last?.id { Divider() }
                    }
                }
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Tokens.radiusGrouped))
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
                if let state { Text("Signed in as \(state.user)").font(.caption).foregroundStyle(Tokens.textMuted) }
            }
        }
        .padding(20)
        .frame(minWidth: 540, alignment: .leading)
        .task { await refresh() }
    }

    private func row(_ service: IntegrationService, configured: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name).font(.body)
                Text(service.blurb).font(.caption).foregroundStyle(Tokens.textMuted)
            }
            Spacer()
            if service.connected {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Button("Disconnect") { Task { await disconnect(service) } }
                    .buttonStyle(.link)
                    .disabled(busy != nil)
            } else if busy == service.slug || waiting == service.slug {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the browser…").font(.caption).foregroundStyle(Tokens.textMuted)
                }
            } else {
                Button("Connect") { Task { await connect(service) } }
                    .disabled(busy != nil || !configured || !service.available)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func notice(_ text: String, tone: NoticeTone) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tone == .warn ? Color.orange : Tokens.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private enum NoticeTone { case warn }

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
            // The user is now in a browser; the connection completes there. Poll for a while so the row
            // flips to Connected without them having to press Refresh.
            waiting = service.slug
            defer { waiting = nil }
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await refresh()
                if state?.services.first(where: { $0.slug == service.slug })?.connected == true { return }
            }
            error = "Still not connected. Finish the page in your browser, then press Refresh."
        } catch {
            self.error = "Could not start the connection."
        }
    }

    private func disconnect(_ service: IntegrationService) async {
        busy = service.slug
        defer { busy = nil }
        do {
            try await store.model.disconnectIntegration(slug: service.slug)
            await refresh()
        } catch {
            self.error = "Could not disconnect."
        }
    }
}
