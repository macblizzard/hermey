import SwiftUI
import UIKit
import HermesKit
import HermesAppKit
import HermeyUI

/// Settings holds settings.
///
/// The sections, in the order the contract fixes (`docs/ENDLESS-CHAT.md` §4): the
/// connection, how the chat behaves, the devices the host will still talk to, and what this
/// build is. Device management is one row that opens its own screen — it used to be twenty
/// rows of toggles on this page, which buried the three settings anyone actually changes.
struct SettingsScreen: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var app: AppEnvironment
    /// One object owns the permission and the badge, so the row reports what the system said
    /// rather than what the app wishes it had said.
    @ObservedObject private var notifier = MobileReplyNotifier.shared

    @State private var showUnpairConfirm = false
    /// Whether the log sheet is up. The log is a tool, not a setting, so it opens from a row and
    /// closes with nothing remembered.
    @State private var showLog = false
    /// The bot list's size, dragged here. Same key the Mac uses.
    @AppStorage(BotListMetrics.storageKey) private var listScale = BotListMetrics.defaultScale

    /// The soul a new bot starts from, and a JSON copy of the whole roster. Both live on the host, so
    /// the phone and the Mac are editing the same thing (asked for 2026-11-15).
    private var rosterSection: some View {
        Section("Bots") {
            DefaultSoulPane(current: model.botDefaults.soul.text,
                            builtIn: model.botDefaults.builtIn,
                            present: model.botDefaults.soul.present,
                            isBusy: model.rosterBusy,
                            save: { await model.saveDefaultSoul($0) },
                            onChange: { await model.loadBotDefaults() })
                .listRowBackground(Tokens.surface)
            BackupPane(botCount: model.bots.count,
                       export: { await model.backupDocument() },
                       restore: { await model.restoreBackup($0) })
                .listRowBackground(Tokens.surface)
        }
    }

    /// Appearance: the same catalogue and the same swatches the Mac's Settings draws.
    private var appearanceSection: some View {
        Section("Appearance") {
            ThemePicker()
                .padding(.vertical, 4)
                .listRowBackground(Tokens.surface)

            // The bot list's own size: the face, the name and the line under it move together
            // (asked for 2026-11-15).
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Bot list size")
                        .font(TypeScale.font(TypeScale.md))
                        .foregroundStyle(Tokens.textPrimary)
                    Spacer()
                    Text("\(Int((listScale * 100).rounded())) %")
                        .font(.system(size: TypeScale.caption, design: .monospaced))
                        .foregroundStyle(Tokens.textMuted)
                        .monospacedDigit()
                }
                Slider(value: $listScale,
                       in: BotListMetrics.minScale...BotListMetrics.maxScale,
                       step: 0.01) {
                    Text("Bot list size")
                }
                .accessibilityIdentifier("appearanceBotListScale")
                BotListScalePreview(scale: listScale)
            }
            .padding(.vertical, 4)
            .listRowBackground(Tokens.surface)
        }
    }

    /// What this device keeps: one row into the cache's own screen, with the real total on it so the
    /// cost is visible without opening anything. The switches, the limit and the Reset button live
    /// on `CachingSettingsScreen`, which is also what the Mac's Caching tab shows.
    private var storageSection: some View {
        Section {
            NavigationLink {
                CachingSettingsScreen(model: model)
            } label: {
                HStack(spacing: 8) {
                    Text("Caching")
                        .font(TypeScale.font(TypeScale.md))
                        .foregroundStyle(Tokens.textPrimary)
                    Spacer(minLength: 8)
                    Text(CacheFormat.size(model.cacheUsage.totalBytes))
                        .font(.system(size: TypeScale.caption, design: .monospaced))
                        .foregroundStyle(Tokens.textGroupedSecondary)
                        .monospacedDigit()
                }
            }
            .listRowBackground(Tokens.surface)
        } header: {
            sectionHeader("Storage")
        } footer: {
            Text("What this phone keeps so bot lists, chats and files open without the host. Nothing here is the only copy — the host always has the original.")
                .font(TypeScale.font(TypeScale.label))
        }
    }

    /// Banners and the icon badge, plus the one thing the app cannot decide: the system's answer.
    ///
    /// The toggle is stored in `AppModel` (so it matches the Mac's); the permission is per app and
    /// per device, which is why a denied permission is drawn here with the one door out of it.
    private var notificationsSection: some View {
        Section {
            PushRelaySettings(register: { url in try await model.registerPushRelay(url) },
                              sendTest: { try await model.sendTestPush() })

            Toggle(isOn: Binding(get: { model.replyNotificationsEnabled },
                                 set: { model.setReplyNotifications(enabled: $0) })) {
                Text("Notify me about replies")
                    .font(TypeScale.font(TypeScale.md))
                    .foregroundStyle(Tokens.textPrimary)
            }
            .tint(Tokens.accent)

            switch notifier.authorization {
            case .denied:
                Button {
                    openNotificationSettings()
                } label: {
                    HStack(spacing: 8) {
                        Text("Notifications are off in iOS Settings")
                            .font(TypeScale.font(TypeScale.md))
                            .foregroundStyle(Tokens.textPrimary)
                        Spacer(minLength: 8)
                        Text("Open")
                            .font(TypeScale.font(TypeScale.md))
                            .foregroundStyle(Tokens.accentText)
                    }
                }
            case .notDetermined:
                Button {
                    notifier.requestAuthorizationIfNeeded()
                } label: {
                    Text("Allow notifications")
                        .font(TypeScale.font(TypeScale.md))
                        .foregroundStyle(Tokens.accentText)
                }
            default:
                EmptyView()
            }

            if model.replyNotificationsEnabled && !model.bots.isEmpty {
                NavigationLink {
                    QuietBotsScreen(model: model)
                } label: {
                    HStack(spacing: 8) {
                        Text("Quiet bots")
                            .font(TypeScale.font(TypeScale.md))
                            .foregroundStyle(Tokens.textPrimary)
                        Spacer(minLength: 8)
                        if !model.mutedNotificationBots.isEmpty {
                            Text("\(model.mutedNotificationBots.count)")
                                .font(TypeScale.font(TypeScale.label))
                                .foregroundStyle(Tokens.textMuted)
                        }
                    }
                }
            }
        } header: {
            Text("Replies")
        } footer: {
            Text("A banner and a badge when a bot replies in a chat you are not reading. iOS delivers these promptly while the app is running; once the phone has put the app away it checks in the background, on a schedule iOS decides — so a banner can arrive a few minutes late unless a relay address is registered in this section, which delivers with the app closed. A chat on screen never notifies.")
        }
    }

    private func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    var body: some View {
        List {
            connectionSection
            appearanceSection
            storageSection
            rosterSection
            notificationsSection
            chatSection
            devicesSection
            diagnosticsSection
            updateSection
            aboutSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Tokens.canvas)
        .navigationTitle("Settings")
        .task { await app.loadDevices() }
        .task { await model.loadBotDefaults() }
        .task { await model.loadCacheState() }
        .sheet(isPresented: $showLog) {
            ClientLogView(title: "Log", header: logHeader)
            .hermesSheetChrome()
        }
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

            Toggle(isOn: $model.showToolCalls) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show tool calls")
                        .font(TypeScale.font(TypeScale.md))
                        .foregroundStyle(Tokens.textPrimary)
                    Text("A card for every command the bot runs, with its result. Off hides them from the chat.")
                        .font(TypeScale.font(TypeScale.label))
                        .foregroundStyle(Tokens.textGroupedSecondary)
                }
            }
            .tint(Tokens.success)
        } header: {
            sectionHeader("Chat")
        } footer: {
            // Compaction is the host's job, at its own `compression.threshold` — it compacts at the
            // start of a turn when the context crosses it. An app-side threshold was a second
            // opinion nobody asked for, and it could compact a thread the host was about to.
            Text("The host compacts a conversation on its own when it nears the model's window. The header still shows how full the context is.")
                .font(TypeScale.font(TypeScale.label))
        }
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

    // MARK: Diagnostics

    /// Where the app explains itself.
    ///
    /// Every failure the user can see is a sentence in this app; the reason is in the log behind
    /// this row. It is one row because a log is a tool, not a setting — nothing here changes how
    /// the app behaves.
    private var diagnosticsSection: some View {
        Section {
            Button {
                showLog = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Tokens.textMuted)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.radiusSmall, style: .continuous)
                                .fill(Tokens.control)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("View log")
                            .font(TypeScale.font(TypeScale.md))
                            .foregroundStyle(Tokens.textPrimary)

                        Text("What this app did, and where it failed.")
                            .font(TypeScale.font(TypeScale.label))
                            .foregroundStyle(Tokens.textGroupedSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tokens.textDim)
                }
                .padding(.vertical, 2)
            }
        } header: {
            sectionHeader("Diagnostics")
        } footer: {
            Text("A timestamped record of this phone's connections, retries and failures. When something goes wrong, open this and copy the line at the time it happened.")
                .font(TypeScale.font(TypeScale.label))
        }
    }

    /// The facts a reader needs before the first log line: which build, on what, against which
    /// host, over which connection.
    private var logHeader: String {
        let version = bundleValue("CFBundleShortVersionString")
        let build = bundleValue("CFBundleVersion")
        let system = UIDevice.current.systemName + " " + UIDevice.current.systemVersion
        return "Hermey \(version) (build \(build))\n\(system) · host: \(app.hostLabel) · \(app.visibleConnection.label)"
    }

    // MARK: About

    /// The one row that asks the feed on demand.
    ///
    /// A manual check is never throttled and never suppressed by an earlier "not now", which is the
    /// whole point of the row: the user asking is the user overriding what the app decided for them.
    private var updateSection: some View {
        Section {
            CheckForUpdatesRow(updates: app.updates)
                .listRowBackground(Tokens.surface)
        } header: {
            sectionHeader("Updates")
        } footer: {
            Text("Download opens the install link in Safari; AltStore, if it is installed, can take it from there. This app never installs anything by itself.")
                .font(TypeScale.font(TypeScale.label))
        }
    }

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

