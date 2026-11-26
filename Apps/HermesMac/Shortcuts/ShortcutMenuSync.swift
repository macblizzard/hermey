import AppKit
import HermesKit

/// The mechanism that makes a rebound key take effect without a relaunch.
///
/// **Why AppKit.** `.keyboardShortcut` is a *declaration*: SwiftUI turns it into an `NSMenuItem`'s
/// `keyEquivalent` when it builds the menu bar, and the menu bar is AppKit's, not the view tree's. A
/// published change re-evaluates the `Commands` body on SwiftUI's own schedule — usually the next
/// time it rebuilds that scene — which is fine for a launch and useless for a settings window that
/// must feel immediate. So the source of truth is the registry, and this pass writes it into the
/// real items: `NSMenuItem.keyEquivalent` and `keyEquivalentModifierMask` are documented, settable
/// properties, and changing them takes effect on the next key press.
///
/// **How an item is found.** SwiftUI gives a menu item no tag we can match, so the item is found by
/// its *title*. The registry declares every title an item can carry, including the ones that flip
/// with state ("Show Bot Panel" / "Hide Bot Panel"), because a title is the only handle AppKit
/// exposes. The titles are chosen to be unique in the menu bar, and the pass touches nothing it was
/// not told about — no item outside the registry is ever rewritten.
///
/// **When it runs.** Once when the window appears, after every change from the pane, and again
/// whenever the app is activated or an item is added. The last two matter because SwiftUI may
/// rebuild an item (a title that flips with state) and the rebuilt one carries the *default* again;
/// re-applying on activation is what stops a rebound key from quietly reverting.
@MainActor
final class ShortcutMenuSync {

    /// The document to read. Set by ``ShortcutCenter`` before `install()`.
    weak var center: ShortcutCenter?

    /// Notification observers, kept so removing the pass is possible (a test builds it twice).
    private var observers: [NSObjectProtocol] = []
    /// Whether a re-apply is already queued for this runloop turn.
    private var isScheduled = false

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Apply now, and keep applying as the menu bar changes.
    func install() {
        apply()
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // The menu bar is built and rebuilt by SwiftUI at moments this class cannot observe
        // directly; a rebuild that dropped a rebind is repaired the moment the app comes forward.
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.schedule() }
        })
        // An item added anywhere in the bar is a chance for the default to be back.
        observers.append(center.addObserver(forName: NSMenu.didAddItemNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.schedule() }
        })
    }

    /// Write the registry into the menu bar, now.
    func apply() {
        guard let center = self.center, let mainMenu = NSApp.mainMenu else { return }
        for action in ShortcutRegistry.actions {
            // A system-owned row (⌘, Settings) is not ours to rewrite: the `Settings` scene's item
            // dispatches through AppKit, and overwriting its equivalent would break it.
            guard action.owner == .appMenu, !action.menuItemTitles.isEmpty else { continue }
            let combo = center.combo(action.id)
            for item in Self.items(in: mainMenu, titled: action.menuItemTitles) {
                item.keyEquivalent = combo?.menuKeyEquivalent ?? ""
                item.keyEquivalentModifierMask = combo?.menuModifiers ?? []
            }
        }
    }

    /// Coalesce a burst of notifications into one pass on the next runloop turn.
    private func schedule() {
        guard !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isScheduled = false
            self.apply()
        }
    }

    /// Every item in `menu` (and its submenus) whose title is one of `titles`, in menu order.
    ///
    /// Static and pure so the walk can be tested against a menu built by hand, without an app.
    static func items(in menu: NSMenu, titled titles: [String]) -> [NSMenuItem] {
        var found: [NSMenuItem] = []
        for item in menu.items {
            if titles.contains(item.title) { found.append(item) }
            if let submenu = item.submenu { found.append(contentsOf: items(in: submenu, titled: titles)) }
        }
        return found
    }
}
