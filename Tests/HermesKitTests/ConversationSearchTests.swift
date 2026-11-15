import XCTest
@testable import HermesKit

/// The in-chat search: what it matches, what it says, and how it steps.
///
/// The bug being pinned down: a query typed one character at a time must keep answering. Both
/// platforms answered `1 of 3` at two characters and then `No matches` at three — the count fell
/// off a cliff that the query did not explain. A substring matcher over folded text cannot do that,
/// and these tests say so out loud instead of trusting it.
final class ConversationSearchTests: XCTestCase {

    /// A transcript in the shape the apps hand the matcher: an id and the text drawn for the row.
    private struct Row {
        let id: String
        let text: String
    }

    private let conversation: [Row] = [
        Row(id: "u1", text: "open the CrowdSec panel and check the bans"),
        Row(id: "a1", text: "The CrowdSec rules are loaded; two bans are active."),
        Row(id: "t1", text: "terminal · docker logs crowdsec"),
        Row(id: "u2", text: "did the vault rotate"),
        Row(id: "a2", text: "the vault\nholds the key, rotated at 04:00"),
        Row(id: "a3", text: "unrelated: the café on the corner résumé"),
    ]

    private func ids(_ query: String, extra: (id: String, text: String)? = nil) -> [String] {
        ConversationSearch.ids(matching: query, in: conversation,
                               id: \.id, text: \.text, extra: extra)
    }

    // MARK: - Inactive

    func testAnEmptyQueryIsInactive() {
        for query in ["", " ", "   ", "\n", "\t \n "] {
            XCTAssertFalse(ConversationSearch.isActive(query), "\(query.debugDescription) is not a search")
            XCTAssertEqual(ids(query), [], "an empty field matches nothing, not everything")
            XCTAssertEqual(ConversationSearch.status(query: query, matched: 0, index: 0), "",
                           "an empty field says nothing")
        }
    }

    func testAnInactiveQueryNeverMatchesText() {
        XCTAssertFalse(ConversationSearch.matches("", in: "anything"))
        XCTAssertFalse(ConversationSearch.matches("   ", in: "anything"))
    }

    // MARK: - One, two, three, four characters

    func testOneCharacterIsAlreadyASearch() {
        // 1 character answers, per keystroke: the old bot-list path refused it, which is why the
        // field looked dead until the second letter.
        XCTAssertTrue(ConversationSearch.isActive("c"))
        XCTAssertEqual(ids("c"), ["u1", "a1", "t1", "a3"])
    }

    func testTwoCharactersNarrowTheAnswerWithoutLosingIt() {
        XCTAssertEqual(ids("cr"), ["u1", "a1", "t1"])
    }

    func testThreeCharactersStillAnswer() {
        XCTAssertEqual(ids("cro"), ["u1", "a1", "t1"])
    }

    func testFourCharactersStillAnswer() {
        XCTAssertEqual(ids("crow"), ["u1", "a1", "t1"])
    }

    /// The report, as a test: type `crowd`, `crowds`, `crowdse`, `crowdsec` one keystroke at a time.
    /// The answer may narrow. It may never empty out on a row that contains the word, and it may
    /// never grow on a keystroke.
    func testAQueryThatGrowsOneToTwoToThreeToFourNeverLosesAMatch() {
        let prefixes = ["c", "cr", "cro", "crow"]
        var previous: [String] = []
        var counts: [Int] = []
        for prefix in prefixes {
            let found = ids(prefix)
            XCTAssertFalse(found.isEmpty, "\(prefix.debugDescription) lost every match")
            XCTAssertTrue(found.contains("u1"), "\(prefix.debugDescription) lost the row it matches")
            if !previous.isEmpty {
                XCTAssertTrue(Set(found).isSubset(of: Set(previous)),
                              "\(prefix.debugDescription) added a match the shorter query did not have")
            }
            previous = found
            counts.append(found.count)
        }
        XCTAssertEqual(counts, counts.sorted(by: >), "a growing query may only narrow the answer: \(counts)")
        XCTAssertEqual(counts.last, 3)
    }

    /// The same walk over every prefix of a real phrase, against every row: the general form of the
    /// property, not one hand-picked example.
    func testEveryLongerQueryMatchesASubsetOfTheShorterOne() {
        let phrase = "the crowdsec rules are loaded"
        let windows = conversation.map { row in row.text.map { String($0) }.joined() }
        for length in 2...phrase.count {
            let shorter = String(phrase.prefix(length - 1))
            let longer = String(phrase.prefix(length))
            for text in windows {
                if ConversationSearch.matches(longer, in: text) {
                    XCTAssertTrue(ConversationSearch.matches(shorter, in: text),
                                  "\(longer.debugDescription) matched text \(shorter.debugDescription) did not")
                }
            }
        }
    }

    func testAFullQueryMatchesTheRowItComesFrom() {
        XCTAssertEqual(ids("crowdsec rules"), ["a1"])
        XCTAssertEqual(ids("crowdsec"), ["u1", "a1", "t1"])
    }

    // MARK: - Folding

    func testCaseIsIgnored() {
        XCTAssertEqual(ids("CROWDSEC"), ["u1", "a1", "t1"])
        XCTAssertEqual(ids("CrowdSec"), ["u1", "a1", "t1"])
    }

