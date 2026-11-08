import XCTest
@testable import HermesRender

final class TranscriptRendererTests: XCTestCase {

    func testAppendCompilesOnlyChangedBlocks() {
        var renderer = TranscriptRenderer(metrics: .iOS)
        renderer.append("one\n\ntwo")
        XCTAssertEqual(renderer.blockCount, 2)
        XCTAssertEqual(renderer.compileCount, 2)

        let changed = renderer.append("!")
        XCTAssertEqual(changed, [1], "only the live paragraph changed")
        XCTAssertEqual(renderer.compileCount, 3, "the finished paragraph was not recompiled")
        XCTAssertEqual(renderer.texts.map { String($0.characters) }, ["one", "two!"])
    }

    func testNewBlockCompilesOnce() {
        var renderer = TranscriptRenderer()
        renderer.append("first")
        XCTAssertEqual(renderer.compileCount, 1)

        renderer.append("\n\nsecond")
        XCTAssertEqual(renderer.blockCount, 2)
        XCTAssertEqual(renderer.compileCount, 2)
        XCTAssertEqual(renderer.attributed(at: 0).map { String($0.characters) }, "first")
    }

    func testLongTranscriptStreamingCostIsBounded() {
        var renderer = TranscriptRenderer()
        let paragraphs = (1...200).map { "paragraph number \($0)" }.joined(separator: "\n\n")
        renderer.append(paragraphs)
        let afterBulk = renderer.compileCount
        XCTAssertEqual(afterBulk, 200)

        for token in [" much", " better"] {
            renderer.append(token)
        }
        XCTAssertEqual(renderer.compileCount, afterBulk + 2, "two tokens, two recompiles — not 400")

        let beforeWhitespace = renderer.compileCount
        XCTAssertEqual(renderer.append("   "), [], "trailing spaces do not change a block")
        XCTAssertEqual(renderer.compileCount, beforeWhitespace, "and cost no recompile")
    }

    func testCodeBlockStreamsAndFinalises() {
        var renderer = TranscriptRenderer()
        renderer.append("```swift\nlet x = 1")
        XCTAssertEqual(renderer.blockCount, 1)

        let attributed = renderer.attributed(at: 0)
        XCTAssertEqual(attributed.map { String($0.characters) }, "let x = 1")
        XCTAssertEqual(attributed?.runs.first?.attributes[CodeTokenAttribute.self], .keyword)

        renderer.append("\nlet y = 2\n```")
        XCTAssertEqual(renderer.blockCount, 1)
        XCTAssertEqual(renderer.compileCount, 2)
        let numbers = renderer.attributed(at: 0)?.runs.filter {
            $0.attributes[CodeTokenAttribute.self] == .number
        }.count
        XCTAssertEqual(numbers, 2)
    }

    func testResetClearsCache() {
        var renderer = TranscriptRenderer()
        renderer.append("some text")
        XCTAssertEqual(renderer.compileCount, 1)

        renderer.reset(source: "fresh")
        XCTAssertEqual(renderer.blockCount, 1)
        XCTAssertEqual(renderer.compileCount, 1)
        XCTAssertEqual(renderer.texts.map { String($0.characters) }, ["fresh"])
    }

    func testOnDemandRenderUsesCache() {
        var renderer = TranscriptRenderer()
        renderer.append("cached")
        XCTAssertEqual(renderer.render(at: 0).map { String($0.characters) }, "cached")
        XCTAssertEqual(renderer.compileCount, 1, "rendering an already-rendered block is free")
        XCTAssertNil(renderer.render(at: 9))
    }

    func testMetricsDriveBlockText() {
        var renderer = TranscriptRenderer(metrics: .macOS)
        renderer.append("body")
        XCTAssertEqual(renderer.metrics.bodySize, 14)
    }
}
