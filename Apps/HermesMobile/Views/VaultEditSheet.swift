import HermesAppKit
import HermesKit
import HermeyUI
import SwiftUI

/// Editing one saved secret on the phone: the same sheet the Mac shows, at a different size.
///
/// The value field **starts empty** because this phone has never held the value and the host will not
/// send it: `VaultItem` has no field for one and `PATCH /v1/vault/{name}` answers with a name. So the
/// field is masked, it is cleared the moment the host accepts the edit, and the only thing it is ever
/// fed is what the owner types into it right now.
///
/// *"Leave blank to keep the current value"* is the grammar of the sheet, not a hint: an absent value is
/// what makes a rename-only edit expressible, so a blank field is sent as *no value at all*. Blank means
/// "nothing to store" on a create, which is why this sheet cannot create anything.
struct VaultEditSheet: View {
    /// The row as the host last described it: its name is the path of the request.
    let item: VaultItem
    let model: AppModel
    /// Called once the host has accepted the edit, so the list is re-read rather than redrawn from memory.
    var onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss

    /// The name, prefilled with the one the host reported.
    @State private var name: String
    /// The replacement. Empty, and never seeded from `item`.
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
    /// A rename, a replacement, or both.
    private var hasChange: Bool { trimmedName != item.name || !value.isEmpty }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("openai.main", text: $name)
                        .font(.system(size: TypeScale.md, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("New value (optional)", text: $value)
                } header: {
                    Text("Name and value")
                } footer: {
                    // The host's own rule for a name, and the sheet's rule for the value, in the two
                    // places the owner looks after typing into either field.
                    VStack(alignment: .leading, spacing: 4) {
                        Text(nameIsValid ? "Letters, digits, '.', '_', '-' and one '/'." : VaultName.rule)
                            .foregroundStyle(nameIsValid ? Tokens.textMuted : Tokens.danger)
                        Text("Leave blank to keep the current value.")
                            .foregroundStyle(Tokens.textMuted)
                    }
                }

                if let error {
                    Section {
                        Text(error)
                            .font(TypeScale.font(TypeScale.label))
                            .foregroundStyle(Tokens.danger)
                    }
                }

                Section {
                    Button(saving ? "Saving…" : "Save changes") {
                        Task { await save() }
                    }
                    .disabled(!nameIsValid || !hasChange || saving)
                    .hermeyFocusQuiet()
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Tokens.canvas)
            .navigationTitle("Edit secret")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .hermeyFocusQuiet()
                }
            }
        }
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
            // Nothing came back to keep, and nothing was kept here: the field is cleared before the
            // sheet closes so the value does not outlive the request.
            value = ""
            await onSaved()
            dismiss()
        } catch let failure {
            // `error` here is the property; the catch binding would shadow it.
            error = VaultFailure.refused(failure)
        }
    }
}
