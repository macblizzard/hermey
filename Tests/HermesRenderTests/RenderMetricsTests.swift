import XCTest
@testable import HermesRender

final class RenderMetricsTests: XCTestCase {

    func testIOSMatchesOpenBotChatText() {
        XCTAssertEqual(ChatTextMetrics.iOS.bodySize, 16)
        XCTAssertEqual(ChatTextMetrics.iOS.bodyLineHeight, 22)
        XCTAssertEqual(ChatTextMetrics.iOS.bodyLineHeightMultiple, 22.0 / 16.0, accuracy: 0.0001)
    }

    func testMacOSMatchesOpenBotChatText() {
        XCTAssertEqual(ChatTextMetrics.macOS.bodySize, 14)
        XCTAssertEqual(ChatTextMetrics.macOS.bodyLineHeight, 22.68, accuracy: 0.001)
        XCTAssertEqual(ChatTextMetrics.macOS.bodyLineHeightMultiple, 1.62, accuracy: 0.0001)
    }

    func testCodeSizeMatchesTokensMono() {
        XCTAssertEqual(ChatTextMetrics.iOS.codeSize, 11.5)
        XCTAssertEqual(ChatTextMetrics.macOS.codeSize, 11.5)
    }

    func testPlatformLookup() {
        XCTAssertEqual(ChatTextMetrics.forPlatform(.iOS), .iOS)
        XCTAssertEqual(ChatTextMetrics.forPlatform(.macOS), .macOS)
    }

    func testHeadingRampDescendsAndNeverGoesBelowBody() {
        let sizes = (1...6).map { ChatTextMetrics.macOS.fontSize(for: .heading(level: $0, text: "h")) }
        XCTAssertEqual(sizes.first, 21)            // 14 × 1.5
        XCTAssertEqual(sizes, sizes.sorted(by: >))
        XCTAssertGreaterThanOrEqual(sizes.last!, ChatTextMetrics.macOS.bodySize)

        let clamped = ChatTextMetrics.macOS.fontSize(for: .heading(level: 99, text: "h"))
        XCTAssertEqual(clamped, sizes[5], "levels above 6 clamp to h6")
    }

    func testBlockSizes() {
        let metrics = ChatTextMetrics.iOS
        XCTAssertEqual(metrics.fontSize(for: .paragraph("x")), 16)
        XCTAssertEqual(metrics.fontSize(for: .bullet("x")), 16)
        XCTAssertEqual(metrics.fontSize(for: .quote("x")), 16)
        XCTAssertEqual(metrics.fontSize(for: .code(language: "swift", body: "x", closed: true)), 11.5)
        XCTAssertEqual(metrics.lineHeight(for: .paragraph("x")), 22)
        XCTAssertEqual(metrics.lineHeight(for: .code(language: nil, body: "x", closed: false)), metrics.codeLineHeight)
    }

    func testLineSpacingIsPositiveAndSmallerThanLineHeight() {
        XCTAssertGreaterThan(ChatTextMetrics.iOS.estimatedLineSpacing, 0)
        XCTAssertLessThan(ChatTextMetrics.iOS.estimatedLineSpacing, ChatTextMetrics.iOS.bodyLineHeight)
    }
}
