import AppKit
import HermeyUI
import SwiftUI

/// The Mac's message menu, presented by AppKit.
///
/// **Why this exists.** Every row of a message menu is a `MessageMenuItem` — title, symbol, verb —
/// and `MessageMenuRow` draws that description on the phone, where the glyph shows. On the Mac the
/// same `Label(title, systemImage:)` inside a `contextMenu` came out as a bare title: SwiftUI's
/// menu on macOS takes the button's title and does not carry its image into the `NSMenuItem` it
/// builds, so every row lost its glyph except `Share` (a `ShareLink`, whose image the system
/// supplies). No label style, tint or `LabelStyle` reaches inside that menu — it is built after our
/// code has finished. So the Mac builds the menu itself: `NSMenuItem.image` is the documented
/// place for a menu glyph, and it cannot be dropped on the way to the screen.
///
/// **Where the click comes from.** This view is an overlay on the row and is never a hit target
/// (`hitTest` returns nil), so text selection, links, thumbnails and the hover glyphs underneath
/// keep their presses. The right-click is taken from the window's own event stream — one local
/// monitor per row, installed while the row is in a window — so it does not depend on SwiftUI's hit
/// testing, on where SwiftUI decides the row's content begins, or on `.contextMenu` at all. A
/// click inside these bounds is consumed (`nil` is returned from the monitor), which is also what
/// stops a second, iconless menu from appearing behind ours.
///
/// **The keyboard.** There is no `⋯` on the row any more (asked for 2026-11-26: the right-click menu
/// *is* the row's menu). The keyboard's door is instead the menu bar's **Message Actions…** (⌘⇧M,
/// `WorkspaceCommands`): it posts `Notification.Name.messageActionsRequested`, the transcript asks
/// `MessageMenuDirectory` for the menu of the row Tab is on and raises that same `NSMenu` below it.
/// Once open it is a real `NSMenu`, so arrows, Return and Escape behave as in any Mac menu — and
/// every row is a Tab stop, so a keyboard-only reader still names a message before opening it.
struct MessageContextMenu: NSViewRepresentable {
    /// The rows, in order, from the shared `MessageMenuItem` description.
    var items: [MessageMenuItem]
    /// The row's handle on the view AppKit built, so its `⋯` can raise the same menu.
    var anchor: MessageMenuAnchor? = nil

    typealias Coordinator = Void

    func makeNSView(context: Context) -> NSView {
        let view = MessageMenuHostView(items: items)
        anchor?.host = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? MessageMenuHostView else { return }
        // Rows change with the message they describe (a second message is speaking, a reaction was
        // added or removed). The view survives, so only the description is swapped.
        view.items = items
        anchor?.host = view
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        (nsView as? MessageMenuHostView)?.stop()
    }
}

/// The row's handle on the AppKit view behind `MessageContextMenu`, so something outside the row can
/// raise the same menu. Weak: the view owns its own lifetime, and a row that scrolls away must not
/// leave a menu that can still be opened. Deliberately outside the main actor so a row can hold one
/// in `@State`; the raise is AppKit work and a button's action runs on the main thread.
final class MessageMenuAnchor {
    weak var host: MessageMenuHostView?

    /// True when the row's AppKit view is in a window — the only state in which its menu can be
    /// raised. `MessageMenuDirectory` asks this before it promises a menu.
    var isReady: Bool { host != nil }
}

/// Every built row's menu, by message id — the menu bar's way into a row it does not own.
///
/// The row presents its own `NSMenu` (see `MessageContextMenu`), so only the row can raise it. A
/// menu-bar command has no row: it has a *name* for one — the row the keyboard is on. This is the
/// one map between those two facts, filled by the rows themselves as a `LazyVStack` builds and
/// tears them down, and it holds anchors weakly through `MessageMenuAnchor.host`.
///
/// A row that is not built is not here, which is the correct answer: a message scrolled out of the
/// lazy stack has no menu on screen to raise, and `present(for:)` returning `false` is that fact
/// rather than a crash or a menu pointing at nothing.
final class MessageMenuDirectory {
    static let shared = MessageMenuDirectory()

