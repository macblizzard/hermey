import Combine
import Foundation
import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// Everything the macOS shell owns that `AppModel` does not: the pairing, the palette, the
/// pane geometry and the per-bot drafts.
///
/// `AppModel` stays the single source of truth for what is on the wire. This type is the
/// window around it — and it is deliberately the only place that knows both a
/// `PairingAddress` and a `GatewayClient`, so a preview can hold an `AppModel` with no
/// socket anywhere near it.
///
/// **One panel, one conversation.** The Mac matches the phone: the left panel lists bots and
/// nothing else, and picking a bot opens *that bot's single conversation* through
/// `AppModel.endlessSession(for:)` — the bot's shared stored id from the bridge (cached per device
/// under `hermes.endlessSession.<botID>`), resumed on every switch. There is no session list, no
/// session search and no session selection here; the shell never asks the host for a conversation
/// the model did not already remember.
@MainActor
final class WorkspaceStore: ObservableObject {

    // MARK: State

    /// The per-window model. Replaced when the host changes; never mutated from outside.
    @Published private(set) var model: AppModel
    @Published private(set) var pairing: PairingAddress? = nil
    /// Where this Mac's pairing is kept — Keychain, or the 0600 file an unsigned build falls back to.
    /// Settings reads it, because a build that cannot use the Keychain should say so rather than
    /// leave the next relaunch looking like a lost pairing.
    @Published private(set) var pairingStorage: PairingStore.Storage?

    @Published var isPairSheetPresented = false
    @Published var isPalettePresented = false
    /// Bumped when the conversation header's magnifier asks for find-in-conversation.
    ///
    /// `TranscriptScroll` owns the search field and its matches — they are a reading tool, not app
    /// state — so this is a request counter, not a boolean: a second press has to re-open and
    /// re-focus a search that is already up, which a Bool could not express. ⌘F stays the
    /// keyboard door; the magnifier is the discoverable one.
    @Published private(set) var findRequest = 0
    /// The bot whose settings sheet is open; `nil` closes it. The bot list's context menu, the
    /// conversation's menu and the Settings window's Bots tab all set this, so there is one
    /// sheet and one owner.
    @Published var botSettingsBot: Bot? = nil
    @Published private(set) var botFaces: [String: BotFace] = [:]
    @Published private(set) var botFacesError: String?
    private var iconGeneration = 0
    /// The open bot's own profile default, for the header chip.
    ///
    /// `AppModel.modelLabel` is read once per connect and per endless-session open; this asks the
    /// same profile-scoped catalogue call and is refreshed whenever the open bot changes.
    @Published private(set) var openBotModelLabel: String?
    @Published private(set) var sidebarWidth: CGFloat = Geometry.sidebarDefault

    /// Whether the bot panel is collapsed. Remembered between launches: a window too narrow for
    /// two panes stays narrow, and its owner should not have to hide the panel again every time.
    /// Set by an explicit Disconnect: the one thing that keeps a launch from dialling a host the
    /// user has just walked away from. Cleared by any connect.
    private var didDisconnectThisRun = false

    @Published private(set) var isSidebarHidden = UserDefaults.standard.bool(forKey: WorkspaceStore.sidebarHiddenKey)

    /// What the ⌘K panel is currently listing. One entry point — "Theme switcher" — opens the
    /// palette *in* theme mode, so the palette is not littered with six rows nobody asked for.
    enum PaletteMode { case commands, themes }
    @Published private(set) var paletteMode: PaletteMode = .commands

    /// The one confirmation the conversation needs. It lives on the store so the header's menu,
    /// the toolbar and the palette's verb can all raise the same dialog instead of three copies.
    @Published var isResetConfirmationPresented = false

    /// Bot and room sheets live on the store so the ⌘K palette can raise them: a verb that is only
    /// reachable by remembering which corner of the sidebar hides it is not really a verb.
    @Published var isAddBotPresented = false
    @Published var isManageBotsPresented = false
    @Published var isStartGroupChatPresented = false
    @Published var isGroupChatsPresented = false

