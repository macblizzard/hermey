import HermesAppKit
import HermesKit
import HermeyUI
import SwiftUI

/// Settings → Vault on the phone: the host's secrets, by name.
///
/// The Mac's Settings has a Vault tab and this is the same pane at a different size — the same
/// `VaultItem` rows, the same words, the same three states (reading, empty, unreachable). It lists
/// names and labels only: a value has no field to arrive in, no reveal control exists here, and a swipe
/// deletes a name rather than reading one.
///
/// Adding goes through `MobileCredentialCardSheet` — the credential card's own sheet — so the one masked
/// field the owner types into is the one that already existed on this phone.
struct VaultScreen: View {
    @ObservedObject var model: AppModel

    /// `nil` = not read yet. An empty vault is `[]`; a host that could not be reached leaves this nil
    /// and sets `failure`, which is what stops the two states looking identical.
    @State private var items: [VaultItem]?
    @State private var failure: String?
    @State private var pendingDelete: VaultItem?
    @State private var actionError: String?
    @State private var showAdd = false

    var body: some View {
        List {
            if let failure {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("The vault could not be read", systemImage: "exclamationmark.triangle")
                            .font(TypeScale.font(TypeScale.md))
                            .foregroundStyle(Tokens.danger)
                        Text(failure)
                            .font(TypeScale.font(TypeScale.label))
                            .foregroundStyle(Tokens.textMuted)
                        Button("Try again") { Task { await load() } }
                            .foregroundStyle(Tokens.accentText)
                            .hermeyFocusQuiet()
                    }
                    .listRowBackground(Tokens.surface)
                }
            } else if items == nil {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Reading the vault…")
                            .font(TypeScale.font(TypeScale.md))
                            .foregroundStyle(Tokens.textMuted)
                    }
                    .listRowBackground(Tokens.surface)
                }
            } else if let items, items.isEmpty {
                Section {
                    Text("Nothing is saved yet. Add a secret and any bot can ask to use it by name.")
                        .font(TypeScale.font(TypeScale.md))
                        .foregroundStyle(Tokens.textMuted)
                        .listRowBackground(Tokens.surface)
                }
            } else if let items {
                Section {
                    ForEach(items) { item in
                        row(item)
                            .listRowBackground(Tokens.surface)
                            // Swipe to remove, with the same confirmation the Mac's trash button asks
                            // for: a name gone by accident means a bot asking for a secret that is not
                            // there any more.
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDelete = item
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .hermeyFocusQuiet()
                            }
                    }
                } footer: {
                    Text("Secrets your bots use, kept on this host. A value is written once and never "
                         + "shown again — not here, not in a chat.")
                        .font(TypeScale.font(TypeScale.label))
                }
            }

            if let actionError {
                Section {
                    Text(actionError)
                        .font(TypeScale.font(TypeScale.label))
                        .foregroundStyle(Tokens.danger)
                        .listRowBackground(Tokens.surface)
                }
            }

            Section {
                Button {
                    showAdd = true
                } label: {
                    Label("Add a secret", systemImage: "plus")
                        .font(TypeScale.font(TypeScale.md))
                        .foregroundStyle(Tokens.accentText)
                }
                .listRowBackground(Tokens.surface)
                .hermeyFocusQuiet()
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Tokens.canvas)
        .navigationTitle("Vault")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showAdd) {
            VaultAddSheet(model: model) { await load() }
                .hermesSheetChrome()
        }
        .confirmationDialog("Delete this secret?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let item = pendingDelete { Task { await delete(item) } }
                pendingDelete = nil
            }
            .hermeyFocusQuiet()
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            .hermeyFocusQuiet()
        } message: {
            Text("\"\(pendingDelete?.name ?? "")\" is removed from the host's vault. Anything that uses "
                 + "it will need it saved again.")
        }
    }

    /// One saved secret: its name, where it is for, when it was added. No value, and nothing that would
    /// offer to show one.
    private func row(_ item: VaultItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.name)
                .font(.system(size: TypeScale.md, design: .monospaced))
                .foregroundStyle(Tokens.textPrimary)
            Text(detail(item))
                .font(TypeScale.font(TypeScale.label))
                .foregroundStyle(Tokens.textMuted)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive) { pendingDelete = item } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func detail(_ item: VaultItem) -> String {
        var parts: [String] = []
        if let site = item.site, !site.isEmpty { parts.append("for \(site)") }
        if let note = item.note, !note.isEmpty { parts.append(note) }
        if item.addedAt > 0 {
            parts.append("added \(item.addedOn.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        do {
            items = try await model.vaultItems()
            failure = nil
        } catch {
            items = nil
            failure = VaultFailure.sentence(error)
        }
    }

    private func delete(_ item: VaultItem) async {
        do {
            try await model.deleteVaultItem(name: item.name)
            actionError = nil
        } catch {
            // The host refused (404/409). Say so, then re-read what it actually holds.
            actionError = VaultFailure.sentence(error)
        }
        await load()
    }
}

/// Adding one secret on the phone: the name, where it is for, then the existing masked sheet.
///
/// Two steps, for the same reason as on the Mac: the name is a label the host validates, so it is
/// checked before a value is typed; the value itself is typed into `MobileCredentialCardSheet`, which is
/// the credential card's own view, unchanged.
struct VaultAddSheet: View {
    let model: AppModel
    var onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var center = MobileCredentialCenter()

    @State private var name = ""
    @State private var site = ""
    @State private var card: CredentialCard?
    @State private var creating = false
    @State private var error: String?

    private var trimmedName: String { VaultName.trimmed(name) }
    private var nameIsValid: Bool { VaultName.isValid(trimmedName) }

    var body: some View {
        Group {
            if let card {
                MobileCredentialCardSheet(card: card, model: model, center: center)
            } else {
                details
            }
        }
        .onChange(of: center.card?.id) { _, next in
            guard card != nil, next == nil else { return }
            Task {
                await onSaved()
                dismiss()
            }
        }
    }

    private var details: some View {
        NavigationStack {
            List {
                Section {
                    TextField("openai.main", text: $name)
                        .font(.system(size: TypeScale.md, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("api.openai.com (optional)", text: $site)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Name")
                } footer: {
                    // The host's own rule, checked here first so nobody types a value into a form whose
                    // name was never going to be accepted.
                    Text(name.isEmpty || nameIsValid ? "Letters, digits, '.', '_', '-' and one '/'."
                                                     : VaultName.rule)
                        .foregroundStyle(name.isEmpty || nameIsValid ? Tokens.textMuted : Tokens.danger)
                }

                if let error {
                    Section {
                        Text(error)
                            .font(TypeScale.font(TypeScale.label))
                            .foregroundStyle(Tokens.danger)
                    }
                }

                Section {
                    Button(creating ? "Opening…" : "Continue") {
                        Task { await askForCard() }
                    }
                    .disabled(!nameIsValid || creating)
                    .hermeyFocusQuiet()
                } footer: {
                    Text("Next you type the value into the same sheet a bot's login card uses. The host "
                         + "keeps it; this phone never sees it again.")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Tokens.canvas)
            .navigationTitle("Add a secret")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .hermeyFocusQuiet()
                }
            }
        }
    }

    private func askForCard() async {
        creating = true
        defer { creating = false }
        do {
            let made = try await model.createVaultEntryCard(
                name: trimmedName,
                site: VaultName.trimmed(site).isEmpty ? nil : VaultName.trimmed(site),
                note: nil
            )
            await center.adopt(made)
            card = made
            error = nil
        } catch {
            error = VaultFailure.sentence(error)
        }
    }
}
