import XCTest
@testable import HermeyUI
import HermesKit

// What a user's choice is worth is whether it survives the trip: picker → the one string the host
// stores → a face on every surface. These are the round trips, plus the migration that keeps a
// choice made by the previous build from being silently dropped.
final class BotFaceChoiceTests: XCTestCase {

    func testAChoiceIsTheReferenceString() {
        let choice = BotFaceChoice.make(colorHex: "#A97EFE", shapeIndex: 3)
        XCTAssertEqual(choice.raw, "#A97EFE::shape_3")
        XCTAssertEqual(choice.rawValue, choice.raw)
        XCTAssertEqual(choice.colorHex, "#A97EFE")
        XCTAssertEqual(choice.shapeIndex, 3)
        XCTAssertEqual(choice.identity(for: "research").shapeIndex, 3)
        XCTAssertTrue(choice.identity(for: "research").hasExplicitShape)
    }

    func testTheIndexWrapsInsteadOfFallingOff() {
        XCTAssertEqual(BotFaceChoice.make(colorHex: "#A97EFE", shapeIndex: 8).raw, "#A97EFE::shape_0")
        XCTAssertEqual(BotFaceChoice.make(colorHex: "#A97EFE", shapeIndex: -1).raw, "#A97EFE::shape_7")
    }

    func testTheHexIsNormalised() {
        // `#abc` and `#aabbcc` are the same colour, so they are the same stored value: two strings
        // that draw identically must not look like two different choices.
        XCTAssertEqual(BotFaceChoice.make(colorHex: "#abc").raw, "#AABBCC")
        XCTAssertEqual(BotFaceChoice.make(colorHex: "aabbcc", shapeIndex: 1).raw, "#AABBCC::shape_1")
    }

    func testAColourOnlyChoiceLeavesTheBodyToTheID() {
        let choice = BotFaceChoice.make(colorHex: "#FF781C")
        XCTAssertEqual(choice.raw, "#FF781C")
        XCTAssertNil(choice.shapeIndex)
        let face = choice.identity(for: "research")
        XCTAssertEqual(face.color.hex, "#FF781C")
        XCTAssertEqual(face.shapeIndex, BotAvatarHash.shapeIndex(for: "research"))
        XCTAssertFalse(face.hasExplicitShape)
    }

    func testAPaletteNameResolvesToItsHex() {
        // The web app stores the palette id; the picker stores the hex. Both have to name one face.
        let byName = BotFaceChoice(rawValue: "violet")
        XCTAssertEqual(byName?.raw, "violet")
        XCTAssertEqual(byName?.colorHex, "#A97EFE")
        XCTAssertEqual(byName?.identity(for: "research").color.id, "violet")
    }

    func testNonsenseIsRefused() {
        XCTAssertNil(BotFaceChoice(rawValue: ""))
        XCTAssertNil(BotFaceChoice(rawValue: "   "))
        XCTAssertNil(BotFaceChoice(rawValue: "data:image/png;base64,AAAA"))
        // A word that is not in the palette would resolve to the id's face while claiming to be a
        // choice — worse than refusing it.
        XCTAssertNil(BotFaceChoice(rawValue: "chartreuse"))
    }

    // MARK: - Codable

    func testItEncodesAsOneString() throws {
        let choice = BotFaceChoice.make(colorHex: "#00C972", shapeIndex: 6)
        let data = try JSONEncoder().encode(["research": choice])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), ##"{"research":"#00C972::shape_6"}"##)
        let back = try JSONDecoder().decode([String: BotFaceChoice].self, from: data)
        XCTAssertEqual(back["research"], choice)
    }

    func testItStillDecodesTheOldPairPayload() throws {
        // What the previous build wrote on the wire: `{shape, color}`. Reading it as the equivalent
        // shipped choice is the whole migration — a failure here loses the bot's face.
        let json = Data(#"{"research":{"shape":"nova","color":"pink"}}"#.utf8)
        let decoded = try JSONDecoder().decode([String: BotFaceChoice].self, from: json)
        let choice = try XCTUnwrap(decoded["research"])
        XCTAssertEqual(choice.colorHex, "#FF5EB1", "Neon Pink carries the old pink's meaning")
        XCTAssertEqual(choice.shapeIndex, BotFaceChoice.legacyShapeOrder.firstIndex(of: "nova").map {
            BotAvatarShape.normalized(index: $0)
        })
    }

    // MARK: - Migration

    func testEveryOldShapeAndColourMigrates() {
        for (index, shape) in BotFaceChoice.legacyShapeOrder.enumerated() {
            for color in BotFaceChoice.legacyColors.keys {
                guard let choice = BotFaceChoice.migrated(legacyShape: shape, legacyColor: color) else {
                    XCTFail("\(shape)/\(color) has no migration")
                    continue
                }
                XCTAssertEqual(choice.shapeIndex, index % BotAvatarStoredValue.shapeCount,
                               "\(shape) lands on a shipped body")
                XCTAssertNotNil(BotAvatarPalette.match(choice.colorHex ?? ""),
                                "\(color) lands on a palette colour")
            }
        }
    }

    func testAnIconOnlyRowMigratesToTheColourItWasDrawnIn() {
        let choice = BotFaceChoice.migrated(legacyIcon: "beacon")
        XCTAssertEqual(choice?.colorHex, "#FFAF38")
        XCTAssertEqual(choice?.shapeIndex, BotFaceChoice.legacyShapeOrder.firstIndex(of: "beacon").map {
            BotAvatarShape.normalized(index: $0)
        })
    }

    func testTheCachedPairMigrates() {
        let choice = BotFaceChoice.migrated(legacyToken: "ember|orange")
        XCTAssertEqual(choice?.colorHex, "#FF781C")
        XCTAssertNotNil(choice?.shapeIndex)
        XCTAssertNil(BotFaceChoice.migrated(legacyToken: "ember"))
    }

    func testAnUnknownOldShapeKeepsTheColour() {
        // A silhouette this build has never heard of still leaves the user their colour rather than
        // nothing at all.
        let choice = BotFaceChoice.migrated(legacyShape: "not-a-shape", legacyColor: "ruby")
        XCTAssertEqual(choice?.colorHex, "#FF3E51")
        XCTAssertNil(choice?.shapeIndex)
    }

    func testNoColourIsNoChoice() {
        XCTAssertNil(BotFaceChoice.migrated(legacyShape: "ember", legacyColor: nil))
    }
}