    /// Set the first time the user asks to connect, so the empty panel can tell
    /// "not paired" apart from "paired, but nothing loaded yet".
    @Published private(set) var connectAttempted = false

    private let pairingStore = PairingStore()
    private var latencyTask: Task<Void, Never>?
    /// Unsent composer text, parked under the bot it was typed for. A draft has no profile on
    /// the host yet, so it belongs to the bot, not to a session id.
    private var drafts: [String: String] = [:]

    private static let widthKey = "hermes.workspace.sidebarWidth"
    static let sidebarHiddenKey = "hermey.workspace.sidebarHidden"

    /// The narrowest the bot panel may be dragged: below this a row's name and description
    /// collide with the unread dot.
    static let sidebarFloor: CGFloat = WindowLayout.sidebarFloor

    /// Retained only because the frozen UI-test fixture assigns it
    /// (`Apps/HermesMac/Testing/PreviewFixture.swift`, which this branch must not edit). The
    /// right-hand context panel is gone, so nothing in the app reads this and nothing persists it.
    @Published var showsContextPanel = false
    /// The shared desktop, as a right-hand panel. It is the same screen for every bot, so the
    /// panel is a property of the window, not of the selected bot — switching bots keeps it open
    /// and the pane re-labels itself.
    @Published var isComputerPanelPresented = false
    /// The bot's own panel on the right edge: the phone's drawer, as a pane. Rakazo's shape —
    /// the name in the header is the control, and every verb about this bot lives beside the chat
    /// rather than in a dropdown that closes after one click.
    @Published var isBotPanelPresented = false
    /// Which of the three per-bot panels is up. One at a time, like every other sheet here.
    @Published var workspaceBot: Bot?
    @Published var skillsBot: Bot?
    @Published var mcpBot: Bot?
    /// What this bot runs on a schedule — the phone's Routines row, as a sheet.
    @Published var routinesBot: Bot?

    /// Open one of them, closing any other: the window's one modal is shared.
    func openWorkspace(_ bot: Bot) { closePanels(); workspaceBot = bot }
    func openSkills(_ bot: Bot) { closePanels(); skillsBot = bot }
    func openMCP(_ bot: Bot) { closePanels(); mcpBot = bot }
    func openRoutines(_ bot: Bot) { closePanels(); routinesBot = bot }

    private func closePanels() {
        workspaceBot = nil
        skillsBot = nil
        mcpBot = nil
        routinesBot = nil
    }
    /// Full screen is the panel's own verb; closing the panel drops it so the next open is a panel.
    @Published var isComputerFullScreen = false

    // MARK: Init

    /// The real app. Reads what was paired last time, and dials nothing.
    init() {
        let store = PairingStore()
        if let saved = store.savedAddress() {
            pairing = saved
            pairingStorage = store.storage
            model = WorkspaceStore.makeModel(for: saved)
            ClientLog.note("pairing restored from \(store.storage?.rawValue ?? "unknown")", category: "pairing")
        } else {
            model = AppModel(client: UnpairedGatewayClient(), hostName: "hermes")
        }
        restorePreferences()
    }

    /// Preview / test entry point: an `AppModel` over `PreviewGatewayClient`.
    init(model: AppModel, pairing: PairingAddress? = nil) {
        self.model = model
        self.pairing = pairing
        restorePreferences()
    }

    // MARK: Derived

    var isPaired: Bool { pairing != nil }

    /// The bot whose conversation is on screen. Nil while the list is still empty, which is
    /// what lets the panel say "no bots" rather than borrow a name.
    var selectedBot: Bot? { model.selectedBot }

    /// The chat header's name: the bot, because a bot *is* the conversation. Before profiles
    /// arrive it falls back to the host's own name, never a hardcoded product name.
    var botTitle: String {
        selectedBot?.displayName ?? model.hostName
    }

    /// ⌘0: back to the design system's own sizes.
    func resetTextSize() {
        TypeScale.factor = 1
        UserDefaults.standard.set(1.0, forKey: TypeScale.scaleDefaultsKey)
        themeVersion += 1
    }

