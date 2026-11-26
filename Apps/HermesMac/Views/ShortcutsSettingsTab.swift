import HermesKit
import HermeyUI
import SwiftUI

/// **Settings → Shortcuts**: every key the app answers to, editable, in one place.
///
/// The pane is a *view of the registry* — it iterates `ShortcutRegistry.actions` and draws whatever
/// is there. There is no list of titles in this file, and that is the point: the previous shape of
/// this feature was a shortcut advertised in the ⌘K palette (⌘⌥S) that the menu bar had never bound
/// (⌘S), and a hand-written pane would have been the third copy to disagree.
///
/// **What a row can do.** Press the chip and a combination is recorded into the registry; ⌫ clears
/// the row; the `↺` beside it puts one row back to the app's default; "Restore Defaults" at the
/// bottom puts all of them back. A refusal — macOS owns the combination, or another action already
/// has it — is shown under the row that tried to take it, naming the action it would have shadowed,
/// and nothing is written.
struct ShortcutsSettingsTab: View {
    @ObservedObject var center: ShortcutCenter

    /// The refusal to draw under each row, by action id. Cleared on the next successful change.
    @State private var failures: [String: String] = [:]
    /// The row currently armed for recording. One at a time: a second armed field would make it
    /// ambiguous which one a key press belonged to.
    @State private var recordingID: String?
    /// The modifiers held while recording, for the live "⌘⇧…" preview.
    @State private var preview: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(ShortcutAction.Group.allCases, id: \.self) { group in
                        section(group)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }

            Divider().overlay(Tokens.border)
            footer
        }
        .background(Tokens.canvas)
        .onDisappear { recordingID = nil }
    }

    // MARK: A group

    private func section(_ group: ShortcutAction.Group) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.rawValue.uppercased())
                .font(TypeScale.font(TypeScale.caption, weight: .semibold))
                .foregroundStyle(Tokens.textMuted)
                .padding(.leading, 2)

            VStack(spacing: 0) {
                // The rows *are* the registry, filtered to this group: no title is spelled here.
                let rows = ShortcutRegistry.actions.filter { $0.group == group }
                ForEach(rows) { action in
                    if action.id != rows.first?.id {
                        Divider().overlay(Tokens.border)
                    }
                    row(action)
                }
            }
            .background(Tokens.surface)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                    .strokeBorder(Tokens.border, lineWidth: 1)
            }
        }
    }

    // MARK: A row

    private func row(_ action: ShortcutAction) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(action.title)
                            .font(TypeScale.font(Tokens.textMD, weight: .medium))
                            .foregroundStyle(Tokens.textPrimary)
                        if center.isCustomised(action.id) {
                            // A quiet mark for "this one is not what the app shipped with", so a
                            // glance down the column answers "have I changed anything here?".
                            Circle()
                                .fill(Tokens.accent)
                                .frame(width: 5, height: 5)
                                .help("Changed from the default")
                        }
                    }
                    Text(action.detail)
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                ShortcutKeyChip(combo: center.combo(action.id),
                                isEnabled: action.isRebindable,
                                isRecording: recordingID == action.id,
                                preview: recordingID == action.id ? preview : nil,
                                message: failures[action.id],
                                onCapture: { combo in record(combo, for: action) },
                                onClear: { clear(action) },
                                onCancel: { stopRecording() },
                                onRecordingChanged: { recording in
                                    if recording {
                                        recordingID = action.id
                                        failures[action.id] = nil
                                    } else if recordingID == action.id {
                                        recordingID = nil
                                    }
                                },
                                onPreviewChanged: { text in
                                    if recordingID == action.id { preview = text }
                                })

                resetButton(action)
            }

            if let failure = failures[action.id] {
                Text(failure)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = action.note {
                Text(note)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// One row's way back to the app's default. Disabled when there is nothing to undo, so the
    /// control never implies a change it would not make.
    private func resetButton(_ action: ShortcutAction) -> some View {
        Button {
            center.reset(action.id)
            failures[action.id] = nil
            stopRecording()
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(center.isCustomised(action.id) ? Tokens.textSecondary : Tokens.textDim)
        }
        .buttonStyle(.plain)
        .disabled(!center.isCustomised(action.id))
        .help("Restore \(action.title)'s default")
        .accessibilityLabel("Restore \(action.title)'s default")
        .hermeyFocusQuiet()
    }

    // MARK: The footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Press a field, then the combination. Escape cancels; ⌫ clears a row.")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
                Spacer(minLength: 12)
                Button("Restore Defaults") {
                    center.restoreDefaults()
                    failures.removeAll()
                    stopRecording()
                }
                .disabled(!center.hasCustomisations)
                .hermeyFocusQuiet()
            }
            // The reserved list is read from the registry rather than written out again: the row
            // that refuses ⌘Q and this sentence cannot disagree about what "reserved" means.
            Text("Two actions cannot share a combination — the row that tries says which one already has it. "
                 + "macOS keeps \(ShortcutRegistry.reserved.map(\.label).joined(separator: ", ")) and will not give them up.")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Tokens.canvas)
    }

    // MARK: Recording

    private func record(_ combo: ShortcutCombo, for action: ShortcutAction) {
        recordingID = nil
        preview = nil
        if let rejection = center.set(combo, for: action.id) {
            failures[action.id] = rejection.message
        } else {
            // A success can free a combination another row was refused for; stale refusals would
            // then be describing a state that no longer exists.
            failures.removeAll()
        }
    }

    private func clear(_ action: ShortcutAction) {
        recordingID = nil
        preview = nil
        if let rejection = center.set(nil, for: action.id) {
            failures[action.id] = rejection.message
        } else {
            failures.removeAll()
        }
    }

    private func stopRecording() {
        recordingID = nil
        preview = nil
    }
}

#if DEBUG
#Preview("Shortcuts") {
    ShortcutsSettingsTab(center: ShortcutCenter())
        .frame(width: 820, height: 500)
}
#endif