    private var anchors: [String: MessageMenuAnchor] = [:]

    /// A row entered the view tree: its menu is now reachable by name.
    func register(_ anchor: MessageMenuAnchor, for row: String) {
        anchors[row] = anchor
    }

    /// A row left the view tree. Only its own anchor is removed — a rebuilt row registers its new
    /// one, and a scroll must not leave a dead anchor answering for a live id.
    func unregister(_ row: String) {
        anchors[row] = nil
    }

    /// Raise the menu of `row`, below the row. `false` when that row is not on screen.
    @discardableResult
    func present(for row: String?) -> Bool {
        guard let row, let anchor = anchors[row], anchor.isReady, let host = anchor.host else {
            return false
        }
        host.presentBelow()
        return true
    }

    /// The menu bar's *Message Actions…* (⌘⇧M). Posted rather than called so the command needs no
    /// reference to the pane: the transcript on screen is the only thing that answers, and it owns
    /// the decision about which row the keyboard means.
    static func requestActions() {
        NotificationCenter.default.post(name: .messageActionsRequested, object: nil)
    }
}

extension Notification.Name {
    /// ⌘⇧M, from the Conversation menu. `MessageMenuDirectory.requestActions()` posts it.
    static let messageActionsRequested = Notification.Name("hermey.message.actions")
}

/// A pass-through overlay that shows the message menu on a right-click inside its bounds.
///
/// `hitTest` returns nil, so it is never in the way. The menu is raised from a local monitor on the
/// window's event stream — the pattern this app already uses where a control in front would
/// otherwise swallow the event (`HoverReporter`) — and the monitor is removed when the row leaves
/// its window.
final class MessageMenuHostView: NSView {
    var items: [MessageMenuItem]

    /// The target of the menu's items. Kept while the menu is up: `NSMenuItem.target` is not a
    /// strong reference, and a router that deallocated under an open menu would grey every row.
    private var router: MessageMenuRouter?
    private var monitor: Any?
    /// The sharing picker, held for as long as it is on screen.
    private var picker: NSSharingServicePicker?

    init(items: [MessageMenuItem]) {
        self.items = items
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var isOpaque: Bool { false }

    /// Never a hit target: every press belongs to the content underneath. The right-click is taken
    /// from the window's stream instead, so it cannot be lost to SwiftUI's hit testing.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else { start() }
    }

    // MARK: The pointer

    private func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) {
            [weak self] event in
            guard let self, self.isMenuClick(event) else { return event }
            self.present(at: self.convert(event.locationInWindow, from: nil))
            // Consumed: the menu we showed is the only one for this click.
            return nil
        }
    }

    /// A right-click in our bounds — or a control-click, which macOS may deliver either as a
    /// right-click or as a left-click carrying `.control`. Anything else is returned untouched, so
    /// left clicks, drags and selections behave exactly as before.
    private func isMenuClick(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        switch event.type {
        case .rightMouseDown:
            break
        case .leftMouseDown where event.modifierFlags.contains(.control):
            break
        default:
            return false
        }
        guard !items.isEmpty else { return false }
        // The topmost row under the pointer answers. Rows do not overlap, so the first containing
        // bounds is the row the person aimed at.
        return bounds.contains(convert(event.locationInWindow, from: nil))
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        picker = nil
        router = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    // MARK: Presenting

    /// Under the pointer, which is where a right-click's menu belongs.
    private func present(at point: NSPoint) {
        show(point: point)
    }

    /// Below the row's leading edge, for the menu bar's *Message Actions…*: there is no pointer to
    /// anchor to when the menu is asked for from the keyboard.
    func presentBelow() {
        // `popUp(positioning:at:in:)` puts the menu's upper-left corner at the point, so a point on
        // the row's bottom edge opens the menu beneath the row.
        let point = NSPoint(x: bounds.minX + 6, y: isFlipped ? bounds.maxY - 1 : bounds.minY + 1)
        show(point: point)
    }

    private func show(point: NSPoint) {
        guard !items.isEmpty else { return }
        let router = MessageMenuRouter(items: items, host: self, anchor: point)
        let menu = router.makeMenu()
        // The menu draws in the app's appearance, not in whichever one AppKit guesses: without this the
        // glyph ink and the menu's own background could disagree, which is how "icons missing" was reached.
        menu.appearance = NSApp.effectiveAppearance
        // Retained for the life of the menu: the items' target is not a strong reference.
        self.router = router
        _ = menu.popUp(positioning: nil, at: point, in: self)
        self.router = nil
    }

    /// Hand the message's text to the system's share sheet, anchored where the menu was.
    ///
    /// Shown on the next main-actor turn rather than inside the item's action: raising a sharing
    /// picker from inside a menu's tracking loop leaves the menu on screen behind it.
    func share(_ text: String, at point: NSPoint) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let picker = NSSharingServicePicker(items: [text])
            self.picker = picker
            picker.show(relativeTo: NSRect(origin: point, size: .zero), of: self,
                        preferredEdge: .minY)
        }
    }
}

