import AppKit
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
    ///
    /// Built in `init` rather than in this property's own initializer for one reason: the updater's
    /// delegate has to be handed the store before the updater starts, and one stored property cannot
    /// see another while it is being initialized.
    @StateObject private var store: WorkspaceStore

    #if canImport(Sparkle)
    /// The standard user driver's delegate *and* the updater's: the launch check reports what it
    /// found here instead of opening a window, and the bot panel's floor bar draws it.
    private let updateReminder: UpdateReminder

    /// Sparkle's controller, owned by the app for its whole lifetime: one that falls out of scope
    /// stops its scheduled cycle, and the menu's verb then does nothing. `startingUpdater: true`
    /// begins the daily check declared by `SUFeedURL`/`SUScheduledCheckInterval` in Info.plist.
    ///
    /// Both delegate slots are `updateReminder`. Its verdict on a *scheduled* check is "no" — the
    /// panel offers the update on its floor bar, so nothing is drawn at boot — and it has no say on
    /// a user-initiated one, which the standard driver always handles. Its prompt stays Sparkle's
    /// own and stays dismissible, so an available build never blocks or gates the workspace; nothing
    /// here disables a feature behind "update first". A tampered DMG fails the EdDSA check against
    /// `SUPublicEDKey` and Sparkle aborts with a visible error; there is no installer of ours to get
    /// that wrong.
    private let updater: SPUStandardUpdaterController
    #endif

    init() {
        // No window in this app is ever a tab, and AppKit still put "Show Tab Bar" and "Show All
        // Tabs" in the View menu — items that light up, do nothing useful, and sit above the text
        // size entries the owner actually uses. The switch is process-wide and only honoured when
        // it is set **before the first window exists**, which is here: `App.init` runs ahead of any
        // scene's window. `WindowTabMenu.purge()` is the belt for a build that grew one anyway.
        NSWindow.allowsAutomaticWindowTabbing = false

        let store = UITestFixture.storeForLaunch()
        #if canImport(Sparkle)
        // Before the controller exists, so the launch check's first answer has somewhere to land:
        // Sparkle calls this on the main thread, and the store is the panel's one source for
        // "a version is waiting".
        let reminder = UpdateReminder()
        reminder.onUpdate = { [weak store] version in store?.offerUpdate(version) }
        updateReminder = reminder
        updater = SPUStandardUpdaterController(startingUpdater: true,
                                               updaterDelegate: reminder,
                                               userDriverDelegate: reminder)
        #endif
        _store = StateObject(wrappedValue: store)
    }

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

    /// Subsystem for the one thing about updates that has to be observable from outside the app.
    ///
    /// `SULastCheckTime` in the app's defaults says *that* a check happened; this says that the launch
    /// path asked for one, which is the difference between "Sparkle's scheduler ran at some point" and
    /// "opening the app asks". Read it with:
    /// `log show --last 1h --predicate 'subsystem == "dev.hermey.app.mac" and category == "updates"'`.
    private let updateLog = Logger(subsystem: "dev.hermey.app.mac", category: "updates")

    /// One background check per launch, whatever Sparkle's own schedule says.
    ///
    /// `SUEnableAutomaticChecks` with `SUScheduledCheckInterval: 86400` means "at most once a day",
    /// so a Mac restarted after a release could sit on the old build until tomorrow. A cold start is
    /// the moment a person expects to be told, so it asks — and now it asks **quietly**. The call is
    /// the same silent `checkForUpdatesInBackground()` it always was; the change is on the other side
    /// of it, where `UpdateReminder` answers "no" to showing a scheduled update, so no window opens
    /// over the workspace at boot. What it finds becomes the bot panel's update glyph, and a check
    /// that finds nothing leaves the panel exactly as it was. Nothing here installs, gates or
    /// blocks: the workspace is usable throughout, and no update is installed without a press.
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
                .hermesThemeChrome()
                // The View menu is built and shown with this window; anything AppKit inserted on
                // its own is dropped here, once, so "Show Tab Bar" cannot come back.
                .onAppear { WindowTabMenu.purge() }
                // A paired host is dialled at launch: the app opens the last conversation instead
                // of asking to be connected to one it already knows. `attachFixtureHostIfNeeded`
                // is a no-op unless the fixture launch argument was given.
                .task {
                    // The palette's "Check for updates…" runs the same closure the menu bar and
                    // Settings → About run; the store never learns what Sparkle is.
                    store.checkForUpdates = checkForUpdates
                    await store.attachFixtureHostIfNeeded()
                    await store.connectOnLaunchIfPaired()
                    // Computer use is a standing decision, not a screen. The switch was already on
                    // when this launch began, so the socket has to come up here: the only other
                    // caller is the Settings view's `.task`, which meant the Mac sat unreachable
                    // until the owner opened Settings — and looked like "computer use isn't
                    // activated" every time the app restarted. `pairingChanged` is idempotent and
                    // no-ops when the switch is off or a loop is already live.
                    LocalComputerService.shared.pairingChanged(address: store.pairing)
                    // Last, so dialling the host is not delayed by the feed.
                    checkForUpdatesAtLaunch()
                    // Then warm every bot's conversation behind the window, so switching bots
                    // paints instead of waiting on a resume. The model owns the task so a click on
                    // a bot can stand the walk down the way a tap does on the phone.
                    store.model.startPrefetch()
                    // Last of the launch work: the menu bar exists by now, so the AppKit pass can
                    // write the owner's own combinations into the real items. `Commands` already
                    // reads the registry, so this is the guarantee rather than the first attempt —
                    // see `ShortcutMenuSync`.
                    store.shortcuts.installMenuSync()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 840)
        .commands {
            WorkspaceCommands(store: store, checkForUpdates: checkForUpdates, shortcuts: store.shortcuts)
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
/// **Every key in here comes from `ShortcutRegistry`.** This file used to spell each combination by
/// hand, in a dozen `.keyboardShortcut` declarations — which made the menu bar the second copy of the
/// truth and the ⌘K palette the third. That modifier still reaches the screen, because it is what
/// turns a `Button` into an `NSMenuItem` carrying a key equivalent, but the value it is given is read
/// from the registry through ``hermeyShortcut(_:using:)``. Anything that is not a registry row (a
/// window verb from a standard group) keeps its own declaration.
///
/// **Why `shortcuts` is observed.** A `Commands` body that reads an observed object is re-evaluated
/// when that object publishes, so a fresh launch comes up with the owner's keys already in place.
/// It is not enough on its own — AppKit keeps the item once built, and SwiftUI rebuilds on its own
/// schedule — which is why `ShortcutMenuSync` also writes the equivalent into the real item the
/// moment a binding changes. The two together are why a rebind takes effect without a relaunch.
struct WorkspaceCommands: Commands {
    let store: WorkspaceStore
    /// The app's updater as an action: the controller itself is the `App`'s, and a second one in
    /// here would start a second check cycle against the same feed.
    let checkForUpdates: () -> Void
    /// The keyboard's one source of truth — the same object Settings → Shortcuts edits.
    @ObservedObject var shortcuts: ShortcutCenter
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
            .hermeyShortcut("app.checkForUpdates", using: shortcuts)
        }

        // No "New Session": a bot has exactly one conversation, so there is nothing to create.
        CommandGroup(replacing: .newItem) {
            Button("Pair Host…") {
                store.isPairSheetPresented = true
            }
            .hermeyShortcut("host.pair", using: shortcuts)

            Button("Manage Paired Devices…") {
                openWindow(id: "paired-devices")
            }
        }

        // ⌘+ / ⌘- / ⌘0 — the platform's own keys for "bigger, smaller, normal". Every size in the
        // app is read at draw time, so the shell is re-created exactly as a theme change does it.
        CommandGroup(after: .sidebar) {
            Button("Bigger Text") { store.stepTextSize(1) }
                .hermeyShortcut("text.bigger", using: shortcuts)
            Button("Smaller Text") { store.stepTextSize(-1) }
                .hermeyShortcut("text.smaller", using: shortcuts)
            Button("Default Text Size") { store.resetTextSize() }
                .hermeyShortcut("text.default", using: shortcuts)
        }

        CommandMenu("Conversation") {
            Button("Send Message") {
                store.send()
            }
            .hermeyShortcut("turn.send", using: shortcuts)
            .disabled(!store.canSend)

            Button("Interrupt Turn") {
                store.interrupt()
            }
            .hermeyShortcut("turn.interrupt", using: shortcuts)
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
            .hermeyShortcut("chat.find", using: shortcuts)

            // ⌘R — the palette has advertised this since it existed and nothing was bound to it.
            Button("Refresh Conversation") {
                store.refreshConversation()
            }
            .hermeyShortcut("chat.refresh", using: shortcuts)
            .disabled(!store.isPaired)

            // ⌘⇧M — the keyboard's door to a message's verbs, and it replaces the `⋯` that used to
            // sit under every message. The right-click menu is the row's menu now; this opens that
            // same `NSMenu` for the row Tab is on (or the newest message when no row holds focus), so
            // nothing a mouse can reach — Select Text, Read Aloud, Add Reaction, Share, Copy, Edit and
            // resend, Delete — became unreachable to the keyboard. Not `.disabled` when there is no
            // conversation: a disabled item swallows its key equivalent for the rest of the run (the
            // lesson ⌘E already carries), and the transcript is the only thing that knows whether a
            // row can answer.
            Button("Message Actions…") {
                MessageMenuDirectory.requestActions()
            }
            .hermeyShortcut("message.actions", using: shortcuts)

            Divider()

            Button(store.isSidebarHidden ? "Show Bot Panel" : "Hide Bot Panel") {
                store.toggleSidebar()
            }
            .hermeyShortcut("view.sidebar", using: shortcuts)

            Divider()

            Button("Bot Settings…") {
                guard let bot = store.selectedBot else { return }
                store.openSettings(for: bot)
            }
            .hermeyShortcut("bot.settings", using: shortcuts)
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
            .hermeyShortcut("view.botPanel", using: shortcuts)

            Divider()

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

            // ⌥⌘↓ / ⌥⌘↑ — the same walk, one press at a time. Not disabled with the list: a key
            // equivalent on a disabled item stops working for the rest of the run, and the store
            // checks the roster itself.
            Button("Next Bot") {
                store.stepBot(1)
            }
            .hermeyShortcut("bot.next", using: shortcuts)

            Button("Previous Bot") {
                store.stepBot(-1)
            }
            .hermeyShortcut("bot.previous", using: shortcuts)

            Divider()

            // The message verbs, on the last message rather than on a row: the transcript's own
            // right-click menu still offers them on any message, and both doors call the same model
            // methods. Never disabled — each one does nothing when there is no message to act on,
            // which is quieter than a greyed row that swallows its key.
            Button("Copy Last Message") {
                store.copyLastMessage()
            }
            .hermeyShortcut("message.copyLast", using: shortcuts)

            Button("Edit Last Message") {
                store.editLastMessage()
            }
            .hermeyShortcut("message.editLast", using: shortcuts)

            Button("Delete Last Message") {
                store.deleteLastMessage()
            }
            .hermeyShortcut("message.deleteLast", using: shortcuts)

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
            .hermeyShortcut("host.connect", using: shortcuts)
            .disabled(!store.isPaired)

            Divider()

            Button("Command Palette…") {
                store.togglePalette()
            }
            .hermeyShortcut("palette.open", using: shortcuts)
        }

        // Settings… and Quit come from the standard groups: the `Settings` scene above owns ⌘,.
    }
}
