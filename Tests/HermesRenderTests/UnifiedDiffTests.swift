import XCTest
@testable import HermesRender

final class UnifiedDiffTests: XCTestCase {

    private let patch = """
    diff --git a/Sources/A.swift b/Sources/A.swift
    index 1111111..2222222 100644
    --- a/Sources/A.swift
    +++ b/Sources/A.swift
    @@ -1,4 +1,5 @@ struct A {
     let a = 1
    -let b = 2
    +let b = 3
    +let c = 4
     let d = 5
     }
    diff --git a/notes.md b/notes.md
    --- a/notes.md
    +++ b/notes.md
    @@ -10,2 +10,2 @@
    -old
    +new
     context
    """

    func testParsesTwoFiles() {
        let files = UnifiedDiff.parse(patch)
        XCTAssertEqual(files.count, 2)

        XCTAssertEqual(files[0].oldPath, "Sources/A.swift")
        XCTAssertEqual(files[0].newPath, "Sources/A.swift")
        XCTAssertEqual(files[0].displayPath, "Sources/A.swift")
        XCTAssertEqual(files[0].hunks.count, 1)
        XCTAssertEqual(files[0].addedCount, 2)
        XCTAssertEqual(files[0].removedCount, 1)

        XCTAssertEqual(files[1].displayPath, "notes.md")
        XCTAssertEqual(files[1].hunks.count, 1)
    }

    func testHunkHeaderAndLineNumbers() {
        let hunk = UnifiedDiff.parse(patch)[0].hunks[0]
        XCTAssertEqual(hunk.oldStart, 1)
        XCTAssertEqual(hunk.oldCount, 4)
        XCTAssertEqual(hunk.newStart, 1)
        XCTAssertEqual(hunk.newCount, 5)
        XCTAssertEqual(hunk.section, "struct A {")

        XCTAssertEqual(hunk.lines.map(\.kind), [
            .context, .deletion, .addition, .addition, .context, .context,
        ])
        XCTAssertEqual(hunk.lines.map(\.oldNumber), [1, 2, nil, nil, 3, 4])
        XCTAssertEqual(hunk.lines.map(\.newNumber), [1, nil, 2, 3, 4, 5])
        XCTAssertEqual(hunk.lines[1].text, "let b = 2")
        XCTAssertEqual(hunk.lines[2].text, "let b = 3")
    }

    func testSecondHunkStartsAtItsOwnLineNumbers() {
        let hunk = UnifiedDiff.parse(patch)[1].hunks[0]
        XCTAssertEqual(hunk.lines.map(\.oldNumber), [10, nil, 11])
        XCTAssertEqual(hunk.lines.map(\.newNumber), [nil, 10, 11])
    }

    func testHeaderRoundTrips() {
        let files = UnifiedDiff.parse(patch)
        XCTAssertEqual(UnifiedDiff.header(for: files[0].hunks[0]), "@@ -1,4 +1,5 @@ struct A {")
        XCTAssertEqual(UnifiedDiff.header(for: files[1].hunks[0]), "@@ -10,2 +10,2 @@")
    }

    func testNoNewlineMarker() {
        let text = """
        --- a/x.txt
        +++ b/x.txt
        @@ -1 +1 @@
        -old
        \\ No newline at end of file
        +new
        """
        let file = UnifiedDiff.parse(text)[0]
        XCTAssertEqual(file.hunks[0].lines.map(\.kind), [.deletion, .noNewline, .addition])
        XCTAssertEqual(file.hunks[0].lines[1].text, "No newline at end of file")
    }

    func testNewFileUsesDevNullForOldPath() {
        let text = """
        diff --git a/new.txt b/new.txt
        new file mode 100644
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +one
        +two
        """
        let files = UnifiedDiff.parse(text)
        XCTAssertEqual(files.count, 1)
        XCTAssertNil(files[0].oldPath)
        XCTAssertEqual(files[0].newPath, "new.txt")
        XCTAssertEqual(files[0].hunks[0].oldCount, 0)
        XCTAssertEqual(files[0].hunks[0].lines.map(\.newNumber), [1, 2])
    }

    func testBinaryFile() {
        let text = """
        diff --git a/logo.png b/logo.png
        index 1111111..2222222 100644
        Binary files a/logo.png and b/logo.png differ
        """
        let files = UnifiedDiff.parse(text)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].isBinary)
        XCTAssertEqual(files[0].displayPath, "logo.png")
        XCTAssertTrue(files[0].hunks.isEmpty)
    }

    func testRowsFlattenHeadersHunksAndLines() {
        let rows = UnifiedDiff.rows(patch)
        guard case .file(let index, _, _) = rows[0] else { return XCTFail("expected file header first") }
        XCTAssertEqual(index, 0)
        guard case .hunk(_, _, let header) = rows[1] else { return XCTFail("expected hunk header second") }
        XCTAssertEqual(header, "@@ -1,4 +1,5 @@ struct A {")
        guard case .line(_, _, let line) = rows[2] else { return XCTFail("expected a line third") }
        XCTAssertEqual(line.kind, .context)

        let lineCount = rows.filter { row in
            if case .line = row { return true } else { return false }
        }.count
        XCTAssertEqual(lineCount, 9)
    }

    func testPlainUnifiedDiffWithTwoFiles() {
        let text = """
        --- a/one.txt
        +++ b/one.txt
        @@ -1 +1 @@
        -one
        +ONE
        --- a/two.txt
        +++ b/two.txt
        @@ -1 +1 @@
        -two
        +TWO
        """
        let files = UnifiedDiff.parse(text)
        XCTAssertEqual(files.count, 2, "a second `---` header starts a new file, even without `diff --git`")
        XCTAssertEqual(files.map(\.displayPath), ["one.txt", "two.txt"])
        XCTAssertEqual(files.map(\.addedCount), [1, 1])
    }

    func testNoNewlineMarkerAfterCountsAreExhausted() {
        let text = "--- a/x.txt\n+++ b/x.txt\n@@ -1,1 +1,1 @@\n same\n\\ No newline at end of file"
        let lines = UnifiedDiff.parse(text)[0].hunks[0].lines
        XCTAssertEqual(lines.map(\.kind), [.context, .noNewline])
    }

    func testMalformedInputDoesNotThrowOrSwallowFollowingFiles() {
        let text = """
        @@ this is not a hunk
        diff --git a/a b/a
        --- a/a
        +++ b/a
        @@ -1,1 +1,1 @@
        -one
        +two
        """
        let files = UnifiedDiff.parse(text)
        XCTAssertEqual(files.count, 1, "garbage before the first file header is dropped")
        XCTAssertEqual(files[0].hunks.count, 1)
        XCTAssertEqual(files[0].hunks[0].lines.map(\.kind), [.deletion, .addition])
    }
}