// MARK: - Building the menu

/// Builds an `NSMenu` from the shared rows, and is the target of every item in it.
///
/// One `NSMenuItem` is made per row, in the rows' order, and **each one is given its image from the
/// row's symbol** — this is the whole point of the file. `NSImage(systemSymbolName:…)` at menu size
/// (16 pt, template, so it follows the menu's appearance) is the documented glyph for a menu item.
final class MessageMenuRouter: NSObject {
    private let items: [MessageMenuItem]
    private weak var host: MessageMenuHostView?
    /// Where the menu was put, so the share sheet points at the same place.
    private let anchor: NSPoint

    init(items: [MessageMenuItem], host: MessageMenuHostView, anchor: NSPoint) {
        self.items = items
        self.host = host
        self.anchor = anchor
        super.init()
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Message")
        // We decide what is enabled: an item whose verb is live must not be greyed because AppKit
        // could not see a responder chain.
        menu.autoenablesItems = false
        for (index, item) in items.enumerated() {
            menu.addItem(makeItem(item, at: index))
        }
        return menu
    }

    /// The only place an `NSMenuItem` is created, and the image is set here — not in a `Label`, and
    /// not left to a style that might drop it.
    private func makeItem(_ item: MessageMenuItem, at index: Int) -> NSMenuItem {
        let nsItem = NSMenuItem(title: item.title,
                                action: #selector(runVerb(_:)),
                                keyEquivalent: "")
        nsItem.image = Self.glyph(item.symbol, description: item.title)
        nsItem.target = self
        nsItem.tag = index
        nsItem.isEnabled = true
        return nsItem
    }

    /// A menu-sized symbol, coloured for the appearance the menu will be drawn in.
    ///
    /// It used to be a template image and nothing else, and the result was reported from a screenshot as
    /// "no icons at all": every glyph was there, drawn in a near-black that vanished into the dark menu.
    /// A template is re-tinted by whatever draws it, and inside a menu that tint follows the appearance
    /// the menu believes it is in — which is not always the one the app is actually showing. So the
    /// colour is resolved here, from the menu's own effective appearance, and the image is not a
    /// template: what we pick is what is drawn.
    private static func glyph(_ symbol: String, description: String) -> NSImage? {
        let ink: NSColor = {
            let match = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            return match == .darkAqua ? .white : .black
        }()
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
        guard let image = NSImage(systemSymbolName: symbol,
                                  accessibilityDescription: description)?
            .withSymbolConfiguration(configuration) else {
            // A wrong symbol name is a bug in the row, not a reason to ship a bare item — but the
            // item must still be usable, so it is added and the mistake is loud in debug.
            assertionFailure("no SF Symbol named \(symbol) for the menu row “\(description)”")
            return nil
        }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = false
        return image
    }

    /// Every row lands here: the verb the shared description carries, run on the same message the
    /// menu was built for. Named `runVerb` rather than `perform` so it cannot collide with
    /// `NSObject.perform(_:)` in a selector.
    @objc private func runVerb(_ sender: NSMenuItem) {
        guard items.indices.contains(sender.tag) else { return }
        switch items[sender.tag].kind {
        case .action(let run):
            run()
        case .share(let text):
            host?.share(text, at: anchor)
        }
    }
}
