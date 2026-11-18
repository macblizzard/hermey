import HermesAppKit
import HermeyUI
import SwiftUI
import os

#if canImport(Sparkle)
import Sparkle
#endif

/// macOS window: **bot panel on the left, chat on the right** — the phone's two-pane shape, with
/// no session list and no inspector column. The bot panel defaults to 280 pt and drags between
/// 200 and 400; the conversation takes the rest on a 640 pt measure (`Geometry`).
///
/// Launch is offline by construction: `WorkspaceStore` restores the pairing it was given
/// last time but dials nothing, and the only calls into `connect()` are the Connect button,
/// the palette's verb and the pair sheet's Pair press.
@main
struct HermesMacApp: App {
    /// Ordinary launch: `WorkspaceStore()`, which restores whatever was paired last time.
    /// UI-test launch: a frozen, offline store built by `UITestFixture`, which is only ever
    /// reachable through the two launch arguments it checks (see that file). The store and the
    /// one `.task` below are the entire hook; nothing else about the window changes.
    @StateObject private var store = UITestFixture.storeForLaunch()

    /// Sparkle's controller, owned by the app for its whole lifetime: one that falls out of scope
    /// stops its scheduled cycle, and the menu's verb then does nothing. `startingUpdater: true`
    /// begins the daily check declared by `SUFeedURL`/`SUScheduledCheckInterval` in Info.plist.
    ///
    /// Its prompt is Sparkle's own and it is dismissible, so an available build never blocks or
    /// gates the workspace — nothing here disables a feature behind "update first". A tampered DMG
    /// fails the EdDSA check against `SUPublicEDKey` and Sparkle aborts with a visible error; there
    /// is no installer of ours to get that wrong.
    #if canImport(Sparkle)
    private let updater = SPUStandardUpdaterController(startingUpdater: true,
                                                       updaterDelegate: nil,
                                                       userDriverDelegate: nil)
    #endif

    /// The one action the menu and Settings → About share. It is a closure rather than the
    /// controller so both callers stay ignorant of Sparkle, and so a tree built without the package
    /// still compiles — the item is simply inert there.
    private var checkForUpdates: () -> Void {
        #if canImport(Sparkle)
        return { self.updater.checkForUpdates(nil) }
        #else
        return {}
        #endif
    }

    /// One background check per launch, whatever Sparkle's own schedule says.
    ///
    /// `SUEnableAutomaticChecks` with `SUScheduledCheckInterval: 86400` means "at most once a day",
    /// so a Mac restarted after a release could sit on the old build until tomorrow. A cold start is
    /// the moment a person expects to be told, so it asks. `checkForUpdatesInBackground` is the
    /// silent variant — Sparkle still draws its own dismissible prompt when it finds something, and
    /// nothing here installs, gates or blocks: the workspace is usable throughout.
    /// Subsystem for the one thing about updates that has to be observable from outside the app.
    ///
    /// `SULastCheckTime` in the app's defaults says *that* a check happened; this says that the launch
    /// path asked for one, which is the difference between "Sparkle's scheduler ran at some point" and
    /// "opening the app asks". Read it with:
    /// `log show --last 1h --predicate 'subsystem == "dev.hermey.app.mac" and category == "updates"'`.
    private let updateLog = Logger(subsystem: "dev.hermey.app.mac", category: "updates")

    private func checkForUpdatesAtLaunch() {
        #if canImport(Sparkle)
        updateLog.notice("launch check requested (running \(AppVersion.label, privacy: .public))")
        updater.updater.checkForUpdatesInBackground()
        #else
        updateLog.notice("launch check skipped: built without Sparkle")
        #endif
    }

    var body: some Scene {
        WindowGroup("Hermey") {
            // The window root, with the launch screen over it until the app is usable. The gate is
            // `LaunchGateView` (the readiness decision) and the picture is `BootScreen`; the shell
            // underneath is built from the first frame, so the fade uncovers the workspace rather
            // than an empty panel. An unpaired Mac never sees the splash at all: the gate leaves at
            // once for the pair UI, which is what this window *is* on a fresh install.
            LaunchGateView(model: store.model,
                           isPaired: { store.isPaired },
                           fadeOut: BootScreen.fadeOutDuration) {
                BootScreen()
            } content: {
                WorkspaceRoot(store: store)
            }
                // The shell lays out exactly this much chrome around the conversation: the bot
                // panel at its floor, the divider strip and its hairline, and — when it is open —
                // the bot's own panel or the shared computer. There is no surround: the shell
                // reaches the window edge on every side.
                // The minimum is the arrangement's, not one pane's: opening the shared computer adds
                // a pane and a hairline, and a window held to the two-pane sum clipped both edges.
                .frame(minWidth: store.minimumWindowWidth, minHeight: WindowLayout.heightMin)
                .preferredColorScheme(.dark)
                // A paired host is dialled at launch: the app opens the last conversation instead
                // of asking to be connected to one it already knows. `attachFixtureHostIfNeeded`
                // is a no-op unless the fixture launch argument was given.
                .task {
                    // The palette's "Check for updates…" runs the same closure the menu bar and
                    // Settings → About run; the store never learns what Sparkle is.
                    store.checkForUpdates = checkForUpdates
                    await store.attachFixtureHostIfNeeded()
                    await store.connectOnLaunchIfPaired()
                    // Last, so dialling the host is not delayed by the feed.
                    checkForUpdatesAtLaunch()
                    // Then warm every bot's conversation behind the window, so switching bots
                    // paints instead of waiting on a resume.
                    await store.model.prefetchConversations()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 840)
        .commands {
            WorkspaceCommands(store: store, checkForUpdates: checkForUpdates)
        }

        // A real Settings scene: ⌘, opens it, and it stays open beside the workspace instead of
        // stacking a third modal sheet over the window the user is trying to read.
        Settings {
            MacSettingsView(store: store, checkForUpdates: checkForUpdates)
        }

        // The takeover indicator: always present, because "a bot may drive this Mac" is a fact about
        // the machine rather than a fact about the window that happens to be open.
        MenuBarExtra {
            ComputerControlMenu()
        } label: {
            ComputerControlMenuBarLabel()
        }

        Window("Paired Devices", id: "paired-devices") {
            MacDevicesView(store: store)
        }
        .defaultSize(width: 560, height: 440)
    }
}

/// The menu bar: everything the palette offers that also deserves a key.
///
/// Kept as a plain reference rather than an observed object — menu items read the store when
/// they are chosen (the closure), which is the only moment that has to be right.
struct WorkspaceCommands: Commands {
    let store: WorkspaceStore
    /// The app's updater as an action: the controller itself is the `App`'s, and a second one in
    /// here would start a second check cycle against the same feed.
    let checkForUpdates: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // The app menu's About item: replaced so it reports this build's version — the app is
        // sideloaded unsigned, so the bundle's own numbers are the only truth about which build
        // is running, and the stock panel showed a placeholder without them.
        CommandGroup(replacing: .appInfo) {
            Button("About Hermes") {
                AppVersion.showStandardPanel()
            }
        }

