import AppKit
import Combine
import HermesKit
import SwiftUI

/// The one object both sides of a shortcut read: the panes draw it, the menu bar applies it.
///
/// **Why a centre and not just the document.** The document is a value — the answer to "what is
/// bound to what" at one instant. The menu bar and the settings pane have to be told when it
/// changes, and a menu item is not a SwiftUI view: it is an `NSMenuItem` whose `keyEquivalent` is
/// AppKit state. `ShortcutCenter` is the object that owns the value, publishes each change, and
/// hands the result to ``ShortcutMenuSync`` in the same breath as it saves it. Nothing else in the
/// app is allowed to write a key equivalent for a registry action.
///
/// **Why this is not per bot.** A keyboard is the Mac's, not the host's and not a bot's: the same
/// physical keys mean the same thing whichever conversation is open. It is stored per app
/// (``ShortcutStore``), and the pane edits the one document.
@MainActor
final class ShortcutCenter: ObservableObject {

    /// The current answer. Published so the pane, the menu's `Commands` and the sidebar's bell all
    /// redraw from one value.
    @Published private(set) var document: ShortcutDocument

    private let store: ShortcutStore
    private let sync = ShortcutMenuSync()
    /// Whether the AppKit pass has been armed. Installing twice would add two observers.
    private var installed = false

    init(store: ShortcutStore = ShortcutStore()) {
        self.store = store
        self.document = store.load()
        sync.center = self
    }

    // MARK: Reading

    /// The combination `id` currently has, or `nil` when it has none.
    func combo(_ id: String) -> ShortcutCombo? { document.resolved(id) }

    /// The combination as macOS prints it — `⇧⌘F` — or `nil` when unbound. This is the string the
    /// ⌘K palette used to spell by hand in a second, wrong place.
    func label(_ id: String) -> String? { combo(id)?.label }

    /// Whether a row can be changed at all.
    func isRebindable(_ id: String) -> Bool { ShortcutRegistry.action(id)?.isRebindable ?? false }

    func isCustomised(_ id: String) -> Bool { document.isCustomised(id) }

    var hasCustomisations: Bool { document.hasCustomisations }

    // MARK: Writing

    /// Bind a combination (or clear the row), or return why not.
    ///
    /// A refusal is returned rather than thrown and rather than logged: the pane shows the sentence
    /// under the row it belongs to, which is the only place it is useful.
    @discardableResult
    func set(_ combo: ShortcutCombo?, for id: String) -> ShortcutRejection? {
        let binding: ShortcutBinding = combo.map(ShortcutBinding.combo) ?? .unassigned
        var next = document
        if let rejection = next.set(binding, for: id) { return rejection }
        apply(next)
        return nil
    }

    /// One row back to what the app shipped with.
    func reset(_ id: String) {
        var next = document
        next.reset(id)
        apply(next)
    }

    /// Every row back. The button is only enabled while something is customised, so this cannot be
    /// pressed by accident on a fresh install.
    func restoreDefaults() {
        var next = document
        next.restoreDefaults()
        apply(next)
    }

    /// Persist and re-apply, in that order: a key that works but is forgotten on relaunch is a worse
    /// bug than one that does not work yet, so the write happens even if the menu pass finds nothing.
    private func apply(_ next: ShortcutDocument) {
        var pruned = next
        pruned.prune()
        document = pruned
        store.save(pruned)
        sync.apply()
    }

    // MARK: The menu bar

    /// Arm the AppKit pass: it applies once now and again whenever the app comes forward, because
    /// SwiftUI may rebuild a menu item (a title that flips with state) and the rebuilt item carries
    /// the default again.
    func installMenuSync() {
        guard !installed else { return }
        installed = true
        sync.install()
    }

    /// Test seam: the resolved table the menu is expected to carry, without touching AppKit.
    var resolvedTable: [String: String] {
        var table: [String: String] = [:]
        for action in ShortcutRegistry.actions {
            guard let combo = combo(action.id) else { continue }
            for title in action.menuItemTitles { table[title] = combo.label }
        }
        return table
    }
}

// MARK: - SwiftUI bridges

extension ShortcutCombo {

