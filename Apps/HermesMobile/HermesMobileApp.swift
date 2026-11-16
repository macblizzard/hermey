import SwiftUI
import HermesKit
import HermesAppKit
import HermeyUI

/// iOS shell.
///
/// Native chrome only — `TabView`, `NavigationStack`, `.searchable`, `.toolbar`, `.sheet` —
/// because the platform's smoothness lives there: interactive pop, rubber-band scrolling,
/// keyboard avoidance and the system tab bar. Nothing here draws a fake navigation bar or
/// imitation glass.
///
/// One screen at the root, because there is one thing the app does: talk to a bot. The bot
/// directory *is* the app — no drawer, no hidden switcher, no session list
/// (`docs/ENDLESS-CHAT.md` §1) — and the app's own Settings hang off the list's menu rather than
/// a floating Bots/Settings pill along the bottom edge.
@main
struct HermesMobileApp: App {
    @StateObject private var app = AppEnvironment()

    /// Background-refresh registration has to happen before the app finishes launching, or iOS
    /// drops the request and a suspended app never learns that a bot replied.
    init() {
        ReplyBackgroundRefresh.register()
    }

    var body: some Scene {
        WindowGroup {
            // The app, with the launch screen over it until it is usable. One gate for both shells:
            // `LaunchGateView` owns the `LaunchReadiness` decision, `BootScreen` is only its picture,
            // and the bot list underneath is drawn from the first frame so the fade uncovers rows
            // rather than an empty box.
            LaunchGateView(model: app.model,
                           isPaired: { app.isPaired },
                           fadeOut: BootScreen.fadeOutDuration,
                           // The card is held until the splash has gone, so an update found during
                           // boot appears on the list rather than behind the logo.
                           onContentRevealed: { app.updates.shellDidReveal() }) {
                BootScreen()
            } content: {
                RootView()
            }
                .environmentObject(app)
                .preferredColorScheme(.dark)
                .task {
                    ThemeRuntime.restoreFromDefaults()
                    TypeScale.restoreScale()
                    await app.start()
                    // After `start()`, so the badge is set from a count the host has answered.
                    app.startReplyNotifications()
                }
                // Its own task, not a step inside `start()`: the feed is a public URL and the app
                // must be usable before it answers. An unreachable feed is a no-op (see
                // `UpdateChecker`), so first paint never waits on it.
                //
                // `atLaunch`: every cold start asks, rather than once per 24 h. The check runs while
                // the splash is up and its answer is presented the moment the splash leaves, so a
                // person who opens the app is told about a new build without going looking for it.
                // A build they already answered "Not now" to stays answered until a newer one
                // appears — that is what keeps this from being a nag on every launch.
                .task { await app.updates.check(atLaunch: true) }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase

    /// Re-created when the theme changes, so the whole tree reads the new palette. The connection
    /// lives in `AppEnvironment`, which this does not touch.
    @AppStorage(ThemeRuntime.defaultsKey) private var themeID: String = ThemeCatalog.defaultID

    var body: some View {
        // One screen at the root: the bot list. The floating Bots/Settings pill at the bottom was a
        // tab bar wearing a pill's clothes — the bots *are* the app, and Settings has a door in the
        // list's own menu.
        BotsTab(model: app.model)
            // The whole tree is re-created on a theme change: every colour is read at draw time,
            // and a fresh subtree is the one guarantee that none of them kept the old palette.
            .id(themeID)
            .tint(Tokens.accent)
            .sheet(isPresented: $app.isPairingPresented) {
                PairingSheet()
                .hermesSheetChrome()
            }
            .onChange(of: app.model.badgeCount) { _, count in
                // The icon badge follows every change, not just new banners: reading a chat clears
                // its count without a reply arriving while the app is away.
                MobileReplyNotifier.shared.updateBadge(count)
            }
            .onChange(of: scenePhase) { phase in
                // A phone comes back from the background with a dead socket; reconnect once
                // rather than waiting for the user to shake it. A host the user disconnected on
                // purpose stays disconnected — that is a choice, not a dropped socket.
                if phase == .background { app.appDidEnterBackground() }
                // The update check is this build's business, not the host's: it runs on every
                // foreground whether or not a phone is paired. `check` throttles itself to once a
                // day, so a phone that is unlocked fifty times costs one request.
                if phase == .active { Task { await app.updates.check() } }
                guard phase == .active, app.isPaired, !app.isDisconnectedByUser else { return }
                MobileReplyNotifier.shared.refreshAuthorization()
                Task {
                    if app.model.connection.isLive { await app.loadBotFaces() }
                    else { await app.reconnect() }
                }
            }
            // The card is advisory and sits over the app; nothing below it is disabled or hidden.
            .updatePrompt(app.updates)
    }
}

/// The bots tab owns its own navigation path so switching tabs keeps the pushed
/// conversation where the user left it.
///
/// One conversation per bot is the whole model, so the path holds a `Bot` and nothing else:
/// there is no session to address, and going back is the only way out of a thread.
struct BotsTab: View {
    @ObservedObject var model: AppModel
    /// Bot faces live in the environment (they are fetched and cached there), so a pushed room
    /// reads them from the same place the list does.
    @EnvironmentObject private var app: AppEnvironment
    /// Whether the app is on screen. A phone that is locked or in another app is not reading this
    /// chat, and the host must not be told otherwise — that claim is what mutes a bot's banners.
    @Environment(\.scenePhase) private var scenePhase
    @State private var path = NavigationPath()
    /// The room's voice: the same host TTS a conversation uses, in its own controller because a
    /// room never records and must not share a session with a conversation.
    @StateObject private var roomVoice = VoiceController()

    /// Render and upload each bot's face — only when a relay is registered.
    ///
    /// A method rather than a closure inside `.task`: inline, the nested `@MainActor` closure and the
    /// `??` chain together outrun the type checker ("unable to type-check in reasonable time").
    private func uploadPushFaces() async {
        let faces = app.botFaces
        // The banners' own pictures first: they are wanted whether or not a relay is registered.
        await MobileFaceCache.refresh(faces: faces)
        guard let relay = UserDefaults.standard.string(forKey: PushRelay.urlKey), !relay.isEmpty else {
            return
        }
        await model.syncPushIcons { id in
            // The stored face when there is one; otherwise the one this bot's id draws.
            PushIcon.png(for: id, color: faces[id]?.raw)
        }
    }

    /// A banner's tap: `hermey://bot/<profile>` lands on that bot's conversation.
    ///
    /// The relay app (Bark) cannot deep-link into a view it knows nothing about, so the URL is the
    /// whole contract. An unknown or stale bot is ignored rather than pushed as an empty thread.
    private func openBannerURL(_ url: URL) {
        guard url.scheme == "hermey", url.host == "bot" else { return }
        let id = url.lastPathComponent
        guard !id.isEmpty, let bot = model.bots.first(where: { $0.id == id }) else { return }
        path = NavigationPath()
        path.append(bot)
    }

    var body: some View {
        NavigationStack(path: $path) {
            BotListScreen(model: model,
                          onGraphite: { path.append($0) },
                          onOpenRoom: { path.append($0) })
                .navigationDestination(for: Bot.self) { bot in
                    ConversationScreen(model: model, bot: bot)
                }
                // A room pushes like a bot's conversation: same stack, same back gesture, and the
                // list keeps its scroll position underneath instead of being covered by a modal.
                .onOpenURL { openBannerURL($0) }
                .onChange(of: scenePhase) { _, phase in
                    // Leaving the app releases the claim; coming back re-makes it for whatever chat
                    // is showing. Without this a chat left open at lock time silenced that bot until
                    // the app was reopened (a reply went unheard for eight hours).
                    Task { await model.reportPresence(bot: phase == .active ? model.selectedBotID : nil) }
                }
                // A banner shows the bot's own face; the host holds the render, not the geometry.
                .task { await uploadPushFaces() }
                .navigationDestination(for: RoomSummary.self) { room in
                    RoomChatView(
                        room: room,
                        icons: app.botFaces,
                        presentation: .pushed,
                        load: { roomID, since in try await model.roomPage(roomID, since: since) },
                        send: { roomID, text, files in
                            try await model.sendRoomMessage(roomID, text: text, attachments: files)
                        },
                        onActivity: { Task { await model.refreshRooms() } },
                        onLatestSeq: { model.markRoomRead(room.id, seq: $0) },
                        onRename: { name in try await model.renameRoom(room.id, to: name) },
                        renameSignal: $model.renameRequest,
                        speak: { try await roomVoice.speakAndWait($0) },
                        markdown: { markdownMessage($0) })
                }
        }
        .task { roomVoice.transport = app.makeVoiceTransport() }
        .onChange(of: app.store.host?.baseURL) { _, _ in roomVoice.transport = app.makeVoiceTransport() }
        // A tapped banner names the bot it was about. The list pushes it like a row press, then
        // clears the request — a tap is an event and must not re-open the bot on every redraw.
        .onChange(of: app.botToOpenRequest) { _, request in
            guard let request, let bot = model.bots.first(where: { $0.id == request }) else {
                app.botToOpenRequest = nil
                return
            }
            path.append(bot)
            app.botToOpenRequest = nil
        }
        .badge(model.pendingRequests.count)
    }
}

struct SettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            SettingsScreen(model: model)
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Root · paired") {
    let environment = AppEnvironment.preview()
    RootView()
        .environmentObject(environment)
        .preferredColorScheme(.dark)
        .task { await environment.start() }
}
#endif

#if DEBUG
#Preview("Root · unpaired") {
    let environment = AppEnvironment.preview(paired: false)
    RootView()
        .environmentObject(environment)
        .preferredColorScheme(.dark)
}
#endif
