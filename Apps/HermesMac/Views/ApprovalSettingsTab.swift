import HermesAppKit
import HermesKit
import HermeyUI
import SwiftUI

/// One approval policy for every bot on the host. The three choices are the host's own modes —
/// `manual` (ask every time), `smart` (the host decides) and `off` (never ask) — exposed here with
/// plain-language labels. This is a fleet setting because the host stores it in each bot's config.
struct ApprovalSettingsTab: View {
    @ObservedObject var store: WorkspaceStore

    @State private var settings: ApprovalSettings?
    @State private var pending: ApprovalMode?
    @State private var error: String?

    private var model: AppModel { store.model }

    var body: some View {
        Form {
            Section {
                ForEach(ApprovalMode.allCases, id: \.self) { mode in
                    Button { choose(mode) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: settings?.mode == mode
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(settings?.mode == mode ? Tokens.accent : Tokens.textDim)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mode.title)
                                    .font(TypeScale.font(TypeScale.md, weight: .medium))
                                    .foregroundStyle(Tokens.textPrimary)
                                Text(mode.detail)
                                    .font(TypeScale.font(TypeScale.caption))
                                    .foregroundStyle(Tokens.textMuted)
                            }
                            Spacer(minLength: 4)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Approvals · all bots")
            } footer: {
                Text(footer)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
            }

            if let error {
                Section {
                    Text(error)
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.danger)
                }
            }
        }
        .task { await load() }
        .confirmationDialog("Never ask for approval?", isPresented: Binding(
            get: { pending != nil },
            set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible) {
            Button("Never ask", role: .destructive) {
                if let mode = pending { Task { await apply(mode) } }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("Every guarded action on every bot will run without asking. Auto is usually the safer default.")
        }
    }

    private var footer: String {
        guard let settings else { return "Reading the host's approval setting…" }
        if !settings.failed.isEmpty {
            return "Could not update: \(settings.failed.keys.sorted().joined(separator: ", "))."
        }
        if settings.mode == nil {
            return "Bots have different approval modes on the host; choose one to make them match."
        }
        return "Applies to \(settings.profiles.count) bots on this host."
    }

    private func choose(_ mode: ApprovalMode) {
        if mode == .off { pending = mode }
        else { Task { await apply(mode) } }
    }

    private func load() async {
        do { settings = try await model.approvalSettings() }
        catch { error = error.localizedDescription }
    }

    private func apply(_ mode: ApprovalMode) async {
        do {
            settings = try await model.setApprovalMode(mode)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
