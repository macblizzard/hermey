import XCTest
@testable import HermesKit

/// Where a pet may sit: the stored string and the arithmetic that keeps it on a display.
///
/// These are the pure half of `PetSettings`/`DesktopPetController` — the half that can be proven
/// without a window server. A positioning bug is otherwise only visible on somebody's second
/// monitor, after the display has been unplugged.
final class PetPlacementTests: XCTestCase {

    // MARK: - Stored form

    func testStoredStringRoundTrips() {
        let placement = PetPlacement(x: 120, y: 340, screenID: "69733408")
        XCTAssertEqual(placement.encoded, "120,340,69733408")
        XCTAssertEqual(PetPlacement.decode(placement.encoded), placement)
    }

    func testStoredStringHasNoFractions() {
        // A window origin with a fraction in it drifts a pixel per drag.
        XCTAssertEqual(PetPlacement(x: 10.6, y: 20.4, screenID: "1").encoded, "11,20,1")
    }

    func testNegativeOriginsSurviveTheRoundTrip() {
        // A display to the left of the main one has a negative x.
        let placement = PetPlacement(x: -1440, y: -80, screenID: "2")
        XCTAssertEqual(PetPlacement.decode(placement.encoded), placement)
    }

    func testTheScreenIDKeepsItsOwnCommas() {
        let placement = PetPlacement.decode("10,20,Screen, Left")
        XCTAssertEqual(placement?.x, 10)
        XCTAssertEqual(placement?.y, 20)
        XCTAssertEqual(placement?.screenID, "Screen, Left")
    }

    func testMalformedValuesAreRefusedRatherThanGuessed() {
        for raw in ["", "10,20", "10,20,", "a,20,1", "10,b,1", ",20,1"] {
            XCTAssertNil(PetPlacement.decode(raw), "\(raw) must not decode")
        }
        // The split is bounded, so a screen id may carry commas of its own.
        XCTAssertEqual(PetPlacement.decode("10,20,1,extra")?.screenID, "1,extra")
    }

    // MARK: - Clamping

    private let display = PetRect(x: 0, y: 25, width: 1440, height: 850)

    func testAnIconDraggedOffTheEdgeIsPulledBackOn() {
        let clamped = PetGeometry.clamp(PetPlacement(x: -400, y: 5000, screenID: "1"),
                                        side: 96, to: display)
        XCTAssertEqual(clamped.x, display.minX)
        XCTAssertEqual(clamped.y, display.maxY - 96)
        XCTAssertEqual(clamped.screenID, "1")
    }

    func testAnIconAlreadyInsideIsLeftAlone() {
        let placement = PetPlacement(x: 300, y: 300, screenID: "1")
        XCTAssertEqual(PetGeometry.clamp(placement, side: 96, to: display), placement)
    }

    func testTheIconIsFullyInsideTheFrameNotJustTouchingIt() {
        let clamped = PetGeometry.clamp(PetPlacement(x: 1400, y: 800, screenID: "1"),
                                        side: 96, to: display)
        XCTAssertEqual(clamped.x + 96, display.maxX)
        XCTAssertEqual(clamped.y + 96, display.maxY)
    }

    func testADisplaySmallerThanTheIconStillGivesAnOrigin() {
        let tiny = PetRect(x: 10, y: 10, width: 40, height: 40)
        let clamped = PetGeometry.clamp(PetPlacement(x: 500, y: 500, screenID: "1"),
                                        side: 96, to: tiny)
        XCTAssertEqual(clamped.x, 10)
        XCTAssertEqual(clamped.y, 10)
    }

    func testANewPetIsCentredAndOnScreen() {
        let centred = PetGeometry.centre(in: display, screenID: "7", side: 96)
        XCTAssertEqual(centred.x, display.minX + (display.width - 96) / 2)
        XCTAssertEqual(centred.y, display.minY + (display.height - 96) / 2)
        XCTAssertEqual(centred.screenID, "7")
        XCTAssertEqual(PetGeometry.clamp(centred, side: 96, to: display), centred)
    }

    func testTheWindowIsTheIconPlusAClearRingForTheMotion() {
        XCTAssertEqual(PetGeometry.windowSide(icon: PetGeometry.iconSide),
                       PetGeometry.iconSide + 2 * PetGeometry.motionMargin)
        XCTAssertEqual(PetGeometry.windowSide(icon: 96), 120)
        XCTAssertGreaterThan(PetGeometry.motionMargin, 9,
                             "a hop travels nine points; the ring has to be at least that wide")
    }

    // MARK: - The balloon

    func testTheBalloonSitsAboveItsPet() {
        let pet = PetPlacement(x: 400, y: 200, screenID: "1")
        let balloon = PetRect(x: 0, y: 0, width: 320, height: 140)
        let placed = PetGeometry.above(pet, side: 96, balloon: balloon, in: display)
        XCTAssertEqual(placed.y, 200 + 96 + 8)
        XCTAssertEqual(placed.x, 400 + (96 - 320) / 2)
        XCTAssertEqual(placed.width, 320)
        XCTAssertEqual(placed.height, 140)
    }

    func testTheBalloonFlipsBelowWhenThereIsNoRoomAbove() {
        let pet = PetPlacement(x: 400, y: display.maxY - 96, screenID: "1")
        let balloon = PetRect(x: 0, y: 0, width: 320, height: 140)
        let placed = PetGeometry.above(pet, side: 96, balloon: balloon, in: display)
        XCTAssertEqual(placed.maxY, pet.y - 8)
    }

    func testTheBalloonNeverHangsOffTheSideOfTheScreen() {
        let pet = PetPlacement(x: display.maxX - 96, y: 200, screenID: "1")
        let balloon = PetRect(x: 0, y: 0, width: 320, height: 140)
        let placed = PetGeometry.above(pet, side: 96, balloon: balloon, in: display)
        XCTAssertEqual(placed.maxX, display.maxX)

        let leftEdge = PetGeometry.above(PetPlacement(x: display.minX, y: 200, screenID: "1"),
                                         side: 96, balloon: balloon, in: display)
        XCTAssertEqual(leftEdge.x, display.minX)
    }
}
