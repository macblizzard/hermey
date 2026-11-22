import XCTest
@testable import HermesA2UI

/// The inline-surface parser. Pure Foundation: what a reply carries, and what a bubble shows.
final class A2UISurfacePayloadTests: XCTestCase {

    private let wire = """
    {"surface":"928e1c18","messages":[{"version":"1.0","createSurface":{"surfaceId":"main",\
    "components":[{"id":"root","component":"Text","text":"A2UI online"}]}}]}
    """

    func testFindsOneSurfaceInAReply() {
        let reply = "Done.\n::a2ui\(wire)\nAnything else?"
        let surfaces = A2UIMarker.surfaces(in: reply)
        XCTAssertEqual(surfaces.count, 1)
        XCTAssertEqual(surfaces.first?.surface, "928e1c18")
        XCTAssertEqual(surfaces.first?.messagesJSON.count, 1)
    }

    func testTheStoredMessageKeepsItsComponents() throws {
        let surface = try XCTUnwrap(A2UIMarker.surfaces(in: "::a2ui\(wire)").first)
        let json = try XCTUnwrap(surface.messagesJSON.first)
        XCTAssertTrue(json.contains("\"component\":\"Text\""), json)
        XCTAssertTrue(json.contains("\"version\":\"1.0\""), json)
    }

    func testTextLosesTheMarkerAndKeepsItsParagraphs() {
        let reply = "First paragraph.\n::a2ui\(wire)\nSecond paragraph."
        // The marker sat on its own line, so removing it leaves exactly one blank line: that is
        // the paragraph break the author wrote, not a hole.
        XCTAssertEqual(A2UIMarker.textWithoutMarkers(reply), "First paragraph.\n\nSecond paragraph.")
        XCTAssertFalse(A2UIMarker.textWithoutMarkers(reply).contains("::a2ui"))
    }

    /// The cases a regex could not survive: quotes and braces inside a string value.
    func testEscapedQuotesAndStrayBracesDoNotEndTheMarker() {
        let tricky = """
        {"surface":"deadbeef","messages":[{"version":"1.0","createSurface":{"surfaceId":"main",\
        "components":[{"id":"root","component":"Text","text":"he said \\"hi\\" } {"}]}}]}
        """
        let reply = "before\n::a2ui\(tricky)\nafter"
        XCTAssertEqual(A2UIMarker.surfaces(in: reply).map(\.surface), ["deadbeef"])
        XCTAssertEqual(A2UIMarker.textWithoutMarkers(reply), "before\n\nafter")
    }

    func testAMalformedSurfaceIsSkippedNotThrown() {
        XCTAssertTrue(A2UIMarker.surfaces(in: "::a2ui{not json}").isEmpty)
        XCTAssertTrue(A2UIMarker.surfaces(in: #"::a2ui{"surface":"x","messages":[]}"#).isEmpty)
        XCTAssertEqual(A2UIMarker.textWithoutMarkers("no marker here"), "no marker here")
    }

    func testTwoSurfacesComeBackInOrder() {
        let second = wire.replacingOccurrences(of: "928e1c18", with: "abcdef01")
        let reply = "::a2ui\(wire)\ntext\n::a2ui\(second)"
        XCTAssertEqual(A2UIMarker.surfaces(in: reply).map(\.surface), ["928e1c18", "abcdef01"])
    }

    func testProseOnlyReplyIsUntouched() {
        let reply = "Nothing was drawn today, so this is just prose with a { brace }."
        XCTAssertTrue(A2UIMarker.surfaces(in: reply).isEmpty)
        XCTAssertEqual(A2UIMarker.textWithoutMarkers(reply), reply)
    }
}
