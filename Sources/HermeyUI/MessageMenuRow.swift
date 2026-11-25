import SwiftUI

/// One verb of a message's menu, as data: its title, the glyph that belongs to it, and what it does.
///
/// **Every row of every message menu is described here**, once, and the two shells draw that
/// description their own way: `MessageMenuRow` renders it as a SwiftUI `Button`/`ShareLink` (the
/// phone, and the group-room transcript), and the Mac hands the same values to AppKit and gets a
/// real `NSMenuItem` back.
///
/// That split is the answer to the bug the owner reported twice. `Label(title, systemImage:)` is
/// what the phone draws and it is correct there; on the Mac the same `Label` inside a `contextMenu`
/// arrived as a bare title, because SwiftUI's menu on macOS builds its items from the button's
/// *title* and does not carry the `Label`'s image into the menu item. A `labelStyle`, a tint or a
/// theme token is all downstream of the menu SwiftUI builds, so nothing in our own code could have
/// changed it. `NSMenuItem.image` is the documented place for a menu glyph, so the Mac owns its
/// menu now (`Apps/HermesMac/Conversation/MessageContextMenu.swift`) and the phone keeps the
/// `Label`.
///
/// A row cannot be built without a symbol: `symbol:` has no default in `action(_:symbol:perform:)`,
/// and the named constructors below — one per verb the menu has ever had — each spell theirs.
public struct MessageMenuItem: Identifiable {
    /// What the row does. `share` carries its text because sharing is presented by the system —
    /// `ShareLink` on the phone, `NSSharingServicePicker` on the Mac — not run by us.
    public enum Kind {
        case action(() -> Void)
        case share(String)
    }

    public let title: String
    /// An SF Symbol name. Required, never defaulted: a row with no glyph is the ragged menu.
    public let symbol: String
    public let kind: Kind

    /// A menu holds one row per verb, so the title is identity enough — and it stays stable across
    /// the rebuilds a scroll causes.
    public var id: String { "\(symbol)#\(title)" }

    private init(title: String, symbol: String, kind: Kind) {
        self.title = title
        self.symbol = symbol
        self.kind = kind
    }

    /// A row that does something. `symbol` is an SF Symbol name; there is no default.
    public static func action(_ title: String, symbol: String,
                              perform: @escaping () -> Void) -> MessageMenuItem {
        MessageMenuItem(title: title, symbol: symbol, kind: .action(perform))
    }

    /// The share row: `square.and.arrow.up`, the glyph macOS and iOS use for "send this on".
    public static func share(_ text: String) -> MessageMenuItem {
        MessageMenuItem(title: "Share", symbol: "square.and.arrow.up", kind: .share(text))
    }
}

// MARK: - The verbs, named

/// One constructor per verb, so neither shell spells a title of its own and the two menus cannot
/// drift apart. A conditional row takes its condition as an argument and swaps *title and symbol
/// together*: a row that says "Stop Reading" must not still show the speaking mark.
public extension MessageMenuItem {
    /// Hand the message's words to the select-text sheet/panel.
    static func selectText(_ perform: @escaping () -> Void) -> MessageMenuItem {
        .action("Select Text", symbol: "text.cursor", perform: perform)
    }

    /// Read the message aloud — or stop, if this row is the one speaking.
    static func readAloud(isSpeaking: Bool, toggle: @escaping () -> Void) -> MessageMenuItem {
        .action(isSpeaking ? "Stop Reading" : "Read Aloud",
                symbol: isSpeaking ? "speaker.slash" : "speaker.wave.2",
                perform: toggle)
    }

    /// Open the emoji picker. `…` because it opens one; the row itself runs no verb.
    static func addReaction(_ open: @escaping () -> Void) -> MessageMenuItem {
        .action("Add Reaction…", symbol: "face.smiling", perform: open)
    }

    /// Put the message on the pasteboard.
    static func copyMessage(_ perform: @escaping () -> Void) -> MessageMenuItem {
        .action("Copy Message", symbol: "doc.on.doc", perform: perform)
    }

    /// Answer the message, quoting it. The phone's menu has this row.
    static func reply(_ perform: @escaping () -> Void) -> MessageMenuItem {
        .action("Reply", symbol: "arrowshape.turn.up.left", perform: perform)
    }

    /// Copy only the message's first fenced block. The phone's menu has this row.
    static func copyCodeBlock(_ perform: @escaping () -> Void) -> MessageMenuItem {
        .action("Copy code block", symbol: "chevron.left.forwardslash.chevron.right",
                perform: perform)
    }

    /// Rewrite one of the owner's own messages: the text goes back into the composer, and sending it
    /// retires that message and everything painted after it (see `AppModel.confirmMessageAction`).
    ///
    /// `square.and.pencil` because it is the app's own "edit" glyph, and the title spells the second
    /// half — *and resend* — because this is not an in-place edit: the turn is asked again.
    static func editAndResend(_ perform: @escaping () -> Void) -> MessageMenuItem {
        .action("Edit and resend", symbol: "square.and.pencil", perform: perform)
    }

    /// Retire one message from the conversation, on every device.
    ///
    /// Destructive, so the row is only ever built behind a confirmation (the model raises one and
    /// nothing reaches the host until it is confirmed) and never on a message that is still being
    /// written. `trash` is what both platforms use for "remove this".
    static func deleteMessage(_ perform: @escaping () -> Void) -> MessageMenuItem {
        .action("Delete", symbol: "trash", perform: perform)
    }
}

/// One row of a message's context menu, with the glyph that belongs to it.
///
/// **Every row is built here.** The menu had five rows and one icon: `Share` was a `Label` (it is a
/// `ShareLink`, and a link's label was easy to spell), and the four verbs around it were bare
/// `Button("…")` titles — the ragged menu the owner photographed on 2026-11-24. A menu is a list of
/// verbs read at a glance, and one row with a mark beside four without reads as five unrelated
/// things.
///
/// The row is a *view of a `MessageMenuItem`*: the description is shared with the Mac's AppKit
/// menu, and this type is the SwiftUI drawing of it. `symbol:` is required by the constructors, so a
/// row cannot be built without one:
///
/// ```swift
/// MessageMenuRow(.readAloud(isSpeaking: isSpeaking) { … })
/// MessageMenuRow.share(entry.text)
/// ```
public struct MessageMenuRow: View {
    private let item: MessageMenuItem

    /// Draw a shared description. The one door the phone and the room transcript use.
    public init(_ item: MessageMenuItem) {
        self.item = item
    }

    /// A row that does something, spelled here. `symbol` is an SF Symbol name; there is no default.
    public static func action(_ title: String, symbol: String,
                              perform: @escaping () -> Void) -> MessageMenuRow {
        MessageMenuRow(.action(title, symbol: symbol, perform: perform))
    }

    /// The share row, through the one definition of it.
    public static func share(_ text: String) -> MessageMenuRow {
        MessageMenuRow(.share(text))
    }

    public var body: some View {
        switch item.kind {
        case .action(let perform):
            Button(action: perform) {
                Label(item.title, systemImage: item.symbol)
            }
            .hermeyFocusQuiet()
        case .share(let text):
            ShareLink(item: text) {
                Label(item.title, systemImage: item.symbol)
            }
            .hermeyFocusQuiet()
        }
    }
}
