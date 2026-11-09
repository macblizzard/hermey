import Foundation

/// Where the bundled viewer page lives, and how its address is built.
///
/// This is the join that was missing: the client hands the view a **socket** (`wss://host/v1/display/ws?display_ticket=…`)
/// and the view used to load *that* as its document. WebKit asked the network for a `wss://` page, got
/// nothing, and the pane sat on "Connecting…" forever — no page, no script, no socket, and a black
/// rectangle where the desktop should be. The page is a local resource; the socket is a query
/// parameter on it.
///
/// It lives in HermesKit (not beside the `WKWebView`) so the rule can be tested without a simulator:
/// the one thing that must be true is that the socket survives the trip through the query string
/// exactly, ticket and all.
public enum BotComputerViewer {
    /// The custom scheme the bundle is served under. `file://` cannot load ES modules and
    /// `loadHTMLString` has no directory for relative imports, so the page gets its own scheme.
    public static let scheme = "hermey-novnc"
    public static let host = "local"
    public static let page = "/botcomputer.html"

    /// The address the web view loads: the bundled page, carrying the socket to dial.
    public static func pageURL(socket: URL, viewOnly: Bool) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = page
        // `ws` is percent-encoded by URLComponents, so the ticket's `?` and `=` cannot split into
        // parameters of their own — the failure mode that makes a viewer dial a socket with no ticket.
        components.queryItems = [
            URLQueryItem(name: "ws", value: socket.absoluteString),
            URLQueryItem(name: "viewOnly", value: viewOnly ? "1" : "0"),
        ]
        return components.url
    }

    /// The socket a page address carries, as the page's own `URLSearchParams` would read it.
    public static func socket(fromPageURL url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "ws" })?.value
        else { return nil }
        return URL(string: raw)
    }
}