// MARK: - Check for Updates

/// The Settings row: the build this phone is running, and a way to ask the feed right now.
///
/// It observes the checker itself rather than the app environment, so a feed answer redraws one row
/// instead of the whole settings list.
struct CheckForUpdatesRow: View {
    @ObservedObject var updates: UpdateChecker

    var body: some View {
        Button {
            Haptics.impact()
            Task { await updates.check(manual: true) }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Check for Updates")
                        .font(TypeScale.font(TypeScale.md))
                        .foregroundStyle(Tokens.textPrimary)
                    Text(detail)
                        .font(TypeScale.font(TypeScale.label))
                        .foregroundStyle(Tokens.textGroupedSecondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                if updates.isChecking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Tokens.textMuted)
                }
            }
        }
        .accessibilityIdentifier("checkForUpdates")
    }

    /// The build is always named: a person deciding about an update wants to know which one they
    /// have, and "up to date" alone never says that.
    private var detail: String {
        if updates.isChecking { return "Checking…" }
        if let available = updates.available {
            return "\(available.version) available · build \(updates.currentBuild)"
        }
        return "Build \(updates.currentBuild)"
    }
}

// MARK: - Settings, as a sheet

/// Settings where the app actually presents it: as the bot list's sheet.
///
/// The stack is created **here**, at the presentation boundary, and not inside `SettingsScreen`.
/// A sheet is its own presentation context — it does not inherit the `NavigationStack` it was
/// presented from — so a `SettingsScreen` put into a sheet bare left every `NavigationLink` row
/// with no navigation container to resolve against. SwiftUI draws such a link disabled and a tap
/// does nothing, which is one report with two faces: "Storage/Caching is greyed out and cannot be
/// changed" and "Devices is greyed out and I cannot remove paired devices" (both rows had already
/// loaded their data — `.task` on the parent still runs — so they showed live subtitles while
/// being inert).
///
/// The Done button belongs to the sheet, not to the screen: `SettingsScreen` can push two levels
/// down (Caching, Devices), and a sheet whose only exit is the swipe gesture is a trap. Pushed
/// screens get the system's back button from this same stack.
struct SettingsSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsScreen(model: model)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("settings.done")
                    }
                }
        }
    }
}