    /// The character AppKit stores in `NSMenuItem.keyEquivalent`.
    ///
    /// Menus do not take key codes: they take the character the key types, and the keys with no
    /// character have reserved values in the private-use area (`NSUpArrowFunctionKey` and friends).
    /// Getting this wrong does not fail loudly — the menu simply never matches — so the table is
    /// explicit rather than derived.
    var menuKeyEquivalent: String {
        switch key {
        case "return": return "\r"
        case "escape": return "\u{1b}"
        case "tab": return "\t"
        case "space": return " "
        // NSBackspaceCharacter. This is the value Finder and Mail put in "Move to Trash", and it is
        // what draws as ⌫ in a menu.
        case "delete": return "\u{8}"
        case "forwardDelete": return "\u{f728}"
        case "up": return "\u{f700}"
        case "down": return "\u{f701}"
        case "left": return "\u{f702}"
        case "right": return "\u{f703}"
        case "home": return "\u{f729}"
        case "end": return "\u{f72b}"
        case "pageUp": return "\u{f72c}"
        case "pageDown": return "\u{f72d}"
        default:
            if key.hasPrefix("f"), let number = Int(key.dropFirst()),
               (1...20).contains(number) {
                // NSF1FunctionKey is 0xF704 and the series runs up without gaps.
                if let scalar = UnicodeScalar(UInt32(0xF704 + number - 1)) {
                    return String(Character(scalar))
                }
                return " "
            }
            return key
        }
    }

    /// What SwiftUI wants for `.keyboardShortcut(_:modifiers:)`.
    var keyEquivalent: KeyEquivalent {
        KeyEquivalent(Character(menuKeyEquivalent))
    }

    /// The modifiers SwiftUI's `keyboardShortcut` takes.
    var eventModifiers: EventModifiers {
        var set: EventModifiers = []
        if modifiers.contains(.command) { set.insert(.command) }
        if modifiers.contains(.option) { set.insert(.option) }
        if modifiers.contains(.control) { set.insert(.control) }
        if modifiers.contains(.shift) { set.insert(.shift) }
        return set
    }

    /// The modifiers AppKit's `keyEquivalentModifierMask` takes.
    var menuModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        return flags
    }

    /// Read a key event back into a combination, for the recorder.
    ///
    /// Modifiers come from the event's own flags; the key comes from the characters the event
    /// carries, which is the only place a layout's answer appears. A modifier pressed on its own has
    /// no characters and returns `nil` — that is the press the recorder must ignore, not bind.
    init?(event: NSEvent) {
        let ignored: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function, .capsLock]
        let flags = event.modifierFlags.intersection(ignored)
        var set = Set<Modifier>()
        if flags.contains(.control) { set.insert(.control) }
        if flags.contains(.option) { set.insert(.option) }
        if flags.contains(.shift) { set.insert(.shift) }
        if flags.contains(.command) { set.insert(.command) }

        if let special = ShortcutCombo.namedKey(forFunction: event) {
            self.init(key: special, modifiers: set)
            return
        }
        guard let characters = event.charactersIgnoringModifiers?.lowercased(),
              let character = characters.first,
              characters.count == 1,
              ShortcutCombo.printableKeys.contains(character) else { return nil }
        self.init(key: String(character), modifiers: set)
    }

    /// The function keys in an event's `keyCode`, mapped to the token the registry knows.
    ///
    /// `charactersIgnoringModifiers` for an arrow key is a private-use character, and for F-keys it
    /// varies by keyboard; the key code is the stable fact. These are the ANSI codes, which is what
    /// every Mac keyboard reports for these keys.
    private static func namedKey(forFunction event: NSEvent) -> String? {
        switch event.keyCode {
        case 36, 76: return "return"
        case 53: return "escape"
        case 48: return "tab"
        case 49: return "space"
        case 51: return "delete"
        case 117: return "forwardDelete"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        case 115: return "home"
        case 119: return "end"
        case 116: return "pageUp"
        case 121: return "pageDown"
        case 122: return "f1"
        case 120: return "f2"
        case 99: return "f3"
        case 118: return "f4"
        case 96: return "f5"
        case 97: return "f6"
        case 98: return "f7"
        case 100: return "f8"
        case 101: return "f9"
        case 109: return "f10"
        case 103: return "f11"
        case 111: return "f12"
        case 105: return "f13"
        case 107: return "f14"
        case 113: return "f15"
        case 106: return "f16"
        case 64: return "f17"
        case 79: return "f18"
        case 80: return "f19"
        case 90: return "f20"
        default: return nil
        }
    }
}

extension View {

    /// `.keyboardShortcut`, read from the registry instead of spelled here.
    ///
    /// An unbound row applies nothing at all, which is why this is a `ViewModifier` and not a
    /// function returning a modified view: `keyboardShortcut` has no "no key" spelling, and applying
    /// some placeholder would bind a key the owner asked not to have.
    func hermeyShortcut(_ actionID: String, using center: ShortcutCenter) -> some View {
        modifier(HermeyShortcut(actionID: actionID, center: center))
    }
}

private struct HermeyShortcut: ViewModifier {
    let actionID: String
    @ObservedObject var center: ShortcutCenter

    func body(content: Content) -> some View {
        if let combo = center.combo(actionID) {
            content.keyboardShortcut(combo.keyEquivalent, modifiers: combo.eventModifiers)
        } else {
            content
        }
    }
}
