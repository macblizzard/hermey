import XCTest
@testable import HermesKit

/// The one rule that broke the feature: the view must load the bundled **page**, carrying the
/// **socket** as a query parameter. Loading the socket itself is what left the phone on
/// "Connecting…" — no page, no script, no socket.
final class BotComputerViewerTests: XCTestCase {

    private let socket = URL(string: "wss://hermes.corvus-vibes.ts.net:8443/v1/display/ws"
                             + "?display_ticket=abc_DEF-123~xyz")!

    func testThePageAddressIsTheLocalViewerNotTheSocket() {
        let page = BotComputerViewer.pageURL(socket: socket, viewOnly: true)
        XCTAssertEqual(page?.scheme, "hermey-novnc")
        XCTAssertEqual(page?.host, "local")
        XCTAssertEqual(page?.path, "/botcomputer.html")
        // A `wss` document is what the old build asked WebKit for; nothing may ever load that again.
        XCTAssertNotEqual(page?.scheme, "wss")
    }

    func testTheSocketSurvivesTheQueryStringExactly() {
        let page = BotComputerViewer.pageURL(socket: socket, viewOnly: false)!
        // Read it the way the page does, so the test fails if percent-encoding ever splits the
        // ticket's own `?` and `=` into parameters of the page address.
        let components = URLComponents(url: page, resolvingAgainstBaseURL: false)!
        let raw = components.queryItems?.first { $0.name == "ws" }?.value
        XCTAssertEqual(raw, socket.absoluteString)
        XCTAssertEqual(BotComputerViewer.socket(fromPageURL: page), socket)

        let params = URLSearchParamsLike(page)
        XCTAssertEqual(params["ws"], socket.absoluteString)
        XCTAssertEqual(params["display_ticket"], nil)   // the ticket belongs to the socket, not the page
    }

    func testViewOnlyTravelsWithTheAddress() {
        XCTAssertEqual(BotComputerViewer
            .pageURL(socket: socket, viewOnly: true)
            .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "viewOnly" }?.value, "1")
        XCTAssertEqual(BotComputerViewer
            .pageURL(socket: socket, viewOnly: false)
            .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "viewOnly" }?.value, "0")
    }

    func testAPlainHTTPSocketIsAccepted() {
        // Pairing can be a tailnet https base or a local http one; both become ws(s) before this and
        // neither may be rejected on the way to the page.
        let plain = URL(string: "ws://127.0.0.1:8787/v1/display/ws?display_ticket=t1")!
        XCTAssertEqual(BotComputerViewer.socket(fromPageURL: BotComputerViewer.pageURL(socket: plain, viewOnly: true)!), plain)
    }

    /// The page's own reader: `new URLSearchParams(window.location.search)`.
    private struct URLSearchParamsLike {
        private let values: [String: String]
        init(_ url: URL) {
            let search = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
            var found: [String: String] = [:]
            for pair in search.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(parts[0]).removingPercentEncoding ?? String(parts[0])
                let value = parts.count > 1 ? String(parts[1]) : ""
                found[name] = value.removingPercentEncoding ?? value
            }
            values = found
        }
        subscript(name: String) -> String? { values[name] }
    }
}
