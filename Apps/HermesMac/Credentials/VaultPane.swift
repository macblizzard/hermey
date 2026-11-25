import HermesAppKit
import HermesKit
import HermeyUI
import SwiftUI

/// Settings → Vault: the secrets the host holds, by name.
///
/// What this pane is *for*: the owner asked to see what is in the host's vault, add one, and remove one,
/// without any way to read a value back out of it. So the pane lists names and labels only. `VaultItem`
/// (Sources/HermesKit/VaultItems.swift) has no field for a value, there is no reveal control here or
/// anywhere else, and nothing on this screen copies a secret to the pasteboard.
///
/// Adding is not a form of its own: "Add a secret" asks the host for a `store`-mode credential card and
/// then presents `CredentialCardSheet` — the same sheet a bot's card opens — so the one masked field the
/// owner types into is the one that already existed. That keeps a single path into the vault.
struct VaultSettingsTab: View {
    @ObservedObject var store: WorkspaceStore

    /// `nil` means "not read yet", which is why the pane can tell a host it could not reach from an
    /// empty vault: an empty vault is `[]`, and a failure is `failure` with `items` left alone.
    @State private var items: [VaultItem]?
    @State private var failure: String?
    @State private var pendingDelete: VaultItem?
    @State private var actionError: String?
    @State private var showAdd = false

    private var model: AppModel { store.model }

    var body: some View {
        Form {
            Section {
                content
            } header: {
                Text("Vault")
            } footer: {
                Text("Secrets your bots use, kept on this host. A value is written once and never shown "
                     + "again — not here, not in a chat. A bot can ask to use one by name.")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
            }

            if let actionError {
                Section {
                    Text(actionError)
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.danger)
                }
            }

            Section {
                Button {
                    showAdd = true
                } label: {
                    Label("Add a secret", systemImage: "plus")
                }
                .hermeyFocusQuiet()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Tokens.canvas)
        .task { await load() }
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
            Text("\"\(pendingDelete?.name ?? "")\" is removed from the host's vault. Anything that uses it "
                 + "will need it saved again.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let failure {
            // Never the empty state: a broken connection and a vault with nothing in it are different
            // facts, and this pane has to say which one it is looking at.
            VStack(alignment: .leading, spacing: 8) {
                Label("The vault could not be read", systemImage: "exclamationmark.triangle")
                    .font(TypeScale.font(TypeScale.md, weight: .medium))
                    .foregroundStyle(Tokens.danger)
                Text(failure)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { Task { await load() } }
                    .hermeyFocusQuiet()
            }
            .padding(.vertical, 4)
        } else if items == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the vault…")
                    .font(TypeScale.font(TypeScale.md))
                    .foregroundStyle(Tokens.textMuted)
            }
        } else if let items, items.isEmpty {
            Text("Nothing is saved yet. Add a secret and any bot can ask to use it by name.")
                .font(TypeScale.font(TypeScale.md))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        } else if let items {
            ForEach(items) { item in
                row(item)
            }
        }
    }

    /// One saved secret. Name, where it is for, when it was added — and a delete. There is no reveal
    /// control and no value on this line, by design.
    private func row(_ item: VaultItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: TypeScale.md, design: .monospaced))
                    .foregroundStyle(Tokens.textPrimary)
                    .textSelection(.enabled)
                Text(detail(item))
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
            }
            Spacer(minLength: 8)
            Button {
                pendingDelete = item
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(Tokens.danger)
            }
            .buttonStyle(.borderless)
            .help("Delete \(item.name)")
            .hermeyFocusQuiet()
        }
        .padding(.vertical, 2)
    }

    /// "for api.openai.com · added 3 Nov" — and nothing about the value, which the app does not have.
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
            // The old rows are dropped: showing a stale list beside "could not be read" would invite
            // the owner to delete something the pane is not currently sure about.
            items = nil
            failure = VaultFailure.sentence(error)
        }
    }

    private func delete(_ item: VaultItem) async {
        do {
            try await model.deleteVaultItem(name: item.name)
            actionError = nil
        } catch {
            // 404 or 409 — the host refused, so say so rather than redrawing as if it worked.
            actionError = VaultFailure.sentence(error)
        }
        await load()
    }
}

/// Adding one secret: the name, where it is for, and then the existing masked sheet for the value.
///
/// The two steps are deliberate. A name is a label — the host validates it with the same pattern it uses
/// for every other name, and the pane checks it first so nobody types a value into a form whose name was
/// never going to be accepted. The value is typed into `CredentialCardSheet`, which is the credential
/// card's own view, unchanged: no second masked form exists.
struct VaultAddSheet: View {
    let model: AppModel
    /// Called once the host has the value, so the pane can re-read instead of leaving a stale list.
    var onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var center = CredentialCardCenter()

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
                // The same sheet a bot's card opens. The value only ever exists in its `SecureField`.
                CredentialCardSheet(card: card, model: model, center: center)
            } else {
                details
            }
        }
        .frame(width: 380)
        .onChange(of: center.card?.id) { _, next in
            // The sheet clears its card the moment the host accepts the answer — that is the signal
            // the value reached the vault.
            guard card != nil, next == nil else { return }
            Task {
                await onSaved()
                dismiss()
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(Tokens.accent)
                Text("Add a secret")
                    .font(.headline)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
                TextField("openai.main", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                // The host's own pattern, checked here first: a name that could never be stored is
                // refused before there is a value to type into it.
                Text(name.isEmpty || nameIsValid ? "Letters, digits, '.', '_', '-' and one '/'."
                                                 : VaultName.rule)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(name.isEmpty || nameIsValid ? Tokens.textMuted : Tokens.danger)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Where it is for (optional)")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
                TextField("api.openai.com", text: $site)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            if let error {
                Text(error)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.danger)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .hermeyFocusQuiet()
                Button(creating ? "Opening…" : "Continue") {
                    Task { await askForCard() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!nameIsValid || creating)
                .hermeyFocusQuiet()
            }
        }
        .padding(20)
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