    func testDiacriticsAreIgnoredInBothDirections() {
        // Text is accented and the query is not…
        XCTAssertEqual(ids("cafe"), ["a3"])
        XCTAssertEqual(ids("resume"), ["a3"])
        // …and the query is accented while the text is not.
        XCTAssertEqual(ids("café"), ["a3"])
        XCTAssertEqual(ids("résumé"), ["a3"])
        XCTAssertTrue(ConversationSearch.matches("naive", in: "naïve"))
        XCTAssertTrue(ConversationSearch.matches("İstanbul", in: "istanbul"))
    }

    func testWidthFoldingKeepsFullWidthTextSearchable() {
        XCTAssertTrue(ConversationSearch.matches("vault", in: "ｖａｕｌｔ"))
    }

    func testARowWrappedByTheRendererMatchesAPhraseAcrossTheBreak() {
        // Stored as two lines, drawn as one sentence.
        XCTAssertEqual(ids("vault holds"), ["a2"])
        XCTAssertEqual(ids("vault\nholds"), ["a2"])
    }

    func testRunOfWhitespaceInTheQueryAndTheRowAreTheSameSeparator() {
        XCTAssertEqual(ids("vault    holds"), ["a2"])
        XCTAssertTrue(ConversationSearch.matches("  the   vault  ", in: "the vault holds the key"))
    }

    func testTheEmptyAnswerQuotesTheQueryAsTyped() {
        XCTAssertEqual(ConversationSearch.status(query: "  Zzz  ", matched: 0, index: 0),
                       "No matches for “Zzz”")
    }

    // MARK: - Status

    func testStatusReadsThePositionAndTheTotal() {
        XCTAssertEqual(ConversationSearch.status(query: "crowdsec", matched: 3, index: 0), "1 of 3")
        XCTAssertEqual(ConversationSearch.status(query: "crowdsec", matched: 3, index: 2), "3 of 3")
        XCTAssertEqual(ConversationSearch.status(query: "crowdsec", matched: 1, index: 0), "1 of 1")
        XCTAssertEqual(ConversationSearch.status(query: "", matched: 0, index: 0), "")
    }

    func testStatusNeverPointsPastTheEndAfterTheQueryNarrowed() {
        // The index was earned when there were nine matches; the query now has two.
        XCTAssertEqual(ConversationSearch.status(query: "cr", matched: 2, index: 8), "2 of 2")
    }

    func testTheNoMatchesSentenceNamesTheQuery() {
        XCTAssertEqual(ConversationSearch.status(query: "vau", matched: 0, index: 0),
                       "No matches for “vau”")
    }

    // MARK: - Index and navigation

    func testClampingAtEveryLength() {
        XCTAssertEqual(ConversationSearch.clamped(0, count: 0), 0)
        XCTAssertEqual(ConversationSearch.clamped(4, count: 0), 0)
        XCTAssertEqual(ConversationSearch.clamped(-3, count: 2), 0)
        XCTAssertEqual(ConversationSearch.clamped(0, count: 2), 0)
        XCTAssertEqual(ConversationSearch.clamped(1, count: 2), 1)
        XCTAssertEqual(ConversationSearch.clamped(9, count: 2), 1)
    }

    func testNextAndPreviousWorkAtEveryLength() {
        // Nothing to step through: the index stays put and the buttons are disabled by the count.
        XCTAssertEqual(ConversationSearch.stepped(0, count: 0, by: 1), 0)
        XCTAssertEqual(ConversationSearch.stepped(0, count: 0, by: -1), 0)

        // One result: both directions land back on it.
        XCTAssertEqual(ConversationSearch.stepped(0, count: 1, by: 1), 0)
        XCTAssertEqual(ConversationSearch.stepped(0, count: 1, by: -1), 0)

        // Two: forward, back, and the wrap.
        XCTAssertEqual(ConversationSearch.stepped(0, count: 2, by: 1), 1)
        XCTAssertEqual(ConversationSearch.stepped(1, count: 2, by: 1), 0)
        XCTAssertEqual(ConversationSearch.stepped(0, count: 2, by: -1), 1)

        // Five: a full lap in each direction.
        var index = 0
        for _ in 0..<5 { index = ConversationSearch.stepped(index, count: 5, by: 1) }
        XCTAssertEqual(index, 0)
        index = 0
        for _ in 0..<5 { index = ConversationSearch.stepped(index, count: 5, by: -1) }
        XCTAssertEqual(index, 0)
    }

    func testSteppingFromAStaleIndexIsDefined() {
        // Nine results gave index 8; the query narrowed to two. Next must go to 0, not past the end.
        XCTAssertEqual(ConversationSearch.stepped(8, count: 2, by: 1), 0)
        XCTAssertEqual(ConversationSearch.stepped(8, count: 2, by: -1), 0)
    }

    // MARK: - The live turn

    func testTheLiveTurnIsSearchedAndComesLast() {
        let extra = (id: "conversation-streaming-search", text: "the crowdsec scan is still running")
        XCTAssertEqual(ids("crowdsec", extra: extra),
                       ["u1", "a1", "t1", "conversation-streaming-search"])
        XCTAssertEqual(ids("still running", extra: extra), ["conversation-streaming-search"])
        XCTAssertEqual(ids("", extra: extra), [], "an empty field does not find the live turn either")
    }

    // MARK: - Order

    func testResultsKeepTranscriptOrder() {
        XCTAssertEqual(ids("the"), ["u1", "a1", "u2", "a2", "a3"])
    }

    func testNothingOffTheConversationComesBack() {
        XCTAssertEqual(ids("zeppelin"), [])
        XCTAssertEqual(ConversationSearch.status(query: "zeppelin", matched: 0, index: 0),
                       "No matches for “zeppelin”")
    }
}
