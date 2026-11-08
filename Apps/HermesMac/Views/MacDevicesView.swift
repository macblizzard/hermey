import OpenBotUI
import SwiftUI

/// Management uses its own window so it is available even while the socket is disconnected.
struct MacDevicesView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var devices: [MacPairedDevice] = []
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var pending: MacPairedDevice?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Paired Devices")
                    .font(TypeScale.font(Tokens.textXL, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                OpenBotButton("Refresh",
                              kind: .secondary,
                              size: .small,
                              isDisabled: busy || store.pairing == nil || store.pairing?.isTicketOnly == true) {
                    Task { await refresh() }
                }
            }
            if let address = store.pairing {
                Text("Devices on \(address.displayHost)")
                    .font(TypeScale.font(Tokens.textSM))
                    .foregroundStyle(Tokens.textMuted)
                if address.isTicketOnly {
                    Text("Device management requires a device ID and refresh token. Pair this Mac as a device first.")
                        .font(TypeScale.font(Tokens.textSM))
                        .foregroundStyle(Tokens.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if let error {
                        Text(error)
                            .font(TypeScale.font(TypeScale.caption))
                            .foregroundStyle(Tokens.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if let notice {
                        Text(notice)
                            .font(TypeScale.font(Tokens.textSM))
                            .foregroundStyle(Tokens.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if devices.isEmpty && !busy && error == nil && notice == nil {
                        Text("No devices found.")
                            .font(TypeScale.font(Tokens.textSM))
                            .foregroundStyle(Tokens.textMuted)
                    }
                    List(devices) { device in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name + (device.deviceID == address.deviceID ? " (This Mac)" : ""))
                                    .font(TypeScale.font(Tokens.textMD, weight: .medium))
                                    .foregroundStyle(Tokens.textPrimary)
                                Text("\(device.platform) · \(device.revoked ? "Revoked" : "Active")")
                                    .font(TypeScale.font(TypeScale.caption))
                                    .foregroundStyle(Tokens.textMuted)
                                Text(device.deviceID)
                                    .font(TypeScale.font(TypeScale.micro))
                                    .foregroundStyle(Tokens.textDim)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            OpenBotButton(device.revoked ? "Remove…" : "Revoke…",
                                          kind: .ghost,
                                          size: .small,
                                          isDisabled: busy) { pending = device }
                        }.padding(.vertical, 4)
                    }
                    .scrollContentBackground(.hidden)
                }
            } else {
                Text("Pair a host before managing devices.")
                    .font(TypeScale.font(Tokens.textSM))
                    .foregroundStyle(Tokens.textMuted)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 360)
        .background(Tokens.canvas)
        .preferredColorScheme(.dark)
        .task(id: store.pairing) { await refresh() }
        .confirmationDialog(pending?.revoked == true ? "Permanently remove device?" : "Revoke device?",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible,
                            presenting: pending) { device in
            Button(device.revoked ? "Permanently Remove" : "Revoke", role: .destructive) {
                pending = nil
                Task { await perform(device) }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { device in
            if device.revoked {
                Text("Permanently remove \(device.name) from the host's device list? This cannot be undone.")
            } else if device.deviceID == store.pairing?.deviceID {
                Text("Revoke this Mac? Its connection will close and you will need to pair again to manage devices.")
            } else {
                Text("Revoke \(device.name)? It will be disconnected and must pair again to regain access.")
            }
        }
    }

    @MainActor private func refresh() async {
        guard let address = store.pairing, !address.isTicketOnly else {
            devices = []; error = nil; notice = nil; busy = false; return
        }
        busy = true; error = nil; notice = nil
        defer { if store.pairing == address { busy = false } }
        do {
            let result = try await MacDeviceService(address: address).devices()
            guard !Task.isCancelled, store.pairing == address else { return }
            devices = result
        } catch {
            guard !Task.isCancelled, store.pairing == address else { return }
            devices = []; self.error = "Could not load devices: \(error.localizedDescription)"
        }
    }

    @MainActor private func perform(_ device: MacPairedDevice) async {
        guard let address = store.pairing else { return }
        busy = true; error = nil; notice = nil
        do {
            let service = MacDeviceService(address: address)
            if device.revoked { try await service.removeRevoked(device.deviceID) }
            else { try await service.revoke(device.deviceID) }
            guard store.pairing == address else { busy = false; return }
            if !device.revoked && device.deviceID == address.deviceID {
                devices = []
                notice = "This Mac was revoked. Pair it again to manage devices."
                busy = false
            } else {
                busy = false
                await refresh()
            }
        } catch {
            guard store.pairing == address else { busy = false; return }
            busy = false
            self.error = "Could not \(device.revoked ? "remove" : "revoke") device: \(error.localizedDescription)"
        }
    }
}
