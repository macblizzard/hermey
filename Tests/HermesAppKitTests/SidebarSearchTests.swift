#if canImport(Combine)
import Foundation
import XCTest
@testable import HermesAppKit
import HermesKit

/// The bot panel's combined answer: findings above bots, one cursor walking both, and a state for
/// every half-answered moment of a debounced search.
///
/// These are the rules the sidebar draws and the keyboard obeys, lifted out of SwiftUI so they can
/// be held here rather than by a screenshot. The view is left with layout and colour.
final class SidebarSearchTests: XCTestCase {

    private func hit(_ profile: String, _ snippet: String, at seconds: TimeInterval = 0) -> BotSearchHit {
        BotSearchHit(profile: profile,
                     sessionID: "s-\(profile)",
                     role: "user",
                     at: Date(timeIntervalSince1970: seconds),
                     snippet: snippet,
                     match: "leak")
    }

    private func bot(_ id: String, _ name: String? = nil) -> Bot {
        Bot(id: id, name: id, displayName: name ?? id, label: id, avatarInitials: String(id.prefix(1)))
    }

    // MARK: Ordering

    func testFindingsComeBeforeTheBots() {
        let rows = SidebarSearch.rows(hits: [hit("cody", "a leak"), hit("ops", "another leak")],
                                      botIDs: ["cody", "aria"])
        XCTAssertEqual(rows, [.message("cody|s-cody|0.0|a leak"),
                              .message("ops|s-ops|0.0|another leak"),
                              .bot("cody"),
                              .bot("aria")])
    }

    func testEitherSectionAloneIsTheWholeList() {
        XCTAssertEqual(SidebarSearch.rows(hits: [], botIDs: ["cody"]), [.bot("cody")])
        XCTAssertEqual(SidebarSearch.rows(hits: [hit("cody", "leak")], botIDs: []).count, 1)
        XCTAssertTrue(SidebarSearch.rows(hits: [], botIDs: []).isEmpty)
    }

    // MARK: Moving

    func testDownFromNothingLandsOnTheFirstRowAndUpOnTheLast() {
        var selection = SidebarSearchSelection(rows: [.message("a"), .message("b"), .bot("cody")])
        XCTAssertNil(selection.highlighted)

        selection.move(by: 1)
        XCTAssertEqual(selection.highlighted, .message("a"))

        var backwards = SidebarSearchSelection(rows: [.message("a"), .message("b"), .bot("cody")])
        backwards.move(by: -1)
        XCTAssertEqual(backwards.highlighted, .bot("cody"))
    }

    func testTheCursorWrapsAtBothEnds() {
        var selection = SidebarSearchSelection(rows: [.message("a"), .bot("cody")],
                                               highlighted: .bot("cody"))
        selection.move(by: 1)
        XCTAssertEqual(selection.highlighted, .message("a"))
        selection.move(by: -1)
        XCTAssertEqual(selection.highlighted, .bot("cody"))
    }

    func testMovingThroughAnEmptyAnswerDoesNothing() {
        var selection = SidebarSearchSelection()
        selection.move(by: 1)
        selection.move(by: -1)
        XCTAssertNil(selection.highlighted)
        XCTAssertNil(selection.opening)
    }

    // MARK: Reconciling with a new answer

    func testTheHighlightSurvivesARowAppearingAboveIt() {
        var selection = SidebarSearchSelection(rows: [.bot("cody")], highlighted: .bot("cody"))
        selection.update(rows: [.message("a"), .bot("cody")])
        XCTAssertEqual(selection.highlighted, .bot("cody"))
        // Still one step from the top, not two: the cursor is the row, not the index it had.
        selection.move(by: -1)
        XCTAssertEqual(selection.highlighted, .message("a"))
    }

    func testTheHighlightIsDroppedWhenItsRowGoesAway() {
        var selection = SidebarSearchSelection(rows: [.message("a"), .bot("cody")],
                                               highlighted: .message("a"))
        selection.update(rows: [.bot("cody")])
        XCTAssertNil(selection.highlighted)
        XCTAssertEqual(selection.opening, .bot("cody"))
    }

    func testClosingTakesTheHighlightWithIt() {
        var selection = SidebarSearchSelection(rows: [.bot("cody")], highlighted: .bot("cody"))
        selection.clear()
        XCTAssertTrue(selection.rows.isEmpty)
        XCTAssertNil(selection.highlighted)
    }

    func testReturnOpensTheFirstRowWhenNothingIsHighlighted() {
        let selection = SidebarSearchSelection(rows: [.message("a"), .bot("cody")])
        XCTAssertEqual(selection.opening, .message("a"))
    }

    // MARK: The states the panel can be in

    func testOneCharacterIsNotASearch() {
        XCTAssertEqual(SidebarSearch.phase(query: "l", answered: "", running: false,
                                           hits: 0, botMatches: 3),
                       .tooShort)
        // Even with the field boxed in whitespace, and even while something is in flight.
        XCTAssertEqual(SidebarSearch.phase(query: "  l  ", answered: "l", running: true,
                                           hits: 0, botMatches: 0),
                       .tooShort)
    }

    func testAnEmptyFieldIsAPlainRoster() {
        XCTAssertEqual(SidebarSearch.phase(query: "   ", answered: "", running: false,
                                           hits: 12, botMatches: 4),
                       .idle)
    }

    func testFindingsForThisPhraseWin() {
        XCTAssertEqual(SidebarSearch.phase(query: "leak", answered: "leak", running: true,
                                           hits: 3, botMatches: 0),
                       .results)
    }

    func testARequestInFlightSaysSearchingRatherThanNothingFound() {
        XCTAssertEqual(SidebarSearch.phase(query: "leak", answered: "", running: true,
                                           hits: 0, botMatches: 2),
                       .searching)
    }

    func testTheDebounceWindowDoesNotPretendToHaveSearched() {
        // Typed a third character a moment ago: the answer on screen belongs to "lea".
        XCTAssertEqual(SidebarSearch.phase(query: "leak", answered: "lea", running: false,
                                           hits: 0, botMatches: 1),
                       .waiting)
    }

    func testAnAnsweredPhraseWithNoFindingsIsSaidSo() {
        XCTAssertEqual(SidebarSearch.phase(query: "leak", answered: "leak", running: false,
                                           hits: 0, botMatches: 2),
                       .messagesEmpty)
    }

    func testNothingAtAllIsTheOnlyNoMatches() {
        XCTAssertEqual(SidebarSearch.phase(query: "leak", answered: "leak", running: false,
                                           hits: 0, botMatches: 0),
                       .noMatches)
    }

    // MARK: Bot name filtering

    func testBotNamesStillAnswerTheSameQuery() {
        XCTAssertTrue(SidebarSearch.matches(bot("cody", "Cody"), query: "cod"))
        XCTAssertTrue(SidebarSearch.matches(bot("CODY", "Something"), query: "cody"))
        XCTAssertFalse(SidebarSearch.matches(bot("cody", "Cody"), query: "leak"))
        // No query is no filter.
        XCTAssertTrue(SidebarSearch.matches(bot("cody", "Cody"), query: "  "))
    }
}

#endif
