import SwiftUI
import WebKit
import HermesAppKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// How a card finds its URL: the app supplies this once, at the root, because only the app knows the
/// paired host, its device id and the refresh token that mints a card session.
public struct GenUICardsResolver: Sendable {
    /// The conversation's bot: one transcript is one bot, so the card does not have to be told twice.
    public var bot: String
    /// `blockID -> URL?`. Nil means "no host, or the host would not mint a session".
    public var url: @Sendable (String) async -> URL?
    /// What the card paints with. Read when the URL is built.
    public var palette: @Sendable () -> GenUIPalette

    public init(bot: String = "",
                url: @escaping @Sendable (String) async -> URL?,
                palette: @escaping @Sendable () -> GenUIPalette) {
        self.bot = bot
        self.url = url
        self.palette = palette
    }

    /// No host paired: a card cannot be drawn, and the transcript says so quietly.
    public static let unavailable = GenUICardsResolver(url: { _ in nil }, palette: { GenUIPalette.rakazo })
}

private struct GenUICardsKey: EnvironmentKey {
    static let defaultValue = GenUICardsResolver.unavailable
}

public extension EnvironmentValues {
    var genUICards: GenUICardsResolver {
        get { self[GenUICardsKey.self] }
        set { self[GenUICardsKey.self] = newValue }
    }
}

public extension GenUIPalette {
    /// The app's own colours, as hex, taken from the active theme so a card is the same face as the
    /// transcript around it. The plugin reads these as `--foreground`, `--background` and so on.
    static var current: GenUIPalette {
        GenUIPalette(ink: Hex.of(Tokens.textPrimary),
                     background: Hex.of(Tokens.canvas),
                     accent: Hex.of(Tokens.accent),
                     muted: Hex.of(Tokens.textMuted),
                     good: Hex.of(Tokens.success),
                     scheme: "dark")
    }

    /// The Rakazo palette, for previews and for the moment before the theme is read.
    static var rakazo: GenUIPalette {
        GenUIPalette(ink: "#F5F5F5", background: "#0A0A0A", accent: "#4D9BFF",
                     muted: "#A5A5A5", good: "#00BA69", scheme: "dark")
    }
}

enum Hex {
    /// A SwiftUI colour as `#RRGGBB`, through the platform colour so a token's own definition is
    /// what gets handed over (a theme that is not sRGB still resolves to sRGB here).
    static func of(_ color: Color) -> String {
        #if os(macOS)
        guard let resolved = NSColor(color).usingColorSpace(.sRGB) else { return "#000000" }
        return format(resolved.redComponent, resolved.greenComponent, resolved.blueComponent)
        #else
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return "#000000"
        }
        return format(red, green, blue)
        #endif
    }

    private static func format(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> String {
        String(format: "#%02X%02X%02X",
               Int((red * 255).rounded()),
               Int((green * 255).rounded()),
               Int((blue * 255).rounded()))
    }
}

/// One drawn board, in the plugin's own renderer.
///
/// The card is a `WKWebView` because the blocks *are* the plugin's React components: re-drawing them
/// in SwiftUI would be a second implementation of 30-odd block types, and the two would drift apart
/// the first time the plugin changed. The page reports its height, so the card sizes itself like any
/// other view in the transcript.
public struct GenUICard: View {
    private let blockID: String
    @Environment(\.genUICards) private var resolver

    @State private var url: URL?
    @State private var height: CGFloat = 120
    @State private var failed = false

    public init(blockID: String) {
        self.blockID = blockID
    }

    public var body: some View {
        Group {
            if let url {
                GenUIWebView(url: url,
                             onHeight: { height = $0 },
                             onSend: { send($0) },
                             onFill: { fill($0) })
                    .frame(height: max(44, height))
            } else if failed {
                Text("This board couldn't be drawn.")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // The same shape the desktop shows while the board is on its way: a quiet line, not
                // a spinner in the middle of a reply.
                Text("drawing…")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 28)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: blockID) {
            guard url == nil else { return }
            let built = await resolver.url(blockID)
            await MainActor.run {
                if let built {
                    url = built
                } else {
                    failed = true
                }
            }
        }
    }

