import HermesAppKit
import OpenBotUI
import SwiftUI

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

    var body: some Scene {
        WindowGroup("Hermey") {
            WorkspaceRoot(store: store)
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
                    await store.attachFixtureHostIfNeeded()
                    await store.connectOnLaunchIfPaired()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 840)
        .commands {
            WorkspaceCommands(store: store)
        }

        // A real Settings scene: ⌘, opens it, and it stays open beside the workspace instead of
        // stacking a third modal sheet over the window the user is trying to read.
        Settings {
            MacSettingsView(store: store)
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

            Button(store.isSidebarHidden ? "Show Bot Panel" : "Hide Bot Panel") {
                store.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: .command)

            Divider()

            Button("Bot Settings…") {
                guard let bot = store.selectedBot else { return }
                store.openBotSettings(bot)
            }
            .disabled(store.selectedBot == nil)

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
