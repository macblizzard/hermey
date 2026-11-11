import Foundation
import SwiftUI
import HermesKit
import HermesAppKit
import OpenBotUI
#if canImport(UIKit)
import UIKit
#endif

/// The app's single owner of state: one `AppModel` (what the user sees) over one
/// `GatewayClient` (the wire), plus the pairing/device surface the shared model
/// deliberately does not cover.
///
/// The transport factory is built here because the socket URL is not a constant: every
/// connection (and every reconnect) has to exchange the device's refresh token for a
/// fresh 30-second ticket, so the closure reads the current credentials from
/// `CredentialBox` and asks `BridgeService` for the URL at connect time.
@MainActor
final class AppEnvironment: ObservableObject {

    let model: AppModel
    let store: HostStore
    /// The shared Bot Computer (one desktop for every bot on the host). A value type whose
    /// endpoint closure mints a ticket per request, so it survives a re-pair and a reconnect.
    let computer: BotComputerClient
    /// The bot's workspace: the list of documents and the bytes of one.
    let workspace: WorkspaceClient

    // MARK: Pairing

    @Published var isPairingPresented = false
    @Published private(set) var isPairing = false
    @Published private(set) var pairingError: String?

    /// Set by Settings → Disconnect. The app reconnects a dead socket on its own when it
    /// returns to the foreground; a socket the user closed on purpose is not dead, so this
    /// keeps the scene-phase retry from silently undoing that choice.
    @Published private(set) var isDisconnectedByUser = false

    // MARK: Devices

    @Published private(set) var devices: [PairedDevice] = []
    @Published private(set) var devicesLoading = false
    @Published private(set) var devicesError: String?
    @Published private(set) var removingDevice = false
    @Published private(set) var botIcons: [String: BotIcon] = [:]
    @Published private(set) var botIconsError: String?
    private var iconGeneration = 0

    private let bridge: BridgeServiceProtocol
    private let box: CredentialBox

    // No default-argument values here on purpose: a default argument is evaluated in a
    // nonisolated context, and both `HostStore()` and `LiveBridgeService()` are
    // main-actor-isolated. They are built inside the body instead.
    init(client: GatewayClientProtocol? = nil,
         store: HostStore? = nil,
         bridge: BridgeServiceProtocol? = nil) {
        let store = store ?? HostStore()
        let bridge = bridge ?? LiveBridgeService()
        self.store = store
        self.bridge = bridge

        let box = CredentialBox()
        let resolvedClient: GatewayClientProtocol
        if let client {
            resolvedClient = client
        } else {
            resolvedClient = GatewayClient(
                makeTransport: { [box, bridge] in
                    guard let credentials = await box.credentials() else {
                        throw BridgeError.noHost
                    }
                    let url = try await bridge.websocketURL(for: credentials.host,
                                                            refreshToken: credentials.token)
                    return GatewayTransport(urlProvider: { url }).bridge()
                },
                // The one pointer both devices share, read/written over the bridge's HTTP surface
                // with a freshly minted single-use ticket (same shape as `BotIconService`). It is
                // resolved per request because the ticket is spent by exactly one call and the
                // paired host can change; a failure just means this phone uses its local cache.
                sessionPointer: BridgeBotSessionPointer(endpoint: {
                    guard let credentials = await box.credentials() else { throw BridgeError.noHost }
                    let ticket = try await BotIconService.mintTicket(baseURL: credentials.host.baseURL,
                                                                     deviceID: credentials.host.deviceID,
                                                                     refreshToken: credentials.token)
                    return (credentials.host.baseURL, ticket)
                }))
        }
        self.box = box
        self.model = AppModel(client: resolvedClient, hostName: store.host?.host ?? "hermes")
        // Faces before the wire: the icons are the bot list's own look, and waiting for a round
        // trip meant every launch greeted the user with initials for a second or two.
        self.botIcons = Self.cachedBotIcons(host: store.host)
        // Same ticket shape as the icon and preview calls: one freshly minted single-use ticket per
        // request, resolved against whatever host is paired right now.
        self.computer = BotComputerClient(endpoint: {
            guard let credentials = await box.credentials() else { throw BridgeError.noHost }
            let ticket = try await BotIconService.mintTicket(baseURL: credentials.host.baseURL,
                                                             deviceID: credentials.host.deviceID,
                                                             refreshToken: credentials.token)
            return (credentials.host.baseURL, ticket)
        })
        self.workspace = WorkspaceClient(endpoint: {
            guard let credentials = await box.credentials() else { throw BridgeError.noHost }
            let ticket = try await BotIconService.mintTicket(baseURL: credentials.host.baseURL,
                                                             deviceID: credentials.host.deviceID,
                                                             refreshToken: credentials.token)
            return (credentials.host.baseURL, ticket)
        })
    }

    // MARK: - Derived

    /// The display name of the paired host; "hermes" until something is paired, which is
    /// what the connection banner says while unpaired.
    var hostLabel: String {
        store.host?.host ?? model.hostName
    }

    var isPaired: Bool { store.host != nil }

