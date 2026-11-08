import XCTest
@testable import HermesAttachmentCore

/// The attachment budget, name rules and downscaling ladder: the parts of the attachment
/// path that are arithmetic rather than UIKit. They are pinned here so a change to the
/// limit or to the ladder is a failing test instead of a rejected upload on a phone.
final class AttachmentBudgetTests: XCTestCase {

    // MARK: Limit

    func testLimitIsEightMebibytes() {
        XCTAssertEqual(AttachmentBudget.maximumBytes, 8 * 1024 * 1024)
    }

    /// The encoded form has to survive one websocket frame, and the gateway's `server.py`
    /// only allows `file.attach` frames above 16 MiB.
    func testEightMebibytesOfPayloadStaysInsideOneWebsocketFrame() {
        let encoded = AttachmentBudget.base64EncodedByteCount(for: AttachmentBudget.maximumBytes)
        XCTAssertEqual(encoded, 11_184_812)                      // ceil(8 MiB / 3) * 4
        XCTAssertLessThan(encoded, AttachmentBudget.gatewayFrameBytes)
        XCTAssertTrue(AttachmentBudget.fitsInFrame(AttachmentBudget.maximumBytes))
    }

    /// Pins the requirement the bridge has to meet, because it is the smaller of the two
    /// frame ceilings: 8 MiB of payload is ~10.7 MiB of base64, which does not fit the
    /// bridge's current hard maximum of 8 MiB (`MAX_FRAME_CAP` in
    /// `Bridge/hermes_bridge/config.py`). That cap has to move before this limit is usable.
    func testTheRequiredBridgeFrameCapIsKnownAndExceedsTheBridgesCurrentMaximum() {
        XCTAssertEqual(AttachmentBudget.requiredBridgeFrameBytes, 11_184_812 + 128 * 1024)
        XCTAssertGreaterThan(AttachmentBudget.requiredBridgeFrameBytes, 8 * 1024 * 1024,
                             "a maximum attachment cannot fit the bridge's 8 MiB frame cap")
        XCTAssertLessThan(AttachmentBudget.requiredBridgeFrameBytes, AttachmentBudget.gatewayFrameBytes)
    }

    func testAPayloadFarOverTheFrameCeilingIsRejectedByTheFrameCheck() {
        XCTAssertFalse(AttachmentBudget.fitsInFrame(13 * 1024 * 1024))
    }

    func testBase64LengthRoundsUpToWholeGroups() {
        XCTAssertEqual(AttachmentBudget.base64EncodedByteCount(for: 0), 0)
        XCTAssertEqual(AttachmentBudget.base64EncodedByteCount(for: 1), 4)
        XCTAssertEqual(AttachmentBudget.base64EncodedByteCount(for: 3), 4)
        XCTAssertEqual(AttachmentBudget.base64EncodedByteCount(for: 4), 8)
    }

    func testEmptyAndOversizedAttachmentsAreRefusedWithTheRealLimit() {
        XCTAssertThrowsError(try AttachmentBudget.validate(byteCount: 0)) { error in
            XCTAssertEqual(error as? AttachmentBudgetError, .empty)
        }
        XCTAssertNoThrow(try AttachmentBudget.validate(byteCount: AttachmentBudget.maximumBytes))
        XCTAssertThrowsError(try AttachmentBudget.validate(byteCount: AttachmentBudget.maximumBytes + 1)) { error in
            let budgetError = error as? AttachmentBudgetError
            guard case .tooLarge(let byteCount, let maximum)? = budgetError else {
                return XCTFail("expected .tooLarge, got \(String(describing: error))")
            }
            XCTAssertEqual(byteCount, AttachmentBudget.maximumBytes + 1)
            XCTAssertEqual(maximum, 8 * 1024 * 1024)
            XCTAssertEqual(budgetError?.errorDescription?.contains("8 MB"), true,
                           "the message must name the limit the user actually hit")
        }
    }

