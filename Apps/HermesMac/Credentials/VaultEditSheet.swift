import HermesAppKit
import HermesKit
import HermeyUI
import SwiftUI

/// Editing one saved secret: a new name, and — only when the owner types one — a replacement value.
///
/// This sheet is the one place in the vault that accepts a value for something that already exists, so it
/// follows the store's rules rather than inventing its own. The field **starts empty**: there is nothing
/// to prefill it with, because `VaultItem` has no value, no route returns one, and the host answers an
/// edit with the item's new name alone. It is masked, it is cleared the moment the host accepts the edit,
/// and it is never read back on this side — there is no code here that could show what is stored.
///
/// *"Leave blank to keep the current value"* is the grammar of the sheet, not a hint: an absent value is
/// what makes a rename-only edit expressible, so a blank field is sent as *no value at all* rather than
/// as an empty string. Blank still means "nothing to store" on a create, which is why this sheet cannot
/// create anything — that is `VaultAddSheet`, through the credential card's own card.
struct VaultEditSheet: View {
    /// The row as the host last described it. Its name is the path of the request and the thing a rename
    /// moves away from; its labels are shown, never edited.
    let item: VaultItem
    let model: AppModel
    /// Called once the host has accepted the edit, so the pane re-reads instead of drawing a stale row.
    var onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss

    /// The name, prefilled with the one the host reported: a rename is an edit of this field alone.
    @State private var name: String
    /// The replacement. Empty, and never seeded from `item` — there is nothing in `item` to seed it with.
    @State private var value = ""
    @State private var saving = false
    @State private var error: String?

    init(item: VaultItem, model: AppModel, onSaved: @escaping () async -> Void) {
        self.item = item
        self.model = model
        self.onSaved = onSaved
        _name = State(initialValue: item.name)
    }

    private var trimmedName: String { VaultName.trimmed(name) }
    private var nameIsValid: Bool { VaultName.isValid(trimmedName) }
    /// A rename, a replacement, or both — the three things this sheet can actually ask the host for.
    private var hasChange: Bool { trimmedName != item.name || !value.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(Tokens.accent)
                Text("Edit secret")
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
                // The host's own pattern, checked here first: a name that could never be stored is refused
                // before a value is typed against it.
                Text(nameIsValid ? "Letters, digits, '.', '_', '-' and one '/'." : VaultName.rule)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(nameIsValid ? Tokens.textMuted : Tokens.danger)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("New value")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
                SecureField("New value (optional)", text: $value)
                    .textFieldStyle(.roundedBorder)
                Text("Leave blank to keep the current value.")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
            }

            if let error {
                Text(error)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .hermeyFocusQuiet()
                Button(saving ? "Saving…" : "Save changes") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                // Nothing to change is not a save: the host would refuse it, and a disabled button says
                // so before the round trip.
                .disabled(!nameIsValid || !hasChange || saving)
                .hermeyFocusQuiet()
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await model.editVaultItem(
                name: item.name,
                rename: trimmedName,
                // Absent, not empty: blank means "keep what is stored".
                value: value.isEmpty ? nil : value
            )
            // Nothing came back to keep, and nothing was ever kept on this side: the field is cleared
            // before the sheet closes so the value does not outlive the request.
            value = ""
            await onSaved()
            dismiss()
        } catch let failure {
            // `error` here is the property; the catch binding would shadow it and cannot be assigned.
            error = VaultFailure.refused(failure)
        }
    }
}