    var canSend: Bool {
        // An attachment with no words is a message: the arrow looked live and did nothing, because
        // this gate only ever looked at the draft.
        guard model.selectedSessionID != nil else { return false }
        return !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !model.pendingAttachments.isEmpty
    }

    var canInterrupt: Bool { model.isStreaming || model.sending }


    /// Open one bot's settings, from wherever the user asked for it.
    func openBotSettings(_ bot: Bot) {
        botSettingsBot = bot
    }

    /// Ask the host for the open bot's current model, scoped to that profile.
    ///
    /// Silent on failure: no chip is honest, a stale or gateway-wide model name is the bug this
    /// replaces. Called when the workspace appears, when the bot changes, and after a settings write.
    func refreshOpenBotModelLabel() async {
        guard let id = model.selectedBotID else {
            openBotModelLabel = nil
            return
        }
        do {
            openBotModelLabel = try await model.modelCatalog(for: id).current?.label
        } catch {
            openBotModelLabel = nil
        }
    }

    // MARK: Bots

    /// Re-read the host's bot directory. `AppModel.start()` already does this on connect;
    /// this exists for the explicit "check again" affordance, which must not reconnect.
    func loadBots() async {
        await model.loadBots()
        await loadBotFaces()
        // Third line of every row. Cached per bot, so a second call is free and a bot that has
        // already answered is not asked again.
        await model.loadBotPreviews()
    }

    /// Switch the workspace to another bot: its one conversation is resumed, and the composer
    /// shows the draft that was typed for it.
    ///
    /// The conversation is *resumed*, not created: `endlessSession(for:)` reads the stored id and
    /// only starts a new session when the host has forgotten the old one (4001/4007). Switching
    /// back and forth therefore never piles up empty sessions on the host.
    func selectBot(_ id: String) {
        // A room can be showing while `selectedBotID` is still the bot underneath it, so the
        // "same bot twice" guard must not fire before the room is dismissed — that guard is what
        // made the list feel dead after opening a group chat.
        let wasShowingRoom = model.activeRoom != nil
        model.closeRoom()
        guard id != model.selectedBotID || wasShowingRoom else { return }
        parkDraft()
        model.draft = ""
        Task { [weak self] in
            guard let self else { return }
            await self.openConversation(for: id)
            self.model.draft = self.drafts[id] ?? ""
        }
    }