    func testHumanSizeReadsLikeAPersonWroteIt() {
        XCTAssertEqual(AttachmentBudget.humanSize(8 * 1024 * 1024), "8 MB")
        XCTAssertEqual(AttachmentBudget.humanSize(512 * 1024), "512 KB")
        XCTAssertEqual(AttachmentBudget.humanSize(1536), "1.5 KB")
        XCTAssertEqual(AttachmentBudget.humanSize(1500 * 1024), "1.5 MB")
        XCTAssertEqual(AttachmentBudget.humanSize(700), "700 bytes")
    }

    // MARK: Names

    func testPlainNameIsKept() {
        XCTAssertEqual(AttachmentName.sanitized("IMG_0001.HEIC"), "IMG_0001.HEIC")
    }

    func testProviderURLDirectoriesAreDropped() {
        XCTAssertEqual(AttachmentName.sanitized("/private/var/mobile/Inbox/report.pdf"), "report.pdf")
        XCTAssertEqual(AttachmentName.sanitized("C:\\Users\\me\\notes.txt"), "notes.txt")
    }

    func testControlCharactersAndSeparatorsNeverReachTheHost() {
        let name = AttachmentName.sanitized("bad\u{0}name\nwith\rbreaks.txt")
        XCTAssertEqual(name, "badnamewithbreaks.txt")
        XCTAssertNil(name?.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\\u{0}\n\r")))
    }

    func testWhitespaceRunsCollapseAndTrim() {
        XCTAssertEqual(AttachmentName.sanitized("  my   photo   two.jpg  "), "my photo two.jpg")
    }

    func testDotNamesAreRefused() {
        XCTAssertNil(AttachmentName.sanitized("."))
        XCTAssertNil(AttachmentName.sanitized(".."))
        XCTAssertNil(AttachmentName.sanitized("   "))
        XCTAssertNil(AttachmentName.sanitized("/"))
        XCTAssertNil(AttachmentName.sanitized("\u{0}\u{1}"))
    }

    func testLongNamesAreTruncatedButKeepTheirExtension() {
        let stem = String(repeating: "a", count: 400)
        let name = AttachmentName.sanitized(stem + ".jpeg")
        XCTAssertNotNil(name)
        XCTAssertTrue(name!.hasSuffix(".jpeg"), "the host still needs to know the type")
        XCTAssertLessThanOrEqual(name!.utf8.count, AttachmentBudget.maximumNameBytes)
        XCTAssertTrue(name!.hasPrefix("aaaa"))
    }

    func testMultibyteNamesAreCutOnACharacterBoundary() {
        // Each emoji is 4 UTF-8 bytes: 100 of them is 400 bytes, over the cap.
        let name = AttachmentName.sanitized(String(repeating: "🙂", count: 100) + ".png")
        XCTAssertNotNil(name)
        XCTAssertLessThanOrEqual(name!.utf8.count, AttachmentBudget.maximumNameBytes)
        XCTAssertTrue(name!.hasSuffix(".png"))
        XCTAssertFalse(name!.contains("\u{FFFD}"), "a cut must not leave a broken scalar")
    }

    func testNameExactlyAtTheLimitIsUnchanged() {
        let stem = String(repeating: "b", count: 247)
        let name = stem + ".mov"
        XCTAssertEqual(name.utf8.count, 251)
        XCTAssertEqual(AttachmentName.sanitized(name), name)
    }

    // MARK: Downscaling decision

    func testAPhotoThatAlreadyFitsIsNeverTouched() {
        let steps = ImageDownscale.steps(decodedBytes: 2 * 1024 * 1024,
                                         pixelWidth: 4032, pixelHeight: 3024)
        XCTAssertTrue(steps.isEmpty, "no re-encode, no quality loss")
        XCTAssertFalse(ImageDownscale.needsReencoding(decodedBytes: 2 * 1024 * 1024,
                                                      pixelWidth: 4032, pixelHeight: 3024))
    }

    func testExactlyAtTheLimitStillFits() {
        let steps = ImageDownscale.steps(decodedBytes: AttachmentBudget.maximumBytes,
                                         pixelWidth: 4032, pixelHeight: 3024)
        XCTAssertTrue(steps.isEmpty)
    }

    func testOneByteOverStartsTheLadder() {
        XCTAssertTrue(ImageDownscale.needsReencoding(decodedBytes: AttachmentBudget.maximumBytes + 1,
                                                     pixelWidth: 4032, pixelHeight: 3024))
    }

    func testTheLadderStartsAtThePhotosOwnLongEdgeAndShrinks() {
        let steps = ImageDownscale.steps(decodedBytes: 12 * 1024 * 1024,
                                         pixelWidth: 4032, pixelHeight: 3024)
        XCTAssertFalse(steps.isEmpty)
        XCTAssertEqual(steps.first, ImageDownscaleStep(maxPixelDimension: 4032, quality: 0.8))
        XCTAssertLessThanOrEqual(steps.count, ImageDownscale.maximumSteps)
        let dimensions = steps.map(\.maxPixelDimension)
        XCTAssertEqual(dimensions, dimensions.sorted(by: >), "largest first, so quality falls last")
        XCTAssertTrue(dimensions.allSatisfy { $0 <= 4032 })
        XCTAssertTrue(steps.allSatisfy { (0...1).contains($0.quality) })
    }

    func testAPortraitPhotoIsMeasuredByItsLongEdge() {
        let steps = ImageDownscale.steps(decodedBytes: 9 * 1024 * 1024,
                                         pixelWidth: 3024, pixelHeight: 4032)
        XCTAssertEqual(steps.first?.maxPixelDimension, 4032)
    }

    func testAPhotoSmallerThanTheLadderNeverGrows() {
        let steps = ImageDownscale.steps(decodedBytes: 9 * 1024 * 1024,
                                         pixelWidth: 1200, pixelHeight: 900)
        XCTAssertEqual(Array(steps.prefix(3)).map(\.maxPixelDimension), [1200, 1200, 1200],
                       "the photo's own long edge comes first, never an upscale")
        XCTAssertTrue(steps.allSatisfy { $0.maxPixelDimension <= 1200 })
    }

    func testUnknownGeometryReencodesWithoutResizing() {
        let steps = ImageDownscale.steps(decodedBytes: 9 * 1024 * 1024, pixelWidth: 0, pixelHeight: 0)
        XCTAssertEqual(steps.count, ImageDownscale.qualityLadder.count)
        XCTAssertTrue(steps.allSatisfy { $0.maxPixelDimension == 0 })
    }

    func testZeroLimitIsNotALadder() {
        XCTAssertTrue(ImageDownscale.steps(decodedBytes: 1, pixelWidth: 10, pixelHeight: 10, limit: 0).isEmpty)
    }

    func testEstimatesGrowWithPixelsAndWithQuality() {
        XCTAssertGreaterThan(ImageDownscale.estimatedJPEGBytes(maxPixelDimension: 2048, quality: 0.8),
                             ImageDownscale.estimatedJPEGBytes(maxPixelDimension: 1024, quality: 0.8))
        XCTAssertGreaterThan(ImageDownscale.estimatedJPEGBytes(maxPixelDimension: 2048, quality: 0.8),
                             ImageDownscale.estimatedJPEGBytes(maxPixelDimension: 2048, quality: 0.4))
        XCTAssertEqual(ImageDownscale.estimatedJPEGBytes(maxPixelDimension: 0, quality: 0.8), 0)
    }

    /// A 48 MP HEIC off a modern iPhone: the first rung must still be a real attempt, and the
    /// ladder must end somewhere a photo of a wall would fit.
    func testAFortyEightMegapixelPhotoGetsAWorkableLadder() {
        let steps = ImageDownscale.steps(decodedBytes: 60 * 1024 * 1024,
                                         pixelWidth: 8064, pixelHeight: 6048)
        XCTAssertFalse(steps.isEmpty)
        XCTAssertEqual(steps.first?.maxPixelDimension, 8064)
        XCTAssertLessThanOrEqual(steps.last!.maxPixelDimension, 2048)
        XCTAssertLessThanOrEqual(steps.count, ImageDownscale.maximumSteps)
    }
}