    /// A card's button sends its text as the user's next message — the same contract the plugin's
    /// own `composerActions` has: a long message or a slash command is put in the composer instead.
    private func send(_ text: String) {
        NotificationCenter.default.post(name: .genUICardSend, object: nil,
                                        userInfo: ["text": text, "bot": resolver.bot])
    }

    private func fill(_ text: String) {
        NotificationCenter.default.post(name: .genUICardFill, object: nil,
                                        userInfo: ["text": text, "bot": resolver.bot])
    }
}

public extension Notification.Name {
    /// A card's button was tapped. `userInfo["text"]` is the message, `["bot"]` the bot it came from.
    static let genUICardSend = Notification.Name("hermey.genui.send")
    /// A card asked for text to be put in the composer instead of sent.
    static let genUICardFill = Notification.Name("hermey.genui.fill")
}

// MARK: - The web view

#if os(macOS)
private struct GenUIWebView: NSViewRepresentable {
    let url: URL
    let onHeight: (CGFloat) -> Void
    let onSend: (String) -> Void
    let onFill: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onHeight: onHeight, onSend: onSend, onFill: onFill) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: "hermes")
        let view = WKWebView(frame: .zero, configuration: configuration)
        // Transparent: the card is part of the transcript, not a panel laid over it.
        view.underPageBackgroundColor = .clear
        view.allowsBackForwardNavigationGestures = false
        view.allowsMagnification = false
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url != url { view.load(URLRequest(url: url)) }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "hermes")
        view.stopLoading()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let onHeight: (CGFloat) -> Void
        let onSend: (String) -> Void
        let onFill: (String) -> Void

        init(onHeight: @escaping (CGFloat) -> Void, onSend: @escaping (String) -> Void,
             onFill: @escaping (String) -> Void) {
            self.onHeight = onHeight
            self.onSend = onSend
            self.onFill = onFill
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            GenUIMessage.handle(message.body, onHeight: onHeight, onSend: onSend, onFill: onFill)
        }
    }
}
#else
private struct GenUIWebView: UIViewRepresentable {
    let url: URL
    let onHeight: (CGFloat) -> Void
    let onSend: (String) -> Void
    let onFill: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onHeight: onHeight, onSend: onSend, onFill: onFill) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: "hermes")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        // The card is sized by its own reported height; a scroll view inside it would be a second
        // scroll region inside the transcript's.
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        if view.url != url { view.load(URLRequest(url: url)) }
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "hermes")
        view.stopLoading()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let onHeight: (CGFloat) -> Void
        let onSend: (String) -> Void
        let onFill: (String) -> Void

        init(onHeight: @escaping (CGFloat) -> Void, onSend: @escaping (String) -> Void,
             onFill: @escaping (String) -> Void) {
            self.onHeight = onHeight
            self.onSend = onSend
            self.onFill = onFill
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            GenUIMessage.handle(message.body, onHeight: onHeight, onSend: onSend, onFill: onFill)
        }
    }
}
#endif

/// The three messages the card page sends, decoded once for both platforms.
enum GenUIMessage {
    static func handle(_ body: Any,
                       onHeight: (CGFloat) -> Void,
                       onSend: (String) -> Void,
                       onFill: (String) -> Void) {
        guard let payload = body as? [String: Any], let type = payload["type"] as? String else { return }
        switch type {
        case "height":
            // A card may report 0 before its first paint; a zero-height frame would collapse the row.
            let value = (payload["value"] as? NSNumber)?.doubleValue ?? 0
            if value > 0 { DispatchQueue.main.async { onHeight(CGFloat(value)) } }
        case "send":
            if let text = payload["text"] as? String, !text.isEmpty {
                DispatchQueue.main.async { onSend(text) }
            }
        case "fill":
            if let text = payload["text"] as? String, !text.isEmpty {
                DispatchQueue.main.async { onFill(text) }
            }
        default:
            break
        }
    }
}
