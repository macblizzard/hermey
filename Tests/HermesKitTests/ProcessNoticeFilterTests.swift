import XCTest
@testable import HermesKit

/// Operational notices from the host's background-process runner are not bot conversation. They used
/// to arrive as giant user rows with command lines and poll output, hiding real messages.
final class ProcessNoticeFilterTests: XCTestCase {
    func testTheExactRuntimeBannerIsRecognised() {
        XCTAssertTrue(GatewayPayloadDecoder.isProcessNotice(
            "[IMPORTANT: Background process proc_a1aeb45cec3f exited (exit code 1). Command: …"))
        XCTAssertTrue(GatewayPayloadDecoder.isProcessNotice(
            "[IMPORTANT: Background process proc_x finished"))
    }

    func testOrdinaryMessagesAreKept() {
        XCTAssertFalse(GatewayPayloadDecoder.isProcessNotice("Please check the background process."))
        XCTAssertFalse(GatewayPayloadDecoder.isProcessNotice("Important: the build is done"))
        XCTAssertFalse(GatewayPayloadDecoder.isProcessNotice(""))
    }
}