    /// What the banner and the pill are allowed to say. An unpaired app is `.idle`, never
    /// "offline" — there is no host to be offline from.
    var visibleConnection: AppModel.Connection {
        store.isPaired ? model.connection : .idle
    }

    /// `AppModel.refreshLatency()` owns the measurement; the pill reads it, never invents
    /// a number when the host stayed silent.
    var effectiveRTT: Int? { model.latencyMS }

    var defaultDeviceName: String {
        #if canImport(UIKit)
        let name = UIDevice.current.name
        return name.isEmpty ? "iPhone" : name
        #else
        return "iOS device"
        #endif
    }

    // MARK: - Bots

    /// Re-read the host's bot directory. `AppModel.start()` already does this on connect;
    /// this is the explicit retry behind pull-to-refresh and the list's empty state. Bots
    /// are the only thing this app lists now — there is no session list to keep in step.
    func loadBots() async {
        await model.loadBots()
        await loadBotIcons()
    }

    private func iconService() throws -> (PairedHost, BotIconService) {
        guard let host = store.host, let token = store.refreshToken else { throw BridgeError.noHost }
        return (host, BotIconService(baseURL: host.baseURL, freshTicket: {
            try await BotIconService.mintTicket(baseURL: host.baseURL, deviceID: host.deviceID, refreshToken: token)
        }))
    }

    /// The bytes of an attachment the host holds, cached on disk so the chat reopens without a
    /// round trip and keeps working offline once it has seen the picture.
    func attachmentImage(named name: String, profile: String) async -> Data? {
        if let cached = AttachmentImageStore.data(named: name) { return cached }
        guard let credentials = await box.credentials() else { return nil }
        let service = AttachmentImageService(baseURL: credentials.host.baseURL, freshTicket: {
            try await BotIconService.mintTicket(baseURL: credentials.host.baseURL,
                                                deviceID: credentials.host.deviceID,
                                                refreshToken: credentials.token)
        })
        guard let data = try? await service.load(profile: profile, name: name) else { return nil }
        AttachmentImageStore.save(data, as: name)
        return data
    }

    // MARK: - Bot icon cache

    /// Icons are tiny facts (`BotIcon` is a raw value), so they live in `UserDefaults` per host: a
    /// re-pair with a different machine must not wear the old machine's faces.
    private static func botIconCacheKey(_ host: String) -> String { "hermey.botIcons.\(host)" }

    private static func cachedBotIcons(host: PairedHost?) -> [String: BotIcon] {
        guard let host else { return [:] }
        guard let data = UserDefaults.standard.data(forKey: botIconCacheKey(host.host)) else { return [:] }
        guard let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return raw.compactMapValues(BotIcon.init(rawValue:))
    }

    private func persistBotIcons(_ icons: [String: BotIcon], host: PairedHost) {
        let raw = icons.mapValues(\.rawValue)
        guard let data = try? JSONEncoder().encode(raw) else { return }
        UserDefaults.standard.set(data, forKey: Self.botIconCacheKey(host.host))
    }

    func loadBotIcons() async {
        iconGeneration += 1
        let generation = iconGeneration
        do {
            let (host, service) = try iconService()
            let icons = try await service.load()
            guard generation == iconGeneration, store.host == host, !isDisconnectedByUser else { return }
            botIcons = icons
            persistBotIcons(icons, host: host)
            botIconsError = nil
        } catch {
            guard generation == iconGeneration, store.isPaired, !isDisconnectedByUser else { return }
            botIconsError = message(for: error)
        }
    }

    func saveBotIcon(botID: String, icon: BotIcon?) async throws {
        let (host, service) = try iconService()
        try await service.save(botID: botID, icon: icon)
        guard store.host == host, !isDisconnectedByUser else { throw BridgeError.noHost }
        await loadBotIcons()
        if let error = botIconsError { throw NSError(domain: "BotIcons", code: 1, userInfo: [NSLocalizedDescriptionKey: "Saved, but could not refresh icons: \(error)"]) }
    }

    // MARK: - Voice

    /// The transport a conversation's `VoiceController` should use right now.
    ///
    /// Built from the *current* pairing, so a re-pair or a host switch cannot leave the
    /// controller talking to the old host; each request then mints its own single-use
    /// ticket inside `VoiceService`. Unpaired means `.unavailable`, which reports itself
    /// instead of guessing a host.
    func makeVoiceTransport() -> VoiceTransport {
        guard let host = store.host, let token = store.refreshToken else { return .unavailable }
        let service = VoiceService(baseURL: host.baseURL, freshTicket: {
            try await BotIconService.mintTicket(baseURL: host.baseURL,
                                                deviceID: host.deviceID,
                                                refreshToken: token)
        })
        return VoiceTransport(
            transcribe: { audio, mimeType in
                try await service.transcribe(audio: audio, mimeType: mimeType)
            },
            synthesize: { text in
                try await service.synthesize(text: text)
            }
        )
    }

    // MARK: - Lifecycle

    /// Boot: mirror credentials, connect if there is a host, then fill in the facts the
    /// conversation header needs. An unpaired app stays `.idle` — not "offline", which
    /// would blame a host that was never paired.
    func start() async {
        await syncCredentials()
        guard store.isPaired else { return }
        isDisconnectedByUser = false
        await model.start()
        await loadBotIcons()
        await loadDevices()
        await model.refreshLatency()
    }