// MARK: - Devices

/// The device list, one screen down.
///
/// Revoking is one-way on the bridge, so the row offers `Revoke` behind a confirmation and then
/// lands in a revoked state rather than pretending it can be switched back on. A revoked row offers
/// the other one-way verb, `Remove`, which deletes its record from the host.
struct DevicesScreen: View {
    @EnvironmentObject private var app: AppEnvironment

    /// The one confirmation this screen can be waiting on.
    ///
    /// One enum rather than two `confirmationDialog` modifiers on the same list: two dialogs
    /// attached to one view is a stacked-presentation hazard, and a screen that can only be waiting
    /// for one answer has no use for two flags.
    private enum Prompt {
        case revoke(PairedDevice)
        case remove(PairedDevice)

        var device: PairedDevice {
            switch self {
            case .revoke(let device), .remove(let device): return device
            }
        }

        var title: String {
            switch self {
            case .revoke(let device): return "Revoke \(device.name)?"
            case .remove(let device): return "Remove \(device.name)?"
            }
        }

        var message: String {
            switch self {
            case .revoke:
                return "The host deletes this device's refresh token immediately, and any open websocket ticket stops working."
            case .remove:
                return "Permanently remove this revoked device's record from the host. This does not remove any other devices."
            }
        }

        var confirmTitle: String {
            switch self {
            case .revoke: return "Revoke"
            case .remove: return "Remove device"
            }
        }

        var cancelTitle: String {
            switch self {
            case .revoke: return "Keep access"
            case .remove: return "Cancel"
            }
        }
    }

