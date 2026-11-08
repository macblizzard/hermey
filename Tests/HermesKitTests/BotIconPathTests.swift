import XCTest
@testable import HermesKit

final class BotIconPathTests: XCTestCase {
    func testIconPathRejectsSlashAndPreservesExactProfile() throws {
        XCTAssertThrowsError(try BotIconPath.component(for: "a/b"))
        XCTAssertThrowsError(try BotIconPath.component(for: "  "))
        XCTAssertEqual(try BotIconPath.component(for: " bot #1 "), " bot #1 ")
    }
}
