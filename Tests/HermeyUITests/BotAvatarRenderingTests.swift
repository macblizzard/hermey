import SwiftUI
import XCTest
@testable import HermeyUI
import HermesKit

// What only a device (or a Mac with SwiftUI) can check: the parsed commands really become a `Path`
// with finite bounds and the ink lands inside the frame. The numbers behind them — and every parity
// case against the reference — live in BotAvatarParityTests.swift, which has no SwiftUI import and
// therefore runs off-device too.

final class BotAvatarRenderingTests: XCTestCase {

    func testEveryShippedShapeBecomesANonEmptyPathWithFiniteBounds() {
        XCTAssertEqual(BotAvatarShape.shipped.count, 8)
        for shape in BotAvatarShape.shipped {
            XCTAssertFalse(shape.commands.isEmpty, "\(shape.id) parsed to no commands")

            let path = shape.path(inSide: 100)
            XCTAssertFalse(path.isEmpty, "\(shape.id) produced an empty Path")

            let box = path.boundingRect
            XCTAssertFalse(box.isNull, "\(shape.id) has null bounds")
            XCTAssertTrue(box.origin.x.isFinite && box.origin.y.isFinite, "\(shape.id) x/y not finite")
            XCTAssertTrue(box.width.isFinite && box.height.isFinite, "\(shape.id) size not finite")
            XCTAssertGreaterThan(box.width, 10, "\(shape.id) is a sliver")
            XCTAssertGreaterThan(box.height, 10, "\(shape.id) is a sliver")
        }
    }

    func testEveryShapeFitsTheViewBox() {
        let viewBox = BotAvatarGeometry.shipped.viewBox
        for shape in BotAvatarShape.shipped {
            guard let bounds = shape.bounds else { return XCTFail("\(shape.id) has no bounds") }
            XCTAssertGreaterThanOrEqual(bounds.minX, viewBox.minX - 1, "\(shape.id) runs off the left")
            XCTAssertLessThanOrEqual(bounds.maxX, viewBox.maxX + 1, "\(shape.id) runs off the right")
            XCTAssertGreaterThanOrEqual(bounds.minY, viewBox.minY - 1, "\(shape.id) runs off the top")
            XCTAssertLessThanOrEqual(bounds.maxY, viewBox.maxY + 1, "\(shape.id) runs off the bottom")
        }
    }

    func testThePathIsScaledIntoTheBoxRatherThanShifted() {
        // The view box starts at -15, so the ink starts inset by 15/259 of the side, not at 0.
        let geometry = BotAvatarGeometry.shipped
        let origin = geometry.point(BotAvatarPoint(0, 0), inSide: 100)
        XCTAssertEqual(origin.x, 15.0 / 259.0 * 100, accuracy: 1e-9)
        XCTAssertEqual(origin.y, 15.0 / 259.0 * 100, accuracy: 1e-9)
        // And the far corner of the 259-unit box lands on the far corner of the canvas.
        let corner = geometry.point(BotAvatarPoint(244, 244), inSide: 100)
        XCTAssertEqual(corner.x, 100, accuracy: 1e-9)
        XCTAssertEqual(corner.y, 100, accuracy: 1e-9)

        // The drawn path agrees: a 228.49-unit-wide body covers most of the 100 pt square.
        let box = BotAvatarShape(kind: .tablet).path(inSide: 100).boundingRect
        XCTAssertEqual(box.minX, (0.27 + 15) / 259 * 100, accuracy: 0.01)
        XCTAssertEqual(box.width, 228.0 / 259 * 100, accuracy: 0.05)
    }

    func testTheGlyphIsCentredInAWiderFrame() {
        // A caller that hands a 200×100 frame gets a 100 pt avatar in the middle, not a stretched one.
        let box = BotAvatarShape(kind: .tablet).path(in: CGRect(x: 0, y: 0, width: 200, height: 100)).boundingRect
        XCTAssertGreaterThan(box.minX, 45)
        XCTAssertLessThan(box.maxX, 155)
        // tablet's ink is 228 × 148 units, scaled by 100/259 and never stretched.
        XCTAssertEqual(box.width, 228.0 / 259 * 100, accuracy: 0.05)
        XCTAssertEqual(box.height, 148.0 / 259 * 100, accuracy: 0.05)
        XCTAssertEqual(box.midX, 100, accuracy: 1.5)
    }

    func testTheEyesPathHasBothBars() {
        let geometry = BotAvatarGeometry.shipped
        let eyes = geometry.eyesPath(inSide: 100)
        XCTAssertFalse(eyes.isEmpty)
        let box = eyes.boundingRect
        XCTAssertTrue(box.width.isFinite && box.height.isFinite)
        // 60 units wide (two 15-unit bars 45 apart), 52 tall, scaled by 100/259.
        XCTAssertEqual(box.width, 60.0 / 259 * 100, accuracy: 0.01)
        XCTAssertEqual(box.height, 52.0 / 259 * 100, accuracy: 0.01)
    }

    func testPaletteHexBecomesASwiftUIColor() {
        let violet = BotAvatarPalette.color(id: "violet")
        XCTAssertNotNil(violet)
        // A malformed value must not turn into black: it is dropped rather than drawn wrong.
        XCTAssertNil(BotAvatarColorDef.color(fromHex: "#12"))
        XCTAssertNotNil(BotAvatarColorDef.color(fromHex: "#A97EFE"))
        XCTAssertNotNil(BotAvatarColorDef.color(fromHex: "#abc"))
    }

    func testTheViewBuildsForEveryActivityAndSize() {
        // A construction check: no activity or size may trap while the timeline is being set up.
        for activity in BotAvatarActivity.allCases {
            for size in [CGFloat(16), 24, 36, 96] {
                let view = BotAvatarView(identity: "research", activity: activity, size: size)
                XCTAssertEqual(view.size, size)
            }
        }
        let resolved = BotAvatarIdentity.resolve(identity: "research")
        XCTAssertEqual(resolved.shape.kind, .blob)
    }
}
