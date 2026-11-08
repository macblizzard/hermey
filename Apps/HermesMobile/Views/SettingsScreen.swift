import SwiftUI
import HermesKit
import HermesAppKit
import OpenBotUI

/// Settings holds settings.
///
/// Four sections, in the order the contract fixes (`docs/ENDLESS-CHAT.md` §4): the
/// connection, how the chat behaves, the devices the host will still talk to, and what this
/// build is. Device management is one row that opens its own screen — it used to be twenty
/// rows of toggles on this page, which buried the three settings anyone actually changes.
struct SettingsScreen: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var app: AppEnvironment

    /// The threshold is edited as text and committed on Enter or focus loss: writing every
    /// keystroke to `autoCompactTokens` would compact the thread mid-typing and would make
    /// a half-typed "20000" behave like "2".
    @FocusState private var thresholdFocused: Bool
    @State private var thresholdText: String = MobileTokens.digits(AppModel.defaultAutoCompactTokens)
    @State private var showUnpairConfirm = false

    /// Appearance: the same catalogue and the same swatches the Mac's Settings draws.
    private var appearanceSection: some View {
        Section("Appearance") {
            ThemePicker()
                .padding(.vertical, 4)
                .listRowBackground(Tokens.surface)
        }
    }

    var body: some View {
        List {
            connectionSection
            appearanceSection
            chatSection
            devicesSection
            aboutSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Tokens.canvas)
        .navigationTitle("Settings")
        .toolbar {
            // A number pad has no Return key, so the field needs an explicit way out —
            // leaving it is what commits the threshold.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { thresholdFocused = false }
            }
        }
        .task { await app.loadDevices() }
        .mobileConnectionBanner(connection: app.visibleConnection,
                                turnRunning: model.isStreaming,
                                host: app.hostLabel,
                                retry: { Task { await app.reconnect() } })
        .confirmationDialog("Unpair this phone?",
                            isPresented: $showUnpairConfirm,
                            titleVisibility: .visible) {
            Button("Unpair", role: .destructive) {
                Task { await app.unpair() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The refresh token is deleted from this phone. The device stays in the host's list until you revoke it there.")
        }
        .onAppear { syncThreshold() }
        .onChange(of: model.autoCompactTokens) { _ in syncThreshold() }
        .onChange(of: thresholdFocused) { focused in
            if !focused { commitThreshold() }
        }
    }

    // MARK: Connection

    /// Host, state, latency — the three facts that explain whether a message will get
    /// through — then the two ways to change that: drop the socket, or pair this phone again.
    @ViewBuilder
    private var connectionSection: some View {
        Section {
            if let host = app.store.host {
                hostRow(host)

                LabeledContent {
                    Text(app.visibleConnection.label)
                        .foregroundStyle(connectionTint)
                        .monospacedDigit()
                } label: {
                    Text("State").font(TypeScale.font(TypeScale.md))
                }

                LabeledContent {
                    Text(latencyText)
                        .foregroundStyle(Tokens.textGroupedSecondary)
                        .monospacedDigit()
                } label: {
                    Text("Latency").font(TypeScale.font(TypeScale.md))
                }

                Button {
                    Haptics.impact()
                    Task { await app.disconnect() }
                } label: {
                    Label("Disconnect", systemImage: "bolt.horizontal.circle")
                        .font(TypeScale.font(TypeScale.md))
                        .foregroundStyle(model.connection.isLive ? Tokens.accentText : Tokens.textDim)
                }
                .disabled(!model.connection.isLive)

                Button {
                    app.isPairingPresented = true
                } label: {
                    Label("Re-pair this phone", systemImage: "qrcode.viewfinder")
                        .font(TypeScale.font(TypeScale.md))
                        .foregroundStyle(Tokens.accentText)
                }

                Button(role: .destructive) {
                    showUnpairConfirm = true
                } label: {
                    Label("Unpair this phone", systemImage: "iphone.slash")
                        .font(TypeScale.font(TypeScale.md))
                }
            } else {
                Button {
                    app.isPairingPresented = true
                } label: {
                    Label("Pair a host", systemImage: "link.badge.plus")
                        .font(TypeScale.font(TypeScale.md))
                        .foregroundStyle(Tokens.accentText)
                }
            }
        } header: {
            sectionHeader("Connection")
        } footer: {
            Text(app.isPaired
                 ? "Disconnecting closes the socket but keeps this phone paired — Retry in the banner reconnects. Re-pair only when the host revoked this phone or moved."
                 : "Nothing is paired yet. Pair the phone with the bridge running on your Hermes host.")
                .font(TypeScale.font(TypeScale.label))
        }
    }

    private func hostRow(_ host: PairedHost) -> some View {
        HStack(spacing: 12) {
            Avatar(host.host, size: .large, presence: model.connection.isLive ? .running : .idle)

            VStack(alignment: .leading, spacing: 3) {
                Text(host.host)
                    .font(TypeScale.font(TypeScale.md, weight: .medium))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)

                Text("\(host.deviceName) · paired \(RelativeTime.short(host.pairedAt))")
                    .font(TypeScale.font(TypeScale.label))
                    .foregroundStyle(Tokens.textGroupedSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    /// Only the states the host can actually be in; `.idle` means "we stopped trying", which
    /// is what Disconnect leaves behind.
    private var connectionTint: Color {
        switch model.connection {
        case .connected: return Tokens.success
        case .connecting, .reconnecting: return Tokens.warning
        case .failed: return Tokens.danger
        case .offline, .idle: return Tokens.textGroupedSecondary
        }
    }

    private var latencyText: String {
        guard let rtt = app.effectiveRTT else { return "—" }
        return "\(rtt) ms"
    }

    // MARK: Chat

    private var chatSection: some View {
        Section {
            HStack(spacing: 8) {
                Text("Auto-compact after")
                    .font(TypeScale.font(TypeScale.md))
                    .foregroundStyle(Tokens.textPrimary)

                Spacer(minLength: 8)

                TextField("Off", text: $thresholdText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 15, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Tokens.textPrimary)
                    .focused($thresholdFocused)
                    .frame(maxWidth: 116)
                    .submitLabel(.done)
                    .onSubmit { commitThreshold() }
                    .accessibilityLabel("Auto-compact threshold, in tokens")

                Text("tokens")
                    .font(TypeScale.font(TypeScale.label))
                    .foregroundStyle(Tokens.textGroupedSecondary)
            }

            if model.autoCompactTokens > 0 {
                Button {
                    Haptics.selection()
                    setThreshold(0)
                } label: {
                    Text("Turn off")
                        .font(TypeScale.font(TypeScale.md))
                        .foregroundStyle(Tokens.accentText)
                }
            } else {
                Button {
                    Haptics.selection()
                    setThreshold(AppModel.defaultAutoCompactTokens)
                } label: {
                    Text("Turn on (\(MobileTokens.short(AppModel.defaultAutoCompactTokens)) tokens)")
                        .font(TypeScale.font(TypeScale.md))
                        .foregroundStyle(Tokens.accentText)
                }
            }

            Toggle(isOn: $model.showReasoning) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show reasoning")
                        .font(TypeScale.font(TypeScale.md))
                        .foregroundStyle(Tokens.textPrimary)
                    Text("The model's thinking, above each answer.")
                        .font(TypeScale.font(TypeScale.label))
                        .foregroundStyle(Tokens.textGroupedSecondary)
                }
            }
            .tint(Tokens.success)

            Toggle(isOn: $model.reasoningExpandedByDefault) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Expand reasoning automatically")
                        .font(TypeScale.font(TypeScale.md))
                        .foregroundStyle(Tokens.textPrimary)
                    Text("Open the model's thinking on arrival instead of a tap.")
                        .font(TypeScale.font(TypeScale.label))
                        .foregroundStyle(Tokens.textGroupedSecondary)
                }
            }
            .tint(Tokens.success)

            Toggle(isOn: $model.showToolOutput) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show tool output")
                        .font(TypeScale.font(TypeScale.md))
                        .foregroundStyle(Tokens.textPrimary)
                    Text("Expandable results under each tool call.")
                        .font(TypeScale.font(TypeScale.label))
                        .foregroundStyle(Tokens.textGroupedSecondary)
                }
            }
            .tint(Tokens.success)
        } header: {
            sectionHeader("Chat")
        } footer: {
            Text(model.autoCompactTokens > 0
                 ? "After a turn leaves \(MobileTokens.short(model.autoCompactTokens)) tokens in the context, this thread is compacted in place. A blank field or 0 turns it off."
                 : "Auto-compaction is off. The conversation grows until the host refuses a turn; the header still shows how full the context is.")
                .font(TypeScale.font(TypeScale.label))
        }
    }

    /// The field is the source of truth while focused, the model's value otherwise. Off is
    /// drawn as an empty field with the "Off" placeholder, not as a literal `0`: the number
    /// and the word mean the same thing, and the word is the one that reads as a state.
    private func syncThreshold() {
        let text = model.autoCompactTokens > 0 ? MobileTokens.digits(model.autoCompactTokens) : ""
        if text != thresholdText { thresholdText = text }
    }

    /// Blank means off: a user who cleared the field is saying "stop doing this", not
    /// "compact at zero tokens".
    private func commitThreshold() {
        let digits = thresholdText.filter(\.isNumber)
        setThreshold(Int(digits) ?? 0)
    }

    private func setThreshold(_ value: Int) {
        let tokens = max(0, value)
        model.autoCompactTokens = tokens
        thresholdText = tokens > 0 ? MobileTokens.digits(tokens) : ""
        thresholdFocused = false
    }

    // MARK: Devices

    /// One row. The list itself lives on its own screen; it is reference material, not a
    /// setting.
    private var devicesSection: some View {
        Section {
            NavigationLink {
                DevicesScreen()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Tokens.textMuted)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.radiusSmall, style: .continuous)
                                .fill(Tokens.control)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Devices")
                            .font(TypeScale.font(TypeScale.md))
                            .foregroundStyle(Tokens.textPrimary)

                        Text(devicesDetail)
                            .font(TypeScale.font(TypeScale.label))
                            .foregroundStyle(Tokens.textGroupedSecondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            sectionHeader("Devices")
        } footer: {
            Text("Every device the host still accepts. Revoking one is permanent.")
                .font(TypeScale.font(TypeScale.label))
        }
    }

    private var devicesDetail: String {
        guard app.isPaired else { return "Pair this phone first" }
        if app.devicesLoading && app.devices.isEmpty { return "Loading…" }
        let active = app.devices.filter { !$0.revoked }.count
        if app.devices.isEmpty { return "None listed by the host" }
        return active == 1 ? "1 device with access" : "\(active) devices with access"
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            LabeledContent {
                Text(bundleValue("CFBundleShortVersionString"))
                    .foregroundStyle(Tokens.textGroupedSecondary)
                    .monospacedDigit()
            } label: {
                Text("Version").font(TypeScale.font(TypeScale.md))
            }

            LabeledContent {
                Text(bundleValue("CFBundleVersion"))
                    .foregroundStyle(Tokens.textGroupedSecondary)
                    .monospacedDigit()
            } label: {
                Text("Build").font(TypeScale.font(TypeScale.md))
            }

            LabeledContent {
                Text(protocolText)
                    .foregroundStyle(Tokens.textGroupedSecondary)
                    .monospacedDigit()
            } label: {
                Text("Protocol").font(TypeScale.font(TypeScale.md))
            }
        } header: {
            sectionHeader("About")
        } footer: {
            Text("Version and build come from this app's bundle; the protocol version is the one this phone claimed when it paired.")
                .font(TypeScale.font(TypeScale.label))
        }
    }

    /// `nil` when the key is missing (a preview or a test host), which is printed as "—"
    /// rather than a number this build does not have.
    private func bundleValue(_ key: String) -> String {
        guard let value = Bundle.main.infoDictionary?[key] as? String,
              !value.trimmingCharacters(in: .whitespaces).isEmpty else { return "—" }
        return value
    }

    /// `0` on the host side means "not reported", so it is not printed as a version.
    private var protocolText: String {
        guard let version = app.store.host?.protocolVersion, version > 0 else { return "—" }
        return "\(version)"
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(TypeScale.font(TypeScale.label))
            .foregroundStyle(Tokens.textGroupedSecondary)
            .textCase(nil)
    }
}

