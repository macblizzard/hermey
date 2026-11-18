import HermesAppKit
import HermeyUI
import SwiftUI

/// The Mac's local-computer door. Off by default; turning it on dials the bridge from this app and
/// keeps that single socket alive. Turning it off drops the socket; the bin revokes it on the host too.
struct LocalComputerSettingsView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject private var service = LocalComputerService.shared
    @StateObject private var permissions = ComputerPermissions()
    @State private var confirmingRevoke = false

    private var pairedAddress: PairingAddress? { store.pairing }

    var body: some View {
        Form {
            Section {
                Toggle("Let bots use this computer", isOn: Binding(
                    get: { service.isEnabled },
                    set: { service.setEnabled($0, address: pairedAddress) }
                ))
                .tint(Tokens.accent)

                HStack(spacing: 8) {
                    Text(Host.current().localizedName ?? "This Mac")
                        .font(TypeScale.font(TypeScale.sm))
                        .foregroundStyle(Tokens.textPrimary)
                    Text(service.status == .connected ? "Connected" : service.status.rawValue.capitalized)
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(service.status == .connected ? Tokens.success : Tokens.textMuted)
                    Spacer(minLength: 6)
                    Button(role: .destructive) { confirmingRevoke = true } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .disabled(pairedAddress == nil)
                    .help("Revoke this Mac's local access on the host")
                }
                .padding(.leading, 18)

                if let error = service.lastError {
                    Text(error)
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 18)
                }
            } header: {
                Text("Computers")
            } footer: {
                Text("Local execution runs commands under your macOS account from this app. No SSH or Remote Login is needed, and the app must be running. Commands run only while this switch is on.")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
            }

            Section {
                ForEach(ComputerPermission.allCases) { permission in
                    let state = permissions.states[permission]
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(permission.title)
                                .font(TypeScale.font(TypeScale.sm))
                                .foregroundStyle(Tokens.textPrimary)
                            Text(state?.label ?? "Checking…")
                                .font(TypeScale.font(TypeScale.caption))
                                .foregroundStyle(state?.granted == true ? Tokens.success
                                                 : state?.granted == false ? Tokens.danger
                                                 : Tokens.textMuted)
                            Spacer(minLength: 6)
                            if permission != .accessibility {
                                Button("Check") { permissions.check(permission) }
                                    .controlSize(.small)
                            }
                            Button(permission == .accessibility ? "Request Access" : "Open Settings") {
                                permissions.request(permission)
                            }
                            .controlSize(.small)
                        }
                        Text(permission.detail)
                            .font(TypeScale.font(TypeScale.caption))
                            .foregroundStyle(Tokens.textMuted)
                        if let note = state?.note, !note.isEmpty {
                            Text(note)
                                .font(TypeScale.font(TypeScale.caption))
                                .foregroundStyle(Tokens.textMuted)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Hermey is ad-hoc signed, so macOS may ask again after an app update. Accessibility has a system prompt; the other three are switches in System Settings › Privacy & Security.")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
            }

            if service.commandsRun > 0 {
                Section("Activity") {
                    Text("\\(service.commandsRun) command(s) run this session")
                        .font(TypeScale.font(TypeScale.caption))
                    if let command = service.lastCommand {
                        Text(command)
                            .font(TypeScale.font(TypeScale.caption))
                            .foregroundStyle(Tokens.textMuted)
                            .lineLimit(2)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Tokens.canvas)
        .task {
            if service.isEnabled { service.setEnabled(true, address: pairedAddress) }
        }
        .onChange(of: store.pairing) { _, address in service.pairingChanged(address: address) }
        .confirmationDialog("Revoke this Mac?", isPresented: $confirmingRevoke, titleVisibility: .visible) {
            Button("Revoke", role: .destructive) {
                Task { await service.revoke(address: pairedAddress) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The host will close this Mac's socket and refuse it until you switch access back on.")
        }
    }
}
