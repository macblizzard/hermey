import AppKit
import Foundation
import WebKit

/// A private page surface for browser tools. It never steals focus from the bot's visible desktop:
/// the window is created off-screen and only the page's DOM/accessibility snapshot crosses the wire.
@MainActor
final class ComputerBrowser: NSObject, WKNavigationDelegate, WKDownloadDelegate {
    static let shared = ComputerBrowser()
    private let webView: WKWebView
    private let window: NSWindow
    private var downloads: [String] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800),
                             configuration: configuration)
        let host = NSWindow(contentRect: view.frame, styleMask: .borderless,
                            backing: .buffered, defer: false)
        host.contentView = view
        host.orderOut(nil)
        self.webView = view
        self.window = host
        super.init()
        view.navigationDelegate = self
    }

    func navigate(_ urlString: String) async throws -> [String: Any] {
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw BrowserError.badURL
        }
        webView.load(URLRequest(url: url))
        for _ in 0..<100 {
            if !webView.isLoading { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return try await snapshot()
    }

    func snapshot() async throws -> [String: Any] {
        let text = try await evaluate("document.body ? document.body.innerText : ''")
        return [
            "url": webView.url?.absoluteString ?? "",
            "title": webView.title ?? "",
            "text": text,
            "loading": webView.isLoading,
        ]
    }

    func act(_ raw: [[String: Any]]) async throws -> [String: Any] {
        guard (1...10).contains(raw.count) else { throw BrowserError.badBatch }
        var results: [[String: Any]] = []
        for action in raw {
            guard let kind = action["kind"] as? String else { throw BrowserError.badBatch }
            let selector = action["selector"] as? String ?? ""
            let value = action["value"] as? String ?? ""
            let js: String
            switch kind {
            case "click":
                js = "(() => { const e = document.querySelector(\(Self.quoted(selector)));"
                    + " if (!e) return {ok:false, error:'not found'}; e.click(); return {ok:true}; })()"
            case "fill", "type":
                js = "(() => { const e = document.querySelector(\(Self.quoted(selector)));"
                    + " if (!e) return {ok:false, error:'not found'}; e.value = \(Self.quoted(value));"
                    + " e.dispatchEvent(new Event('input', {bubbles:true}));"
                    + " e.dispatchEvent(new Event('change', {bubbles:true})); return {ok:true}; })()"
            default:
                throw BrowserError.badBatch
            }
            let result = try await evaluate(js)
            results.append(["kind": kind, "selector": selector, "result": result])
        }
        return ["actions": results, "page": try await snapshot()]
    }

    private func evaluate(_ script: String) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value ?? NSNull()) }
            }
        }
    }

    private static func quoted(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }

    // MARK: - Downloads

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {}

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {}

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {}

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        download.delegate = self
    }

    nonisolated func download(_ download: WKDownload,
                              decideDestinationUsing response: URLResponse,
                              suggestedFilename: String,
                              completionHandler: @escaping (URL?) -> Void) {
        let folder = ComputerFiles.shared.root.appendingPathComponent("downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = suggestedFilename.isEmpty ? "download" : suggestedFilename
        completionHandler(folder.appendingPathComponent(name))
        Task { @MainActor in ComputerBrowser.shared.downloads.append(name) }
    }

    nonisolated func downloadDidFinish(_ download: WKDownload) {}

    func recentDownloads() -> [String] { downloads.suffix(20) }
}

enum BrowserError: LocalizedError {
    case badURL
    case badBatch

    var errorDescription: String? {
        switch self {
        case .badURL: return "Only http and https URLs can be opened."
        case .badBatch: return "A browser batch needs 1..10 click/fill/type actions."
        }
    }
}