    /// Open (or resume) the selected bot's single conversation.
    ///
    /// The one door the empty chat offers, and what `connect()` calls when the wire comes up.
    func startConversation() {
        guard let id = model.selectedBotID else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.openConversation(for: id)
            self.model.draft = self.drafts[id] ?? ""
        }
    }

    /// Resume-or-create, then refresh the header's model chip.
    private func openConversation(for botID: String) async {
        _ = await model.endlessSession(for: botID)
        await refreshOpenBotModelLabel()
        rememberOpenBot()
    }

    /// After the socket opens: nothing is on screen yet, so open the selected bot's conversation.
    /// A reconnect that already has a conversation keeps it (`selectedSessionID` is non-nil).
    private func openConversationIfNeeded() async {
        guard model.selectedSessionID == nil, let bot = model.selectedBotID else { return }
        await openConversation(for: bot)
        model.draft = drafts[bot] ?? ""
    }

    /// What was open last, per host: a second machine on the same key would otherwise reopen
    /// whichever bot the other one was last looking at.
    private static func lastBotKey(_ host: String) -> String { "hermey.lastBot.\(host)" }

    private func rememberOpenBot() {
        guard let id = model.selectedBotID else { return }
        UserDefaults.standard.set(id, forKey: Self.lastBotKey(hostKey))
    }

    private func restoreLastBot() {
        guard let id = UserDefaults.standard.string(forKey: Self.lastBotKey(hostKey)),
              model.bots.contains(where: { $0.id == id }),
              id != model.selectedBotID else { return }
        selectBot(id)
    }

    private var hostKey: String {
        pairing?.displayHost ?? model.hostName
    }

    /// Called once when the window appears: a paired host is dialled without being asked.
    func connectOnLaunchIfPaired() async {
        guard isPaired, !connectAttempted, !didDisconnectThisRun else { return }
        await connect()
    }

    private func parkDraft() {
        if let id = model.selectedBotID { drafts[id] = model.draft }
    }

    // MARK: Lifecycle

    /// Attach to the host.
    ///
    /// The app used to make no network call at launch and wait for a **Connect** button, which put
    /// two "Not connected" panels in front of a person every morning for a socket that was going to
    /// come up in a second anyway. A paired host is dialled at launch and the last conversation is
    /// reopened; `didDisconnectThisRun` is the one thing that stops it, so an explicit Disconnect is
    /// not undone by the next launch.
    func connect() async {
        guard pairing != nil else {
            isPairSheetPresented = true
            return
        }
        didDisconnectThisRun = false
        connectAttempted = true
        await model.start()
        if model.connection.isLive {
            startLatencyLoop()
            await loadBotFaces()
            // The conversation that was on screen when the app closed, not "pick a bot".
            restoreLastBot()
            await openConversationIfNeeded()
        }
    }

    func reconnect() async {
        connectAttempted = true
        await model.retryConnection()
        if model.connection.isLive {
            startLatencyLoop()
            await loadBotFaces()
            await openConversationIfNeeded()
        }
    }

    func disconnect() async {
        didDisconnectThisRun = true
        clearBotFaces()
        stopLatencyLoop()
        await model.stop()
    }

    /// Persist a new host and rebuild the model around it. Does not connect: the sheet
    /// calls `connect()` straight after, which is the user's deliberate second half.
    func pair(urlText: String, deviceID: String = "", token: String) throws {
        let address = try PairingAddress.parse(urlText, deviceID: deviceID, token: token)
        pairingStorage = pairingStore.save(address)

        clearBotFaces()
        stopLatencyLoop()
        pairing = address
        model = WorkspaceStore.makeModel(for: address)
        drafts.removeAll()
        connectAttempted = false
        isPairSheetPresented = false
    }

    /// True when the keychain refused the pairing, so the sheet can say the host will have
    /// to be re-paired after a relaunch.
    var pairingIsSessionOnly: Bool { !pairingStore.persisted && pairing != nil }

    /// The narrowest window that holds what is on screen right now: two panes, or three while the
    /// shared computer is open. `WorkspaceRoot` draws to this and `WindowWidthFitter` grows the window
    /// to it, so a pane opening can never clip the shell's edges.
    var minimumWindowWidth: CGFloat {
        WindowLayout.minimumWidth(sidebarWidth: isSidebarHidden ? nil : sidebarWidth,
                                  panelOpen: isComputerPanelPresented,
                                  botPanelOpen: isBotPanelPresented)
    }

    /// One sentence about where the pairing lives, for Settings.
    var pairingStorageDescription: String? {
        guard pairing != nil else { return nil }
        guard let storage = pairingStorage else {
            return "This session only — nothing could be stored, so a relaunch will ask for a code."
        }
        return "Stored in \(storage.description)."
    }

    func unpair() async {
        clearBotFaces()
        stopLatencyLoop()
        await model.stop()
        pairingStore.clear()
        pairingStorage = nil
        pairing = nil
        model = AppModel(client: UnpairedGatewayClient(), hostName: "hermes")
        drafts.removeAll()
        connectAttempted = false
    }

    private func clearBotFaces() {
        iconGeneration += 1
        botFaces = [:]
        botFacesError = nil
    }

    func loadBotFaces() async {
        guard let address = pairing, !address.isTicketOnly else { return }
        iconGeneration += 1
        let generation = iconGeneration
        do {
            let icons = try await MacBotIconService(address: address).load()
            guard generation == iconGeneration, pairing == address else { return }
            botFaces = icons
            botFacesError = nil
        } catch {
            guard generation == iconGeneration, pairing == address else { return }
            botFacesError = error.localizedDescription
        }
    }

    func saveBotFace(botID: String, face: BotFace?) async throws {
        guard let address = pairing, !address.isTicketOnly else {
            throw MacBotIconService.Failure.devicePairingRequired
        }
        iconGeneration += 1
        let generation = iconGeneration
        try await MacBotIconService(address: address).save(botID: botID, face: face)
        guard generation == iconGeneration, pairing == address else { return }
        await loadBotFaces()
        if let error = botFacesError {
            throw MacBotIconService.Failure.refresh(error)
        }
    }

    // MARK: Previews and UI fixture

    /// Open the first session the model already listed, if nothing is open.
    ///
    /// This is the *offline* path only: `PreviewSupport.attachPreviewHost()` and the frozen
    /// UI-test fixture call it to put a canned transcript on screen without a live host (the
    /// fixture's `listSessions` answers one row). The app itself never calls it — bot selection
    /// goes through `endlessSession(for:)`.
    func openFirstSessionIfNeeded() async {
        guard model.selectedSessionID == nil, let first = model.sessions.first else { return }
        await model.select(first.id)
    }

    // MARK: Turn

    func send() {
        guard canSend else { return }
        Task { [weak self] in
            await self?.model.send()
        }
    }

    func interrupt() {
        guard canInterrupt else { return }
        Task { [weak self] in
            await self?.model.interrupt()
        }
    }

    func retrySend() {
        guard canSend else { return }
        send()
    }

    // MARK: Voice

    /// Voice input needs a refresh token: each transcription mints its own short-lived ticket,
    /// and a ticket-only pairing has already spent its single one on the socket upgrade.
    var canTranscribeVoice: Bool { pairing.map { !$0.isTicketOnly } ?? false }

    /// Transcribe captured audio on the paired host.
    ///
    /// `MacVoiceService` mints a fresh single-use ticket per call from this window's pairing, so
    /// a host switch or a re-pair is picked up without the composer holding any credential. Read
    /// at call time, not cached: nothing outlives one recording.
    func transcribeVoice(_ audio: Data, mimeType: String) async throws -> String {
        guard let address = pairing, !address.isTicketOnly else {
            throw MacVoiceFailure.devicePairingRequired
        }
        return try await MacVoiceService(address: address).transcribe(audio: audio, mimeType: mimeType)
    }

    // MARK: Approvals

    func approve(_ request: ServerRequest) {
        Task { [weak self] in
            await self?.model.approve(request)
        }
    }

    /// Deny is an explicit `deny` choice, never a `-32601`: the latter tells the gateway this
    /// client cannot answer at all, and the agent is told nobody refused.
    func deny(_ request: ServerRequest) {
        Task { [weak self] in
            await self?.model.deny(request)
        }
    }

    func answer(_ request: ServerRequest, choice: String) {
        Task { [weak self] in
            await self?.model.answer(request, choice: choice)
        }
    }

    func submitClarification(_ request: ServerRequest, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { [weak self] in
            await self?.model.answers(request, ["response": trimmed])
        }
    }

    func decline(_ request: ServerRequest) {
        Task { [weak self] in
            await self?.model.decline(request)
        }
    }

    // MARK: Geometry

    /// Live drag value, clamped to what the panel can actually draw.
    func setSidebarWidth(_ width: CGFloat) {
        sidebarWidth = min(Geometry.sidebarMax, max(WorkspaceStore.sidebarFloor, width))
    }

    /// Snap on mouse-up and persist, so the window reopens where it was left.
    func endSidebarDrag() {
        sidebarWidth = min(Geometry.sidebarMax, max(WorkspaceStore.sidebarFloor, sidebarWidth))
        UserDefaults.standard.set(Double(sidebarWidth), forKey: WorkspaceStore.widthKey)
    }

    // MARK: Palette

    func openPalette() {
        paletteMode = .commands
        isPalettePresented = true
    }

    /// Open the palette already listing the themes.
    func openThemeSwitcher() {
        paletteMode = .themes
        isPalettePresented = true
    }

    func closePalette() {
        isPalettePresented = false
        paletteMode = .commands
    }

    /// The themes as palette rows, with the current one ticked.
    var themeCommands: [WorkspaceCommand] {
        ThemeCatalog.all.map { theme in
            WorkspaceCommand(
                id: "theme.\(theme.id)",
                title: theme.id == ThemeRuntime.active.id ? "✓ \(theme.name)" : theme.name,
                subtitle: theme.id == ThemeRuntime.active.id ? "Current theme" : "Use this theme",
                systemImage: "paintpalette",
                shortcut: nil,
                group: .appearance,
                isEnabled: true,
                run: { [weak self] in
                    guard let self else { return }
                    self.selectTheme(theme.id)
                    self.closePalette()
                })
        }
    }

    /// ⌘+ / ⌘-: one step larger or smaller, then the same rebuild a theme change does (every size
    /// is read at draw time, so only a fresh subtree carries the new scale).
    func stepTextSize(_ direction: Int) {
        TypeScale.stepSize(direction)
        themeVersion += 1
    }


    /// Apply a theme, which re-creates the shell (see `WorkspaceRoot`): the palette is read by
    /// `Tokens` at draw time, and a rebuilt tree is what makes every colour take it.
    func selectTheme(_ id: String) {
        ThemeRuntime.apply(id: id)
        themeVersion += 1
    }

    /// Bumped whenever the palette changes, so the shell can be re-created without touching the
    /// model — drafts, sessions and scroll-to-bottom wishes survive a theme change.
    @Published private(set) var themeVersion = 0

    /// Show or hide the bot panel, and remember the choice.
    func toggleSidebar() {
        isSidebarHidden.toggle()
        UserDefaults.standard.set(isSidebarHidden, forKey: Self.sidebarHiddenKey)
    }
    /// ⌘K, ⌘K again: the palette is an overlay now, so the same key both raises and drops it.
    /// Raising it always starts on the commands, never in whatever mode it was left in.
    func togglePalette() {
        if isPalettePresented { closePalette() } else { openPalette() }
    }

    /// Ask the transcript for its search field. The same door ⌘F opens, reachable with the mouse
    /// from the header's magnifier — which used to raise the palette instead.
    func openFindInChat() { findRequest += 1 }

    /// The live catalogue. Disabled entries are shown but cannot run: a palette that hides
    /// half its verbs is harder to learn than one that explains why a verb is unavailable.
    var commands: [WorkspaceCommand] {
        var items: [WorkspaceCommand] = []

        items.append(WorkspaceCommand(
            id: "turn.interrupt",
            title: "Interrupt the turn",
            subtitle: "Stop the running agent turn in this conversation",
            systemImage: "stop.fill",
            shortcut: "⌘.",
            group: .chat,
            isEnabled: canInterrupt,
            run: { [weak self] in self?.interrupt() }))

        items.append(WorkspaceCommand(
            id: "chat.compact",
            title: "Compact conversation",
            subtitle: "Summarise the history now instead of waiting for the threshold",
            systemImage: "rectangle.compress.vertical",
            shortcut: nil,
            group: .chat,
            isEnabled: model.canActOnConversation,
            run: { [weak self] in
                guard let self else { return }
                Task { await self.model.compressNow() }
            }))

        items.append(WorkspaceCommand(
            id: "chat.reset",
            title: "Reset conversation…",
            subtitle: "Start this bot again from an empty conversation",
            systemImage: "arrow.counterclockwise",
            shortcut: nil,
            group: .chat,
            isEnabled: model.canActOnConversation,
            run: { [weak self] in self?.isResetConfirmationPresented = true }))

        // One door, not six: the palette carries a single "Theme switcher" and opens *itself* in
        // theme mode, where the catalogue is listed and can be searched like any other verb.
        items.append(WorkspaceCommand(
            id: "theme.switcher",
            title: "Theme switcher…",
            subtitle: "Change the palette — \(ThemeRuntime.active.name) now",
            systemImage: "paintpalette",
            shortcut: nil,
            group: .appearance,
            isEnabled: true,
            run: { [weak self] in self?.openThemeSwitcher() }))

        items.append(WorkspaceCommand(
            id: "view.sidebar",
            title: isSidebarHidden ? "Show bot panel" : "Hide bot panel",
            subtitle: "Collapse the list of bots to give the conversation the whole window",
            systemImage: "sidebar.leading",
            shortcut: "⌘⌥S",
            group: .chat,
            isEnabled: true,
            run: { [weak self] in self?.toggleSidebar() }))

        items.append(WorkspaceCommand(
            id: "chat.botSettings",
            title: "Bot settings…",
            subtitle: botSettingsSubtitle,
            systemImage: "gearshape",
            shortcut: nil,
            group: .chat,
            isEnabled: selectedBot != nil,
            run: { [weak self] in
                guard let self, let bot = self.selectedBot else { return }
                self.openBotSettings(bot)
            }))

        items.append(WorkspaceCommand(
            id: "host.connect",
            title: model.connection.isLive ? "Reconnect to host" : "Connect to host",
            subtitle: pairing.map { "Open the socket to \($0.displayHost)" } ?? "No host paired yet",
            systemImage: "bolt.horizontal",
            shortcut: "⇧⌘R",
            group: .host,
            isEnabled: isPaired,
            run: { [weak self] in
                guard let self else { return }
                Task {
                    if self.model.connection.isLive {
                        await self.reconnect()
                    } else {
                        await self.connect()
                    }
                }
            }))

        items.append(WorkspaceCommand(
            id: "host.disconnect",
            title: "Disconnect",
            subtitle: "Close the socket and keep the pairing",
            systemImage: "bolt.slash",
            shortcut: nil,
            group: .host,
            isEnabled: model.connection.isLive,
            run: { [weak self] in
                guard let self else { return }
                Task { await self.disconnect() }
            }))

        items.append(WorkspaceCommand(
            id: "host.pair",
            title: "Pair host…",
            subtitle: "Enter a wss:// URL and a device token",
            systemImage: "link",
            shortcut: "⇧⌘P",
            group: .host,
            isEnabled: true,
            run: { [weak self] in self?.isPairSheetPresented = true }))

        items.append(WorkspaceCommand(
            id: "chat.refresh",
            title: "Refresh this conversation",
            subtitle: model.activeRoom.map { "Re-read \($0.name) from the host" }
                ?? "Re-open this bot's conversation from the host",
            systemImage: "arrow.triangle.2.circlepath",
            shortcut: "⌘R",
            group: .chat,
            isEnabled: isPaired,
            run: { [weak self] in
                guard let self else { return }
                if self.model.activeRoom != nil {
                    self.model.requestRefresh()
                } else if let bot = self.selectedBot, !self.model.isStreaming {
                    Task { await self.openConversation(for: bot.id) }
                }
            }))

        items.append(WorkspaceCommand(
            id: "bots.add",
            title: "Add bot…",
            subtitle: "Create a profile on the host: name, description, face, SOUL.md",
            systemImage: "plus.circle",
            shortcut: nil,
            group: .bots,
            isEnabled: isPaired,
            run: { [weak self] in self?.isAddBotPresented = true }))

        items.append(WorkspaceCommand(
            id: "bots.manage",
            title: "Manage bots…",
            subtitle: "Hide, disable or delete a bot",
            systemImage: "slider.horizontal.3",
            shortcut: nil,
            group: .bots,
            isEnabled: isPaired,
            run: { [weak self] in self?.isManageBotsPresented = true }))

        items.append(WorkspaceCommand(
            id: "rooms.start",
            title: "Start group chat…",
            subtitle: "Put two to six bots in one room where they answer each other",
            systemImage: "person.3",
            shortcut: nil,
            group: .chat,
            isEnabled: isPaired,
            run: { [weak self] in self?.isStartGroupChatPresented = true }))

        items.append(WorkspaceCommand(
            id: "rooms.list",
            title: "Group chats…",
            subtitle: "The rooms this host hosts",
            systemImage: "bubble.left.and.bubble.right",
            shortcut: nil,
            group: .chat,
            isEnabled: isPaired,
            run: { [weak self] in self?.isGroupChatsPresented = true }))

        for room in model.rooms {
            items.append(WorkspaceCommand(
                id: "room.\(room.id)",
                title: model.activeRoom?.id == room.id ? "✓ \(room.name)" : room.name,
                subtitle: "Group chat · " + room.members.map { "@\($0.mention)" }.joined(separator: " "),
                systemImage: "person.3.fill",
                shortcut: nil,
                group: .chat,
                isEnabled: true,
                run: { [weak self] in self?.model.openRoom(room) }))
        }

        // The bots are a catalogue of their own: one command per profile, disabled for the
        // one already on screen, so switching is reachable without leaving the keyboard.
        // `orderedBots` is the same list the panel draws — pinned first, hidden ones absent.
        for bot in model.orderedBots {
            items.append(WorkspaceCommand(
                id: "bot.\(bot.id)",
                title: "Switch to \(bot.displayName)",
                subtitle: bot.id == model.selectedBotID
                    ? "Current bot · \(bot.id)"
                    : "Bot · \(bot.id)",
                systemImage: "person.crop.circle",
                shortcut: nil,
                group: .bots,
                isEnabled: bot.id != model.selectedBotID && model.connection.isLive,
                run: { [weak self] in self?.selectBot(bot.id) }))
        }

        return items
    }

    private var botSettingsSubtitle: String {
        guard let bot = selectedBot else { return "No bot selected" }
        return "Description and default model for \(bot.displayName)"
    }

    // MARK: Private

    private func startLatencyLoop() {
        stopLatencyLoop()
        latencyTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.model.refreshLatency()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    private func stopLatencyLoop() {
        latencyTask?.cancel()
        latencyTask = nil
    }

    private func restorePreferences() {
        let saved = UserDefaults.standard.double(forKey: WorkspaceStore.widthKey)
        if saved > 0 {
            sidebarWidth = min(Geometry.sidebarMax,
                               max(WorkspaceStore.sidebarFloor, CGFloat(saved)))
        }
    }

    /// The Bot Computer client: one ticket per request, resolved against the host paired *now*.
    var computer: BotComputerClient {
        BotComputerClient(endpoint: { [weak self] in
            guard let address = await MainActor.run(body: { self?.pairing }) else {
                throw MacDeviceService.Failure.devicePairingRequired
            }
            guard !address.isTicketOnly else { throw MacDeviceService.Failure.devicePairingRequired }
            return (try address.apiOrigin(), try await address.mintedTicket())
        })
    }

    /// The workspace client: same minted-ticket-per-request rule as the computer.
    var workspace: WorkspaceClient {
        WorkspaceClient(endpoint: { [weak self] in
            guard let address = await MainActor.run(body: { self?.pairing }) else {
                throw MacDeviceService.Failure.devicePairingRequired
            }
            guard !address.isTicketOnly else { throw MacDeviceService.Failure.devicePairingRequired }
            return (try address.apiOrigin(), try await address.mintedTicket())
        })
    }

    func toggleBotPanel() {
        withAnimation(.easeOut(duration: 0.16)) { isBotPanelPresented.toggle() }
    }

    func toggleComputerPanel() {
        isComputerPanelPresented.toggle()
        if !isComputerPanelPresented { isComputerFullScreen = false }
    }

    /// The one place a real socket is built.
    ///
    /// The transport factory is async and runs once per connection attempt, which is exactly
    /// what the ticket flow needs: **each** attempt mints a fresh single-use ticket, so a
    /// reconnect after a drop does not replay a burned one.
    private static func makeModel(for address: PairingAddress) -> AppModel {
        let client = GatewayClient(
            makeTransport: {
                let socketURL = try await address.socketURL()
                let transport = GatewayTransport(urlProvider: { socketURL })
                return transport.bridge()
            },
            // The bot's conversation pointer lives on the bridge, so this Mac and the phone open
            // the same stored session. Resolved per request: every bridge call needs its own
            // single-use ticket, and a ticket-only pairing has no refresh token to mint one from.
            sessionPointer: BridgeBotSessionPointer(endpoint: {
                guard !address.isTicketOnly else { throw MacDeviceService.Failure.devicePairingRequired }
                let ticket = try await address.mintedTicket()
                return (try address.apiOrigin(), ticket)
            }))
        return AppModel(client: client, hostName: address.displayHost)
    }
}
