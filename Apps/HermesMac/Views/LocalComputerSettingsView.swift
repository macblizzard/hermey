import HermesAppKit
import HermeyUI
import SwiftUI

/// The Mac's local-computer door. Off by default; turning it on dials the bridge from this app and
/// keeps that single socket alive. Turning it off drops the socket; the bin revokes it on the host too.
struct LocalComputerSettingsView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject private var service = LocalComputerService.shared
    @ObservedObject private var takeover = ComputerTakeover.shared
    @StateObject private var permissions = ComputerPermissions()
    @State private var confirmingRevoke = false
    @ObservedObject private var launchAtLogin = LaunchAtLogin.shared

    private var pairedAddress: PairingAddress? { store.pairing }

    /// The row's state word. "Unavailable" is a separate answer from "not installed" on purpose: the
    /// owner should be able to tell a host that disagrees from a host that did not reply.
    private var skillLabel: String {
        guard service.skillChecked else { return "Checking…" }
        guard let skill = service.skill else { return "Unavailable" }
        if skill.ownedByTheUser { return "Yours" }
        if skill.upToDate { return "Installed" }
        return skill.present ? "Update available" : "Not installed"
    }

    private var skillTint: Color {
        guard let skill = service.skill else { return Tokens.textMuted }
        if skill.ownedByTheUser { return Tokens.textMuted }
        if skill.upToDate { return Tokens.success }
        return skill.present ? Tokens.warning : Tokens.textMuted
    }

    var body: some View {
        Form {
            Section {
                Toggle("Let bots use this computer", isOn: Binding(
                    get: { service.isEnabled },
                    set: { on in
                        if on {
                            // Switching this on is also the answer to a revoke, so ask the host to
                            // lift it before dialling. Without this the trash button was a one-way
                            // door: the socket re-dialled into a rejected handshake for ever, and
                            // the switch appeared to do nothing (reported 2026-11-19).
                            Task {
                                await service.allow(address: pairedAddress)
                                service.setEnabled(true, address: pairedAddress)
                            }
                        } else {
                            service.setEnabled(false, address: pairedAddress)
                        }
                    }
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
                            // Every row gets Check, Accessibility included. It was left out because
                            // granting that one happens in System Settings and the app only learns
                            // of it on the next probe — which is exactly why a Check button belongs
                            // there: it is the only way to tell whether the grant landed without
                            // quitting and relaunching. `check(.accessibility)` re-reads
                            // AXIsProcessTrusted, so the row answers honestly.
                            Button("Check") { permissions.check(permission) }
                                .controlSize(.small)
                            Button(permission == .accessibility ? "Request Access" : "Open Settings") {
                                permissions.request(permission)
                            }
                            .controlSize(.small)
                        }
                        Text(permission.detail)
                            .font(TypeScale.font(TypeScale.caption))
                            .foregroundStyle(Tokens.textMuted)
                        if let note = state?.note, !note.isEmpty, note != state?.label {
                            // A note that only repeats the status ("On first use") drew the same
                            // words twice on the row.
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

            Section {
                HStack(spacing: 8) {
                    Text("Bot instructions")
                        .font(TypeScale.font(TypeScale.sm))
                        .foregroundStyle(Tokens.textPrimary)
                    Text(skillLabel)
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(skillTint)
                    Spacer(minLength: 6)
                    Button(service.skill?.present == true ? "Reinstall" : "Install") {
                        Task { await service.installSkill(address: pairedAddress) }
                    }
                    .controlSize(.small)
                    .disabled(pairedAddress == nil || service.skillBusy)
                    .help("Re-run the host's installer for the skill your agents read")
                }

                if let skill = service.skill, skill.present, !skill.version.isEmpty {
                    Text("mac-local-computer \(skill.version)")
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.textMuted)
                        .padding(.leading, 18)
                }

                if let skill = service.skill, skill.present, !skill.cliPresent {
                    Text("The command line the skill points at is missing on the host.")
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.danger)
                        .padding(.leading, 18)
                }
            } header: {
                Text("Agents")
            } footer: {
                Text("Every agent on the host gets a mac-local-computer skill, so it knows how to reach this Mac without being told. The host writes it on each start; this button only re-runs that.")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
            }

            Section {
                Toggle("Open Hermey at login", isOn: Binding(
                    get: { launchAtLogin.status.toggleIsOn },
                    set: { launchAtLogin.set($0) }
                ))
                .tint(Tokens.accent)
                .accessibilityIdentifier("computerOpenAtLogin")

                // The row reports what macOS did, not what the click asked for: registration can land
                // in "needs approval" or be refused outright on a build the system will not accept.
                Text(launchAtLogin.status.detail)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if launchAtLogin.status.offersApproval {
                    Button("Open Login Items in System Settings") {
                        launchAtLogin.openLoginItemsSettings()
                    }
                    .controlSize(.small)
                }
            } header: {
                Text("Startup")
            } footer: {
                Text("A login item starts the app after a restart so computer use comes back without you opening it. It cannot wake a sleeping Mac: launchd runs nothing while macOS is asleep, and the wake has to come from a Wake-on-LAN packet or a Bonjour sleep proxy on your network — neither of which an app can arrange for itself.")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
            }

            Section("Activity") {
                if takeover.active {
                    HStack(spacing: 8) {
                        Image(systemName: "hand.raised")
                            .foregroundStyle(Tokens.warning)
                        Text("Bot control paused by your input")
                            .font(TypeScale.font(TypeScale.sm))
                            .foregroundStyle(Tokens.textPrimary)
                        Spacer(minLength: 6)
                        Button("Resume") {
                            service.resumeAfterTakeover()
                        }
                        .controlSize(.small)
                    }
                }

                if service.isCommandRunning {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Running")
                            .font(TypeScale.font(TypeScale.caption))
                            .foregroundStyle(Tokens.textMuted)
                        Text(service.liveOutput.isEmpty ? "…" : service.liveOutput)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(Tokens.textSecondary)
                            .lineLimit(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if service.recentActivity.isEmpty {
                    Text("No commands yet this session")
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.textMuted)
                } else {
                    ForEach(service.recentActivity.suffix(12).reversed()) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(item.kind)
                                    .font(TypeScale.font(TypeScale.caption))
                                    .foregroundStyle(Tokens.textPrimary)
                                Text(item.outcome)
                                    .font(TypeScale.font(TypeScale.caption))
                                    .foregroundStyle(item.outcome == "ok" || item.outcome == "resumed"
                                                     ? Tokens.success : Tokens.danger)
                                Spacer(minLength: 6)
                                if let duration = item.durationMS {
                                    Text("\(duration) ms")
                                        .font(TypeScale.font(TypeScale.caption))
                                        .foregroundStyle(Tokens.textMuted)
                                }
                            }
                            Text(item.summary)
                                .font(TypeScale.font(TypeScale.caption))
                                .foregroundStyle(Tokens.textMuted)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Tokens.canvas)
        .task {
            // Idempotent: this `.task` runs on every appearance, and re-dialling here cancelled a
            // live socket each time Settings came back.
            if service.isEnabled { service.ensureRunning(address: pairedAddress) }
            await service.refreshSkill(address: pairedAddress)
        }
        .onChange(of: store.pairing) { _, address in
            service.pairingChanged(address: address)
            Task { await service.refreshSkill(address: address) }
        }
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