    func reconnect() async {
        guard store.isPaired else {
            isPairingPresented = true
            return
        }
        isDisconnectedByUser = false
        await syncCredentials()
        // `retryConnection` keeps the open session selected across the reconnect.
        await model.retryConnection()
        await loadBotIcons()
        await loadDevices()
        await model.refreshLatency()
    }

    /// The transport reads credentials at connect time, so they are mirrored here before
    /// every connect; this is also the retry path for a first connect that failed.
    func syncCredentials() async {
        await box.update(host: store.host, token: store.refreshToken)
    }

    // MARK: - Pairing

    /// Redeem a code and, on success, pair, connect and load the device list.
    @discardableResult
    func pair(code rawCode: String, host rawHost: String, deviceName: String) async -> Bool {
        guard let code = PairingPayload.normalizeCode(rawCode) else {
            pairingError = "Enter the code shown on the host (digits only)."
            return false
        }
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            pairingError = "Enter the host this phone should talk to."
            return false
        }

        isPairing = true
        pairingError = nil
        defer { isPairing = false }

        do {
            let claim = try await bridge.claim(code: code,
                                               host: host,
                                               deviceName: deviceName.isEmpty ? defaultDeviceName : deviceName)
            store.save(host: claim.host, refreshToken: claim.refreshToken)
            iconGeneration += 1
            botIcons = [:]
            botIconsError = nil
            await box.update(host: claim.host, token: claim.refreshToken)
            Haptics.success()
            isDisconnectedByUser = false
            await model.start()
            await loadBotIcons()
            await loadDevices()
            await model.refreshLatency()
            return true
        } catch {
            pairingError = message(for: error)
            Haptics.error()
            return false
        }
    }

    func unpair() async {
        iconGeneration += 1
        botIcons = [:]
        botIconsError = nil
        await model.stop()
        store.clear()
        await box.update(host: nil, token: nil)
        DeviceKey.forget()
        devices = []
        devicesError = nil
    }

    /// Drop the socket but keep the pairing: the refresh token stays on this phone, so
    /// `reconnect()` can bring the same host back without another QR code. Settings offers
    /// this next to *Re-pair*, which is the action that replaces the credentials.
    func disconnect() async {
        isDisconnectedByUser = true
        iconGeneration += 1
        botIcons = [:]
        botIconsError = nil
        await model.stop()
    }

    func dismissPairingError() {
        pairingError = nil
    }

    // MARK: - Devices

    func loadDevices() async {
        guard let host = store.host, let token = store.refreshToken else {
            devices = []
            devicesError = "Cannot load devices: this phone is not paired."
            return
        }
        devicesLoading = true
        devicesError = nil
        defer { devicesLoading = false }
        do {
            devices = try await bridge.devices(for: host, refreshToken: token)
        } catch {
            // Keep the last list: a stale device list beats an empty one with a scary
            // error, and Settings shows the error above it.
            devicesError = message(for: error)
        }
    }

    func revoke(_ device: PairedDevice) async {
        guard let host = store.host, let token = store.refreshToken else {
            devicesError = "Cannot revoke the device: this phone is not paired."
            return
        }
        devicesError = nil
        do {
            try await bridge.revoke(deviceID: device.deviceID, on: host, refreshToken: token)
            if let index = devices.firstIndex(where: { $0.deviceID == device.deviceID }) {
                devices[index].revoked = true
            }
            Haptics.success()
            if device.deviceID == host.deviceID {
                // Revoking the phone you are holding ends its own session: drop the
                // credentials rather than pretending the next request will work.
                await unpair()
            }
        } catch {
            devicesError = message(for: error)
            Haptics.error()
        }
    }

    func removeRevoked(_ device: PairedDevice) async {
        guard !removingDevice else { return }
        guard let current = devices.first(where: { $0.deviceID == device.deviceID }), current.revoked else {
            devicesError = "Only revoked devices can be removed. Refresh the list and try again."
            return
        }
        guard let host = store.host, let token = store.refreshToken else {
            devicesError = "Cannot remove the device: this phone is not paired."
            return
        }
        removingDevice = true
        defer { removingDevice = false }
        devicesError = nil
        do {
            try await bridge.removeRevoked(deviceID: current.deviceID, on: host, refreshToken: token)
            await loadDevices()
            if let error = devicesError {
                devicesError = "Device removed, but the list could not refresh: \(error)"
            }
            Haptics.success()
        } catch {
            devicesError = "Could not remove \(current.name): \(message(for: error))"
            Haptics.error()
        }
    }

    // MARK: - Errors

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Previews

    /// A fully paired, network-free environment. Screens preview against this and call
    /// `start()` in a `.task`, exactly as the app does.
    static func preview(paired: Bool = true,
                        scenario: PreviewGatewayClient.Scenario = .sessions) -> AppEnvironment {
        AppEnvironment(client: PreviewGatewayClient(scenario: scenario),
                       store: HostStore.preview(paired: paired),
                       bridge: PreviewBridgeService())
    }
}