// MARK: - Devices

/// The device list, one screen down.
///
/// Revoking is one-way on the bridge, so the toggle is guarded by a confirmation and the row
/// lands in a revoked state rather than pretending it can be switched back on.
struct DevicesScreen: View {
    @EnvironmentObject private var app: AppEnvironment

    @State private var allowedOverrides: [String: Bool] = [:]
    @State private var pendingRevoke: PairedDevice?
    @State private var showRevokeConfirm = false
    @State private var pendingRemoval: PairedDevice?
    @State private var showRemovalConfirm = false

    /// Appearance: the same catalogue and the same swatches the Mac's Settings draws.
    private var appearanceSection: some View {
        Section("Appearance") {
            ThemePicker()
                .padding(.vertical, 4)
                .listRowBackground(Tokens.surface)
        }
    }

    var body: some View {
        List {
            Section {
                if let error = app.devicesError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(TypeScale.font(TypeScale.label))
                        .foregroundStyle(Tokens.danger)
                        .padding(.vertical, 2)
                }

                ForEach(app.devices) { device in
                    deviceRow(device)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if device.revoked {
                                Button("Remove", role: .destructive) {
                                    pendingRemoval = device
                                    showRemovalConfirm = true
                                }
                                .disabled(app.removingDevice || app.store.host == nil)
                            }
                        }
                }

                if app.devices.isEmpty {
                    if app.devicesLoading {
                        HStack(spacing: 8) {
                            SpinningRing(color: Tokens.textMuted, size: 11, lineWidth: 1.5)
                            Text("Loading devices…")
                                .font(TypeScale.font(TypeScale.md))
                                .foregroundStyle(Tokens.textMuted)
                        }
                    } else {
                        Text(app.isPaired ? "The host listed no devices." : "Pair this phone to see its devices.")
                            .font(TypeScale.font(TypeScale.md))
                            .foregroundStyle(Tokens.textMuted)
                    }
                }
            } footer: {
                Text("Turning a device off revokes it on the host. That cannot be undone — pair it again to give it access. Swipe a revoked device to remove its record.")
                    .font(TypeScale.font(TypeScale.label))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Tokens.canvas)
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await app.loadDevices() }
        .task { await app.loadDevices() }
        .confirmationDialog(revokeTitle,
                            isPresented: $showRevokeConfirm,
                            titleVisibility: .visible) {
            Button("Revoke", role: .destructive) { confirmRevoke() }
            Button("Keep access", role: .cancel) { restorePendingToggle() }
        } message: {
            Text("The host deletes this device's refresh token immediately, and any open websocket ticket stops working.")
        }
        .onChange(of: showRevokeConfirm) { presented in
            if !presented { restorePendingToggle() }
        }
        .confirmationDialog(pendingRemoval.map { "Remove \($0.name)?" } ?? "Remove this device?",
                            isPresented: $showRemovalConfirm,
                            titleVisibility: .visible) {
            Button("Remove device", role: .destructive) {
                guard let device = pendingRemoval else { return }
                pendingRemoval = nil
                Task { await app.removeRevoked(device) }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("Permanently remove this revoked device's record from the host. This does not remove any other devices.")
        }
    }

    private func deviceRow(_ device: PairedDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: device.platform.lowercased() == "ios" ? "iphone" : "desktopcomputer")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(device.revoked ? Tokens.textDim : Tokens.textMuted)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusSmall, style: .continuous)
                        .fill(Tokens.control)
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(TypeScale.font(TypeScale.md))
                        .foregroundStyle(device.revoked ? Tokens.textDim : Tokens.textPrimary)
                        .lineLimit(1)

                    if device.deviceID == app.store.host?.deviceID {
                        StatusChip("this phone", tone: .accent, size: .small)
                    }
                }

                Text(subtitle(for: device))
                    .font(TypeScale.font(TypeScale.label))
                    .foregroundStyle(Tokens.textGroupedSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: allowedBinding(for: device))
                .labelsHidden()
                .tint(Tokens.success)
                .disabled(device.revoked || app.store.host == nil)
                .accessibilityLabel("\(device.name) has access")
                .accessibilityHint("Turning this off revokes the device on the host")
        }
        .padding(.vertical, 2)
    }

    private func subtitle(for device: PairedDevice) -> String {
        if device.revoked { return "Revoked" }
        let platform = device.platformLabel
        if let seen = device.lastSeenAt {
            return "\(platform) · seen \(RelativeTime.short(seen))"
        }
        return platform
    }

    private func allowedBinding(for device: PairedDevice) -> Binding<Bool> {
        Binding(get: {
            allowedOverrides[device.deviceID] ?? !device.revoked
        }, set: { wantsAccess in
            guard !wantsAccess, !device.revoked else {
                allowedOverrides[device.deviceID] = nil
                return
            }
            Haptics.selection()
            allowedOverrides[device.deviceID] = false
            pendingRevoke = device
            showRevokeConfirm = true
        })
    }

    private var revokeTitle: String {
        guard let device = pendingRevoke else { return "Revoke this device?" }
        return "Revoke \(device.name)?"
    }

    private func confirmRevoke() {
        guard let device = pendingRevoke else { return }
        pendingRevoke = nil
        Task {
            await app.revoke(device)
            // Either way the override goes: a revoked row reads its own state, a failed
            // revoke reads `false` again and the toggle springs back on.
            allowedOverrides[device.deviceID] = nil
        }
    }

    private func restorePendingToggle() {
        guard let device = pendingRevoke else { return }
        allowedOverrides[device.deviceID] = nil
        pendingRevoke = nil
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Settings · paired") {
    let environment = AppEnvironment.preview()
    NavigationStack {
        SettingsScreen(model: environment.model)
    }
    .environmentObject(environment)
    .preferredColorScheme(.dark)
    .task { await environment.start() }
}
#endif

#if DEBUG
#Preview("Settings · unpaired") {
    let environment = AppEnvironment.preview(paired: false)
    NavigationStack {
        SettingsScreen(model: environment.model)
    }
    .environmentObject(environment)
    .preferredColorScheme(.dark)
}
#endif

#if DEBUG
#Preview("Devices") {
    let environment = AppEnvironment.preview()
    NavigationStack {
        DevicesScreen()
    }
    .environmentObject(environment)
    .preferredColorScheme(.dark)
    .task { await environment.start() }
}
#endif
