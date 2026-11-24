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
    @State private var applying: ApprovalMode?

    private var model: AppModel { store.model }

    /// While the host's answer is unknown or mixed, Auto is the highlighted default — it still asks
    /// for the actions Hermes considers dangerous, unlike Allow always.
    private var selectedMode: ApprovalMode { settings?.mode ?? .recommended }

    var body: some View {
        Form {
            Section {
                ForEach(ApprovalMode.allCases, id: \.self) { mode in
                    Button { choose(mode) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: selectedMode == mode
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedMode == mode ? Tokens.accent : Tokens.textDim)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(mode.title)
                                        .font(TypeScale.font(TypeScale.md, weight: .medium))
                                        .foregroundStyle(Tokens.textPrimary)
                                    if mode == .smart {
                                        Text("Recommended")
                                            .font(TypeScale.font(TypeScale.caption))
                                            .foregroundStyle(Tokens.accentText)
                                    }
                                }
                                Text(mode.detail)
                                    .font(TypeScale.font(TypeScale.caption))
                                    .foregroundStyle(Tokens.textMuted)
                            }
                            Spacer(minLength: 4)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // The blue focus ring on the first row read as "this option is selected" even
                    // when Auto was. These are radio-like choices, not keyboard targets.
                    .focusable(false)
                    .hermeyFocusQuiet()
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
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Tokens.canvas)
        .task { await load() }
        .confirmationDialog("Allow every guarded action?", isPresented: Binding(
            get: { pending != nil },
            set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible) {
            Button("Allow always", role: .destructive) {
                if let mode = pending { Task { await apply(mode) } }
                pending = nil
            }
            .hermeyFocusQuiet()
            Button("Cancel", role: .cancel) { pending = nil }
            .hermeyFocusQuiet()
        } message: {
            Text("Allow always runs every guarded action on every bot without asking. Auto is the safer default.")
        }
    }

    private var footer: String {
        if let applying { return "Applying \(applying.title) to every bot…" }
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
        do {
            let answer = try await model.approvalSettings()
            settings = answer
            // Nothing configured anywhere yet: make Auto the real default on the host, not just a
            // highlighted row in this view. A mode that has been set — by anyone — is never overwritten.
            if !answer.profiles.isEmpty, answer.unset.count == answer.profiles.count {
                settings = try await model.setApprovalMode(.recommended)
            }
        } catch { self.error = (error as Error).localizedDescription }
    }

    private func apply(_ mode: ApprovalMode) async {
        applying = mode
        defer { applying = nil }
        do {
            // The bridge answers in the GET shape now, so the checkmark and the footer below show
            // what the host actually stored instead of a stale summary.
            settings = try await model.setApprovalMode(mode)
            error = nil
        } catch {
            self.error = (error as Error).localizedDescription
        }
    }
}