        // Directly under About, where macOS apps have always put it: the manual half of the daily
        // check. Sparkle draws the "you're up to date" / "new version" panel itself, and an
        // in-flight download can be cancelled from it, so the app stays usable either way.
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                checkForUpdates()
            }
        }

        // No "New Session": a bot has exactly one conversation, so there is nothing to create.
        CommandGroup(replacing: .newItem) {
            Button("Pair Host…") {
                store.isPairSheetPresented = true
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Button("Manage Paired Devices…") {
                openWindow(id: "paired-devices")
            }
        }

        // ⌘+ / ⌘- / ⌘0 — the platform's own keys for "bigger, smaller, normal". Every size in the
        // app is read at draw time, so the shell is re-created exactly as a theme change does it.
        CommandGroup(after: .sidebar) {
            Button("Bigger Text") { store.stepTextSize(1) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Smaller Text") { store.stepTextSize(-1) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Default Text Size") { store.resetTextSize() }
                .keyboardShortcut("0", modifiers: .command)
        }

        CommandMenu("Conversation") {
            Button("Send Message") {
                store.send()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!store.canSend)

            Button("Interrupt Turn") {
                store.interrupt()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!store.canInterrupt)

            Divider()

            // ⌘F — find inside the conversation on screen. It lives in the menu because a key you
            // cannot see is a key you cannot learn: the transcript has carried a hidden ⌘F for a
            // while, and the sidebar's field was mistaken for this search instead (reported
            // 2026-11-15). The sidebar's field asks the host about every bot's conversation too,
            // and lists the findings; this puts the reader on the row inside the transcript on
            // screen, from a bar over it.
            Button("Find in Conversation…") {
                store.openFindInChat()
            }
            .keyboardShortcut("f", modifiers: .command)

            Divider()

            Button(store.isSidebarHidden ? "Show Bot Panel" : "Hide Bot Panel") {
                store.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: .command)

            Divider()

            Button("Bot Settings…") {
                guard let bot = store.selectedBot else { return }
                store.openSettings(for: bot)
            }
            .disabled(store.selectedBot == nil)

            // ⌘E — the bot's panel on the right edge, the same panel the pill at the centre of the
            // header opens. The key is the keyboard's copy of the pill, not a second door to a
            // per-row menu: the panel *is* the menu, and it is the only place these verbs live on
            // this shell.
            //
            // The action checks the selection rather than the item being disabled: `store` here is a
            // plain reference, so a `.disabled` gate is whatever the roster was when the menu was
            // built — "no bots yet" at launch — and a disabled item swallows its key equivalent for
            // the rest of the run. Pressing ⌘E before a bot arrives does nothing, quietly, instead
            // of killing the shortcut.
            Button(store.isBotPanelVisible ? "Hide Bot Actions" : "Show Bot Actions") {
                guard store.model.selectedBotID != nil else { return }
                store.toggleBotPanel()
            }
            .keyboardShortcut("e", modifiers: .command)

            Menu("Switch Bot") {
                ForEach(store.model.orderedBots) { bot in
                    Button(bot.id == store.model.selectedBotID
                           ? "✓ \(bot.displayName)"
                           : bot.displayName) {
                        store.selectBot(bot.id)
                    }
                    .disabled(!store.model.connection.isLive)
                }
            }
            .disabled(store.model.orderedBots.isEmpty)

            Divider()

            Button(store.model.connection.isLive ? "Disconnect" : "Connect") {
                Task {
                    if store.model.connection.isLive {
                        await store.disconnect()
                    } else {
                        await store.connect()
                    }
                }
            }
            .disabled(!store.isPaired)

            Divider()

            Button("Command Palette…") {
                store.togglePalette()
            }
            .keyboardShortcut("k", modifiers: .command)
        }

        // Settings… and Quit come from the standard groups: the `Settings` scene above owns ⌘,.
    }
}
