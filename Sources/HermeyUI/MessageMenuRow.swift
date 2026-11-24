import SwiftUI

/// One row of a message's context menu, with the glyph that belongs to it.
///
/// **Every row is built here.** The menu had five rows and one icon: `Share` was a `Label` (it is a
/// `ShareLink`, and a link's label was easy to spell), and the four verbs around it were bare
/// `Button("…")` titles — the ragged menu the owner photographed on 2026-11-24. A menu is a list of
/// verbs read at a glance, and one row with a mark beside four without reads as five unrelated
/// things.
///
/// The fix is not five icons pasted into a menu that the next row can miss: `symbol:` is required
/// by both constructors, so a row cannot be built without one. Sharing is a `ShareLink` rather than
/// a `Button`, so it gets its own constructor — same `Label`, same metrics, built by the same type.
/// A conditional row passes its glyph from the same condition as its title:
///
/// ```swift
/// MessageMenuRow.action(isSpeaking ? "Stop Reading" : "Read Aloud",
///                       symbol: isSpeaking ? "speaker.slash" : "speaker.wave.2") { … }
/// MessageMenuRow.share(entry.text)
/// ```
public struct MessageMenuRow: View {
    private enum Kind {
        /// A verb: the row runs `perform`.
        case action(() -> Void)
        /// `Share`: a `ShareLink`, which the system presents itself.
        case share(String)
    }

    private let title: String
    private let symbol: String
    private let kind: Kind

    private init(title: String, symbol: String, kind: Kind) {
        self.title = title
        self.symbol = symbol
        self.kind = kind
    }

    /// A row that does something. `symbol` is an SF Symbol name; there is no default.
    public static func action(_ title: String, symbol: String,
                              perform: @escaping () -> Void) -> MessageMenuRow {
        MessageMenuRow(title: title, symbol: symbol, kind: .action(perform))
    }

    /// The share row: `square.and.arrow.up`, the glyph macOS and iOS use for "send this on".
    public static func share(_ text: String) -> MessageMenuRow {
        MessageMenuRow(title: "Share", symbol: "square.and.arrow.up", kind: .share(text))
    }

    public var body: some View {
        switch kind {
        case .action(let perform):
            Button(action: perform) {
                Label(title, systemImage: symbol)
            }
            .hermeyFocusQuiet()
        case .share(let text):
            ShareLink(item: text) {
                Label(title, systemImage: symbol)
            }
            .hermeyFocusQuiet()
        }
    }
}
