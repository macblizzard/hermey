import SwiftUI
#if canImport(WebKit)
import WebKit

/// Serves the bundled noVNC tree to a `WKWebView` under its own scheme.
///
/// Two arrangements do **not** work and this one exists because of them: `file://` cannot load ES
/// modules (WebKit gives every file a null origin, so noVNC's `core/rfb.js` imports are blocked),
/// and `loadHTMLString` has no directory to resolve those imports against. A custom scheme is the
/// one arrangement where relative module imports work and nothing leaves the device — the page and
/// its socket are local and tailnet-only respectively.
///
/// Paths are resolved under `root` only: `..` cannot climb out, because the resolved file must
/// still be prefixed by the root.
public final class BotComputerSchemeHandler: NSObject, WKURLSchemeHandler {
    public static let scheme = "hermey-novnc"
    public static let host = "local"

    private let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
        super.init()
    }

    public func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(BotComputerViewerError.badURL)
            return
        }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/botcomputer.html" }
        let file = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        guard file.path.hasPrefix(root.path), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(BotComputerViewerError.missingAsset(path))
            return
        }
        let response = URLResponse(url: url,
                                   mimeType: Self.mimeType(for: file.pathExtension),
                                   expectedContentLength: data.count,
                                   textEncodingName: "utf-8")
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    public func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // Nothing to cancel: every response is one synchronous file read.
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html"
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "png": return "image/png"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }
}

enum BotComputerViewerError: Error, LocalizedError {
    case badURL
    case missingAsset(String)
    case notBundled

    var errorDescription: String? {
        switch self {
        case .badURL: return "the viewer address was not a URL"
        case .missingAsset(let path): return "the viewer is missing \(path) from this build"
        case .notBundled: return "this build has no bundled viewer"
        }
    }
}

/// Where the bundled viewer lives in an app bundle: `Resources/botcomputer.html` plus its
/// `novnc/` tree beside it.
public struct BotComputerResources: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// Resolve from a bundle, or nil when the app was built without the resources (a UI test, a
    /// preview) — the pane then says so instead of drawing a blank rectangle.
    public init?(bundle: Bundle = .main) {
        guard let html = bundle.url(forResource: "botcomputer", withExtension: "html") else {
            return nil
        }
        self.root = html.deletingLastPathComponent()
    }
}

#if os(macOS)
public struct BotComputerWebView: NSViewRepresentable {
    public let url: URL
    public let resources: BotComputerResources
    public let viewOnly: Bool
    public var onEvent: (String) -> Void

    public init(url: URL, resources: BotComputerResources, viewOnly: Bool,
                onEvent: @escaping (String) -> Void = { _ in }) {
        self.url = url
        self.resources = resources
        self.viewOnly = viewOnly
        self.onEvent = onEvent
    }

    public func makeCoordinator() -> Coordinator { Coordinator(onEvent: onEvent) }

    public func makeNSView(context: Context) -> WKWebView {
        makeWebView(context)
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        apply(viewOnly: viewOnly, to: webView)
    }
}
#else
public struct BotComputerWebView: UIViewRepresentable {
    public let url: URL
    public let resources: BotComputerResources
    public let viewOnly: Bool
    public var onEvent: (String) -> Void

    public init(url: URL, resources: BotComputerResources, viewOnly: Bool,
                onEvent: @escaping (String) -> Void = { _ in }) {
        self.url = url
        self.resources = resources
        self.viewOnly = viewOnly
        self.onEvent = onEvent
    }

    public func makeCoordinator() -> Coordinator { Coordinator(onEvent: onEvent) }

    public func makeUIView(context: Context) -> WKWebView {
        makeWebView(context)
    }

    public func updateUIView(_ webView: WKWebView, context: Context) {
        apply(viewOnly: viewOnly, to: webView)
    }
}
#endif

// MARK: - Shared construction

extension BotComputerWebView {
    public final class Coordinator: NSObject, WKScriptMessageHandler {
        let onEvent: (String) -> Void
        init(onEvent: @escaping (String) -> Void) { self.onEvent = onEvent }

        public func userContentController(_ controller: WKUserContentController,
                                          didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let event = body["event"] as? String else { return }
            onEvent(event)
        }
    }

    func makeWebView(_ context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(BotComputerSchemeHandler(root: resources.root),
                                          forURLScheme: BotComputerSchemeHandler.scheme)
        configuration.userContentController.add(context.coordinator, name: "bridge")
        // noVNC may start audio/notification-less media; nothing else is allowed to pop windows.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        #if os(iOS)
        // macOS's WKWebView has neither: `isOpaque` is get-only and there is no backgroundColor.
        webView.isOpaque = false
        webView.backgroundColor = .clear
        #endif
        webView.load(URLRequest(url: url))
        return webView
    }

    /// Input is gated on the host by the control lease; `viewOnly` is the UI's own hint, so a
    /// stale value can never let a viewer type into a screen the host says it does not hold.
    func apply(viewOnly: Bool, to webView: WKWebView) {
        let js = "window.hermeySetViewOnly && window.hermeySetViewOnly(\(viewOnly ? "true" : "false"))"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}
#endif