    @State private var prompt: Prompt?

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
                                    prompt = .remove(device)
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
                Text("Revoke removes a device's access on the host. That cannot be undone — pair it again to give it access. A revoked device can then be removed here for good.")
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
        // `presenting:` hands the dialog the prompt it was opened with, so the buttons do not
        // change underneath a dismissal.
        .confirmationDialog(prompt?.title ?? "Devices",
                            isPresented: Binding(get: { prompt != nil },
                                                 set: { if !$0 { prompt = nil } }),
                            titleVisibility: .visible,
                            presenting: prompt) { prompt in
            Button(prompt.confirmTitle, role: .destructive) { confirm(prompt) }
            Button(prompt.cancelTitle, role: .cancel) { self.prompt = nil }
        } message: { prompt in
            Text(prompt.message)
        }
    }

    /// One device, with the one verb that applies to it on the row.
    ///
    /// The verb used to be a `Toggle` — an access switch that could only ever go one way, since
    /// revoking is one-way on the bridge — and permanent removal existed only behind a trailing
    /// swipe, which is a gesture nobody is told about. Both actions now sit where the device is:
    /// `Revoke` while it still has access, `Remove` once it is revoked. Each one asks first.
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
                    if device.revoked {
                        StatusChip("revoked", tone: .danger, size: .small)
                    }
                }

                Text(subtitle(for: device))
                    .font(TypeScale.font(TypeScale.label))
                    .foregroundStyle(Tokens.textGroupedSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            action(for: device)
        }
        .padding(.vertical, 2)
    }

    /// Revoke, or remove. Never both: a device with access has nothing to remove, and a revoked
    /// one has no access left to take away.
    @ViewBuilder
    private func action(for device: PairedDevice) -> some View {
        if device.revoked {
            Button("Remove") {
                Haptics.selection()
                prompt = .remove(device)
            }
            .buttonStyle(.borderless)
            .font(TypeScale.font(TypeScale.md))
            .foregroundStyle(Tokens.danger)
            .disabled(app.removingDevice || app.store.host == nil)
            .accessibilityLabel("Remove \(device.name) permanently")
            .accessibilityIdentifier("devices.remove.\(device.deviceID)")
        } else {
            Button("Revoke") {
                Haptics.selection()
                prompt = .revoke(device)
            }
            .buttonStyle(.borderless)
            .font(TypeScale.font(TypeScale.md))
            .foregroundStyle(Tokens.danger)
            .disabled(app.store.host == nil)
            .accessibilityLabel("Revoke \(device.name)")
            .accessibilityIdentifier("devices.revoke.\(device.deviceID)")
        }
    }

    private func subtitle(for device: PairedDevice) -> String {
        if device.revoked { return "No access · remove to clear its record" }
        let platform = device.platformLabel
        if let seen = device.lastSeenAt {
            return "\(platform) · seen \(RelativeTime.short(seen))"
        }
        return platform
    }

    /// Both verbs go through the bridge, and both end by re-reading the host's list.
    ///
    /// `AppEnvironment.revoke` flips the local row the moment the bridge answers, which is what
    /// makes the screen move immediately; the refresh after it is what turns this phone's optimism
    /// back into a fact about the host. `removeRevoked` already refreshes, so it needs nothing
    /// extra here.
    private func confirm(_ prompt: Prompt) {
        let device = prompt.device
        self.prompt = nil
        switch prompt {
        case .revoke:
            Task {
                await app.revoke(device)
                // Revoking *this* phone unpairs it, which clears the list already; asking the host
                // for a device list we no longer have a token for would only print "not paired"
                // over the result.
                if app.isPaired { await app.loadDevices() }
            }
        case .remove:
            Task { await app.removeRevoked(device) }
        }
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

/// The bots that never raise a banner. A quieted bot still counts on its row and in the badge —
/// the switch is about being interrupted, not about hiding that something is waiting.
struct QuietBotsScreen: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            Section {
                ForEach(model.bots) { bot in
                    Toggle(isOn: Binding(get: { !model.isNotificationMuted(bot.id) },
                                         set: { wantsBanners in
                                             if wantsBanners == model.isNotificationMuted(bot.id) {
                                                 Haptics.selection()
                                                 model.toggleNotificationMute(bot.id)
                                             }
                                         })) {
                        Text(bot.displayName)
                            .font(TypeScale.font(TypeScale.md))
                            .foregroundStyle(Tokens.textPrimary)
                    }
                    .tint(Tokens.accent)
                    .listRowBackground(Tokens.surface)
                }
            } footer: {
                Text("Off means this bot never buzzes. Its replies still count on its row and in the badge.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Tokens.canvas)
        .navigationTitle("Quiet bots")
    }
}
