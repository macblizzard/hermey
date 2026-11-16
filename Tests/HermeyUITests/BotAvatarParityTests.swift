import XCTest
@testable import HermeyUI
import HermesKit

// Parity tests for the ported bot-avatar module. Nothing here needs SwiftUI: the geometry, the
// palette, the hash, the activity rules and the motion curves are plain numbers, so this half of
// the suite can run anywhere the toolchain does.
//
// The expected values are not invented. They were computed by running the reference's own
// TypeScript (`shippedHash`, `shippedRandom`, `resolvePersonaColorDef` from
// `packages/core/src/bot-avatar-colors.ts`, and `avatarIdentitySeed` from `avatar-shape.ts`) under
// Node, then pasted here. That run's table:
//
//   identity        hash        seed        draw 0              colour  hex      shape
//   research        1658572492  350895717   0.400121087208390   cyan    #1CC3B0  5 blob
//   nightly-build    704378051  524064326   0.781934395432472   red     #FF3E51  6 teardrop
//   ops-bot         3901881355  1252198356  0.426259827567264   cyan    #1CC3B0  4 pebble
//   Hermes           229322211  2136888634  0.295127885648981   orange  #FF781C  2 squircle
//   c0demo0001       548618470  2017030033  0.242986184544861   green   #00C972  1 wedge
//   🦀-bot          2452827075  838774396   0.742383737582713   red     #FF3E51  4 pebble
//   preview         1257924439  318184504   0.622504899045452   yellow  #FFAF38  0 hex
//   agent           1340600742  92750597    0.140268271556124   violet  #A97EFE  5 blob
//
// `hash` is shippedHash (FNV-1a over UTF-16 code units) and `seed` is avatarIdentitySeed (djb2 over
// the same units); the colour comes from the first, the shape from the second.
//
// 🦀 is deliberate: it is a surrogate pair, and it proves the hash walks UTF-16 code units the way
// `charCodeAt` does rather than UTF-8 bytes, which would give that bot a different colour here.

final class BotAvatarShapeParityTests: XCTestCase {

    func testShippedOrderAndPathLengthsAreTheReferenceOnes() {
        // SHIPPED_BOT_AVATAR_SHAPE_KEYS, in order, with the reference's path lengths.
        let expected: [(String, Int)] = [
            ("hex", 226), ("wedge", 121), ("squircle", 4811), ("tablet", 189),
            ("pebble", 4925), ("blob", 572), ("teardrop", 169), ("cloud", 6139),
        ]
        XCTAssertEqual(BotAvatarShape.shipped.map(\.kind.rawValue), expected.map(\.0))
        for (shape, pair) in zip(BotAvatarShape.shipped, expected) {
            XCTAssertEqual(shape.pathData.count, pair.1, "\(pair.0) path length differs")
        }
    }

    func testEveryShippedShapeParsesWithFiniteBounds() {
        XCTAssertEqual(BotAvatarShape.shipped.count, 8)
        for shape in BotAvatarShape.shipped {
            XCTAssertFalse(shape.commands.isEmpty, "\(shape.id) parsed to no commands")
            let bounds = shape.bounds
            XCTAssertNotNil(bounds, "\(shape.id) has no bounds")
            XCTAssertTrue(bounds?.isFinite == true, "\(shape.id) has a non-finite bound")
            XCTAssertGreaterThan(bounds?.width ?? 0, 100, "\(shape.id) is a sliver")
            XCTAssertGreaterThan(bounds?.height ?? 0, 100, "\(shape.id) is a sliver")
        }
    }

    func testShapeIndexWrapsTheWayTheReferenceWrapsIt() {
        // `((trunc(index) % count) + count) % count`.
        XCTAssertEqual(BotAvatarShape.shipped(index: 0).kind, .hex)
        XCTAssertEqual(BotAvatarShape.shipped(index: 7).kind, .cloud)
        XCTAssertEqual(BotAvatarShape.shipped(index: 8).kind, .hex)
        XCTAssertEqual(BotAvatarShape.shipped(index: -1).kind, .cloud)
        XCTAssertEqual(BotAvatarShape.shipped(index: -9).kind, .cloud)
        XCTAssertEqual(BotAvatarShape.shipped(index: 99).kind, .tablet)   // 99 % 8 == 3
        XCTAssertEqual(BotAvatarShape.normalized(index: -1), 7)
        XCTAssertEqual(BotAvatarShape.normalized(index: 9), 1)
        XCTAssertEqual(BotAvatarShape.index(of: .tablet), 3)
    }

    func testParserHandlesEveryPenCommandIncludingRelativeOnes() throws {
        // M/L/H/V/C/S/Q/T/Z, absolute.
        let absolute = try BotAvatarPathParser.parse("M10 10 L20 10 H30 V20 C31 21 32 22 33 23 S34 24 35 25 Q36 26 37 27 T38 28 Z")
        XCTAssertEqual(absolute.count, 9)
        XCTAssertEqual(absolute[0], .move(to: BotAvatarPoint(10, 10)))
        XCTAssertEqual(absolute[1], .line(to: BotAvatarPoint(20, 10)))
        XCTAssertEqual(absolute[2], .line(to: BotAvatarPoint(30, 10)))
        XCTAssertEqual(absolute[3], .line(to: BotAvatarPoint(30, 20)))
        XCTAssertEqual(absolute[4], .cubic(control1: BotAvatarPoint(31, 21),
                                           control2: BotAvatarPoint(32, 22),
                                           to: BotAvatarPoint(33, 23)))
        // S reflects the C's second control point: 2·(33,23) − (32,22) = (34,24).
        XCTAssertEqual(absolute[5], .cubic(control1: BotAvatarPoint(34, 24),
                                           control2: BotAvatarPoint(34, 24),
                                           to: BotAvatarPoint(35, 25)))
        XCTAssertEqual(absolute[6], .quad(control: BotAvatarPoint(36, 26), to: BotAvatarPoint(37, 27)))
        // T reflects the Q's control point: 2·(37,27) − (36,26) = (38,28).
        XCTAssertEqual(absolute[7], .quad(control: BotAvatarPoint(38, 28), to: BotAvatarPoint(38, 28)))
        XCTAssertEqual(absolute[8], .close)

        // The same shape, relative.
        let relative = try BotAvatarPathParser.parse("m10 10 l10 0 h10 v10 q1 1 2 2 t3 3 z")
        XCTAssertEqual(relative[0], .move(to: BotAvatarPoint(10, 10)))
        XCTAssertEqual(relative[1], .line(to: BotAvatarPoint(20, 10)))
        XCTAssertEqual(relative[2], .line(to: BotAvatarPoint(30, 10)))
        XCTAssertEqual(relative[3], .line(to: BotAvatarPoint(30, 20)))
        XCTAssertEqual(relative[4], .quad(control: BotAvatarPoint(31, 21), to: BotAvatarPoint(32, 22)))
        XCTAssertEqual(relative[5], .quad(control: BotAvatarPoint(33, 23), to: BotAvatarPoint(35, 25)))
        XCTAssertEqual(relative.last, .close)

        // Implicit repeat: `M0 0 10 10` is a move then a line.
        let repeated = try BotAvatarPathParser.parse("M0 0 10 10 20 20")
        XCTAssertEqual(repeated.count, 3)
        XCTAssertEqual(repeated[1], .line(to: BotAvatarPoint(10, 10)))
        XCTAssertEqual(repeated[2], .line(to: BotAvatarPoint(20, 20)))
    }

    func testParserAcceptsTheReferencePunctuation() throws {
        // No separator between a number and the next letter, a negative sign instead of a space, and
        // an exponent are all legal; the first two appear in the shipped data.
        let commands = try BotAvatarPathParser.parse("M74.27 40.27L154.27 40.27C195.14 40.27 228.27 73.4 228.27 114.27L0.27 114.27Q-24.62 218.53 12.39 154.43Z")
        XCTAssertEqual(commands.count, 6)
        XCTAssertEqual(commands[4], .quad(control: BotAvatarPoint(-24.62, 218.53), to: BotAvatarPoint(12.39, 154.43)))
        // Commas are separators, as SVG allows and the reference's commas use them.
        XCTAssertEqual(try BotAvatarPathParser.parse("M0,0L10,10Z"), [
            .move(to: BotAvatarPoint(0, 0)), .line(to: BotAvatarPoint(10, 10)), .close,
        ])
        let exponent = try BotAvatarPathParser.parse("M1e2 2e2L1.5e2 2.5e2")
        XCTAssertEqual(exponent[1], .line(to: BotAvatarPoint(150, 250)))
    }

    func testParserRejectsWhatIsNotAPath() {
        XCTAssertThrowsError(try BotAvatarPathParser.parse(""))
        XCTAssertThrowsError(try BotAvatarPathParser.parse("L10 10Z"))          // no initial move
        XCTAssertThrowsError(try BotAvatarPathParser.parse("M0 0 X10 10"))     // unknown command
        XCTAssertThrowsError(try BotAvatarPathParser.parse("M0 0L"))           // letter, no numbers
        XCTAssertThrowsError(try BotAvatarPathParser.parse("M0 0Z 5"))         // a number with no command
    }
}

final class BotAvatarGeometryParityTests: XCTestCase {

    func testGeometryMatchesTheReferenceConstants() {
        let geometry = BotAvatarGeometry.shipped
        XCTAssertEqual(BotAvatarGeometry.viewBoxString, "-15 -15 259 259")
        XCTAssertEqual(BotAvatarGeometry.centreValue, 114.2705)
        XCTAssertEqual(geometry.viewBox, BotAvatarRect(x: -15, y: -15, width: 259, height: 259))
        XCTAssertEqual(geometry.centre, BotAvatarPoint(114.2705, 114.2705))

        XCTAssertEqual(geometry.eyes.width, 15)
        XCTAssertEqual(geometry.eyes.height, 52)
        XCTAssertEqual(geometry.eyes.leftCx, 114.2705 - 22.5, accuracy: 1e-9)
        XCTAssertEqual(geometry.eyes.rightCx, 114.2705 + 22.5, accuracy: 1e-9)
        XCTAssertEqual(geometry.eyes.cy, 114.2705 - 8, accuracy: 1e-9)
        // 91.7705, 136.7705 and 106.2705, as the reference computes them.
        XCTAssertEqual(geometry.eyes.leftCx, 91.7705, accuracy: 1e-9)
        XCTAssertEqual(geometry.eyes.rightCx, 136.7705, accuracy: 1e-9)
        XCTAssertEqual(geometry.eyes.cy, 106.2705, accuracy: 1e-9)
    }

    func testEyeBarsAreTheReferenceRects() {
        let bars = BotAvatarGeometry.shipped.eyes.bars
        XCTAssertEqual(bars.count, 2)
        XCTAssertEqual(bars[0].x, 84.2705, accuracy: 1e-9)
        XCTAssertEqual(bars[1].x, 129.2705, accuracy: 1e-9)
        for bar in bars {
            XCTAssertEqual(bar.y, 80.2705, accuracy: 1e-9)
            XCTAssertEqual(bar.width, 15)
            XCTAssertEqual(bar.height, 52)
            // Fully rounded ends: half the width.
            XCTAssertEqual(bar.cornerRadius, 7.5)
        }
        // One face for every shape: the eyes are not the shape's.
        XCTAssertEqual(BotAvatarGeometry.shipped.eyes.bounds.width, 60, accuracy: 1e-9)
        XCTAssertEqual(BotAvatarGeometry.shipped.eyes.bounds.height, 52, accuracy: 1e-9)
    }

    func testUnitsPerPointIsTheViewBoxRatio() {
        let geometry = BotAvatarGeometry.shipped
        XCTAssertEqual(geometry.scale(forSide: 259), 1, accuracy: 1e-12)
        XCTAssertEqual(geometry.scale(forSide: 51.8), 0.2, accuracy: 1e-12)
        let bar = geometry.bar(geometry.eyes.bars[0], inSide: 51.8)
        XCTAssertEqual(bar.width, 3, accuracy: 1e-9)
        XCTAssertEqual(bar.height, 10.4, accuracy: 1e-9)
        XCTAssertEqual(bar.cornerRadius, 1.5, accuracy: 1e-9)
        XCTAssertEqual(bar.x, (84.2705 + 15) * 0.2, accuracy: 1e-9)
        XCTAssertEqual(bar.y, (80.2705 + 15) * 0.2, accuracy: 1e-9)
    }
}

final class BotAvatarPaletteParityTests: XCTestCase {

    func testPaletteIsTheReferenceListInTheReferenceOrder() {
        let expected: [(String, String, String)] = [
            ("white", "Staff White", "#FFFFFF"),
            ("violet", "Executive Violet", "#A97EFE"),
            ("green", "Emerald", "#00C972"),
            ("orange", "Forge Orange", "#FF781C"),
            ("cyan", "Cyber Cyan", "#1CC3B0"),
            ("blue", "Cobalt Blue", "#2A92FE"),
            ("yellow", "Amber Gold", "#FFAF38"),
            ("brown", "Caramel Bronze", "#A27952"),
            ("red", "Crimson Red", "#FF3E51"),
            ("magenta", "Neon Pink", "#FF5EB1"),
            ("gray", "Slate Silver", "#94A3B8"),
        ]
        XCTAssertEqual(BotAvatarPalette.colors.count, 11) // the order picks the index
        for (index, entry) in expected.enumerated() {
            let color = BotAvatarPalette.colors[index]
            XCTAssertEqual(color.id, entry.0)
            XCTAssertEqual(color.name, entry.1)
            XCTAssertEqual(color.hex, entry.2)
        }
        // The deeper values existing bots were saved with.
        XCTAssertEqual(BotAvatarPalette.color(id: "violet")?.previousHex, "#8B5CF6")
        XCTAssertEqual(BotAvatarPalette.color(id: "gray")?.previousHex, "#64748B")
        XCTAssertNil(BotAvatarPalette.color(id: "white")?.previousHex)
        XCTAssertEqual(BotAvatarPalette.defaultColor.hex, "#A97EFE")
        XCTAssertEqual(BotAvatarPalette.inviteColors.map(\.hex),
                       ["#A97EFE", "#00C972", "#FF781C", "#1CC3B0", "#2A92FE"])
    }

    func testHexMatchingIsCaseInsensitiveAndIncludesTheOlderValue() {
        XCTAssertEqual(BotAvatarPalette.match("#a97efe")?.id, "violet")
        XCTAssertEqual(BotAvatarPalette.match("#8b5cf6")?.id, "violet")   // previousHex
        XCTAssertEqual(BotAvatarPalette.match("executive violet")?.id, "violet")
        XCTAssertEqual(BotAvatarPalette.match("EMERALD")?.id, "green")
        XCTAssertNil(BotAvatarPalette.match("#123456"))
        XCTAssertTrue(BotAvatarPalette.isHexColor("#abc"))
        XCTAssertTrue(BotAvatarPalette.isHexColor("#AABBCC"))
        XCTAssertFalse(BotAvatarPalette.isHexColor("#abcd"))
        XCTAssertFalse(BotAvatarPalette.isHexColor("abc"))
        XCTAssertFalse(BotAvatarPalette.isHexColor("#GGGGGG"))
        XCTAssertEqual(BotAvatarPalette.expandedHex("#abc"), "aabbcc")
        XCTAssertEqual(BotAvatarPalette.expandedHex("A97EFE"), "A97EFE")
    }

    func testEyeToneMatchesTheReferenceCases() {
        // Straight from bot-avatar-colors.test.ts.
        XCTAssertEqual(BotAvatarPalette.eyeTone(forBody: "#FF5EB1"), .page)
        XCTAssertEqual(BotAvatarPalette.eyeTone(forBody: "#FFAF38"), .dark)
        XCTAssertEqual(BotAvatarPalette.eyeTone(forBody: "#FFFFFF"), .dark)
        XCTAssertEqual(BotAvatarPalette.eyeTone(forBody: "#111111"), .light)
        // And the rest of the palette, so a new colour cannot quietly join the wrong side.
        XCTAssertEqual(BotAvatarPalette.eyeTone(forBody: "#00C972"), .dark)   // emerald is pale
        XCTAssertEqual(BotAvatarPalette.eyeTone(forBody: "#1CC3B0"), .dark)   // so is cyan
        XCTAssertEqual(BotAvatarPalette.eyeTone(forBody: "#A97EFE"), .page)
        XCTAssertEqual(BotAvatarPalette.eyeTone(forBody: "#2A92FE"), .page)
        XCTAssertEqual(BotAvatarPalette.eyeTone(forBody: "#FF781C"), .page)
        XCTAssertEqual(BotAvatarPalette.eyeTone(forBody: "#000000"), .light)
    }

    func testContrastAndInkMatchTheReferenceCases() {
        // contrastRatio(#FFAF38, #FFFFFF) = 1.8355 in the reference.
        XCTAssertEqual(BotAvatarPalette.contrastRatio("#FFAF38", "#FFFFFF"), 1.8355, accuracy: 0.0005)
        XCTAssertEqual(BotAvatarPalette.contrastRatio("#FFFFFF", "#FFFFFF"), 1, accuracy: 1e-9)
        XCTAssertEqual(BotAvatarPalette.contrastRatio("#000000", "#FFFFFF"), 21, accuracy: 1e-6)

        let dark = (background: "#121212", foreground: "#F5F5F5")
        let light = (background: "#FFFFFF", foreground: "#1C1C1C")
        XCTAssertEqual(BotAvatarPalette.eyeInk(forBody: "#FF5EB1", pageBackground: dark.background, pageForeground: dark.foreground), "#121212")
        XCTAssertEqual(BotAvatarPalette.eyeInk(forBody: "#FF5EB1", pageBackground: light.background, pageForeground: light.foreground), "#FFFFFF")
        XCTAssertEqual(BotAvatarPalette.eyeInk(forBody: "#FFFFFF", pageBackground: light.background, pageForeground: light.foreground), "#1C1C1C")
    }
}

final class BotAvatarIdentityParityTests: XCTestCase {

    func testHashAndDrawStreamMatchTheReference() {
        // The FNV-1a seed and the first four draws of `shippedRandom(shippedHash(identity))`.
        let cases: [(String, UInt32, [Double])] = [
            ("research", 1658572492, [0.400121087208390, 0.373083626851439, 0.976874544983730, 0.528965263860300]),
            ("nightly-build", 704378051, [0.781934395432472, 0.104265909409150, 0.306777169927955, 0.247818960342556]),
            ("ops-bot", 3901881355, [0.426259827567264, 0.823128976626322, 0.901497171260417, 0.045012035174295]),
            ("Hermes", 229322211, [0.295127885648981, 0.606347029795870, 0.413941010832787, 0.001192835159600]),
            ("c0demo0001", 548618470, [0.242986184544861, 0.404913516482338, 0.975006866268814, 0.596181039465591]),
            ("🦀-bot", 2452827075, [0.742383737582713, 0.380737409228459, 0.416812097653747, 0.518642612267286]),
        ]
        for (identity, hash, draws) in cases {
            XCTAssertEqual(BotAvatarHash.shippedHash(identity), hash, "hash differs for \(identity)")
            var random = BotAvatarRandom(seed: hash)
            for (index, expected) in draws.enumerated() {
                XCTAssertEqual(random.next(), expected, accuracy: 1e-15, "draw \(index) differs for \(identity)")
            }
        }
        // The stream is a function of its seed, not of the process.
        var a = BotAvatarRandom(seed: 42)
        var b = BotAvatarRandom(seed: 42)
        for _ in 0..<8 { XCTAssertEqual(a.next(), b.next()) }
    }

    func testResolvedFacesMatchTheReferenceSamples() {
        let expected: [(String, String, String, Int, BotAvatarShape.Kind)] = [
            ("research", "cyan", "#1CC3B0", 5, .blob),
            ("nightly-build", "red", "#FF3E51", 6, .teardrop),
            ("ops-bot", "cyan", "#1CC3B0", 4, .pebble),
            ("Hermes", "orange", "#FF781C", 2, .squircle),
            ("c0demo0001", "green", "#00C972", 1, .wedge),
            ("🦀-bot", "red", "#FF3E51", 4, .pebble),
        ]
        XCTAssertGreaterThanOrEqual(expected.count, 6)
        for (identity, id, hex, index, kind) in expected {
            let resolved = BotAvatarIdentity.resolve(identity: identity)
            XCTAssertEqual(resolved.color.id, id, "colour differs for \(identity)")
            XCTAssertEqual(resolved.color.hex, hex)
            XCTAssertEqual(resolved.shapeIndex, index)
            XCTAssertEqual(resolved.shape.kind, kind)
            XCTAssertFalse(resolved.hasExplicitShape)
            XCTAssertFalse(resolved.isImage)
        }
    }

    func testExplicitColoursWinAndFallThroughLikeTheReference() {
        // A palette hex, including the deeper value bots were saved with.
        XCTAssertEqual(BotAvatarIdentity.resolve(identity: "carrier-id", explicitColor: "#8B5CF6").color.hex, "#A97EFE")
        XCTAssertEqual(BotAvatarIdentity.resolve(identity: "carrier-id", explicitColor: "#A97EFE").color.id, "violet")
        // A display name.
        XCTAssertEqual(BotAvatarIdentity.resolve(identity: "carrier-id", explicitColor: "emerald").color.id, "green")
        // A custom hex is kept exactly as given.
        let custom = BotAvatarIdentity.resolve(identity: "carrier-id", explicitColor: "#abc")
        XCTAssertEqual(custom.color.id, "custom")
        XCTAssertEqual(custom.color.hex, "#abc")
        // A value that names nothing falls through to the identity hash — carrier-id is yellow.
        XCTAssertEqual(BotAvatarIdentity.resolve(identity: "carrier-id", explicitColor: "not-a-colour").color.hex, "#FFAF38")
        XCTAssertEqual(BotAvatarIdentity.resolveColor(identity: "carrier-id").hex, "#FFAF38")
        // The five explicit paths the reference resolver distinguishes, side by side.
        let table: [(String, String, String)] = [
            ("#8B5CF6", "violet", "#A97EFE"),
            ("emerald", "green", "#00C972"),
            ("#abc", "custom", "#abc"),
            ("not-a-colour", "yellow", "#FFAF38"),
        ]
        for (explicit, id, hex) in table {
            let resolved = BotAvatarIdentity.resolve(identity: "carrier-id", explicitColor: explicit)
            XCTAssertEqual(resolved.color.id, id, explicit)
            XCTAssertEqual(resolved.color.hex, hex, explicit)
        }
    }

    func testAStoredShapeOverridesTheDerivedOne() {
        let stored = BotAvatarIdentity.resolve(identity: "research", explicitColor: "#A97EFE::shape_3")
        XCTAssertEqual(stored.color.id, "violet")
        XCTAssertEqual(stored.shapeIndex, 3)
        XCTAssertEqual(stored.shape.kind, .tablet)
        XCTAssertTrue(stored.hasExplicitShape)

        let wrapped = BotAvatarIdentity.resolve(identity: "research", explicitColor: "#A97EFE::shape_11")
        XCTAssertEqual(wrapped.shapeIndex, 3) // 11 % 8

        // A shape-less value keeps the derived shape.
        let plain = BotAvatarIdentity.resolve(identity: "research", explicitColor: "#A97EFE")
        XCTAssertEqual(plain.shapeIndex, 5)
        XCTAssertFalse(plain.hasExplicitShape)
    }

    func testStoredValueParsingMirrorsTheContracts() {
        XCTAssertEqual(BotAvatarStoredValue.parse("data:image/png;base64,AAAA"), .image("data:image/png;base64,AAAA"))
        XCTAssertEqual(BotAvatarStoredValue.parse("#FF781C::shape_5"), .shape(color: "#FF781C", shapeIndex: 5))
        XCTAssertEqual(BotAvatarStoredValue.parse("#FF781C::shape_13"), .shape(color: "#FF781C", shapeIndex: 5))
        XCTAssertEqual(BotAvatarStoredValue.parse("#FF781C::shape_x"), .shape(color: "#FF781C", shapeIndex: 0))
        XCTAssertEqual(BotAvatarStoredValue.parse("::shape_2"), .shape(color: "#F97316", shapeIndex: 2))
        XCTAssertEqual(BotAvatarStoredValue.parse("#ABC"), .color("#ABC"))
        XCTAssertEqual(BotAvatarStoredValue.parse("violet"), .other("violet"))
        XCTAssertTrue(BotAvatarIdentity.resolve(identity: "x", explicitColor: "data:image/webp;base64,AA").isImage)
    }

    func testShapeIndexComesFromTheIdentitySeed() {
        // avatarIdentitySeed % 8: the reference's organic-family derivation over this port's shapes.
        XCTAssertEqual(BotAvatarHash.shapeIndex(for: "research"), 5)
        XCTAssertEqual(BotAvatarHash.shapeIndex(for: "Hermes"), 2)
        XCTAssertEqual(BotAvatarHash.shapeIndex(for: "c0demo0001"), 1)
        // djb2 over UTF-16 code units, as `avatarIdentitySeed` computes it — a different hash from
        // the FNV one above, and the one the organic family (and so the shape) is drawn from.
        XCTAssertEqual(BotAvatarHash.identitySeed(for: "research"), 350895717)
        XCTAssertEqual(BotAvatarHash.identitySeed(for: "nightly-build"), 524064326)
        XCTAssertEqual(BotAvatarHash.identitySeed(for: "Hermes"), 2136888634)
        XCTAssertEqual(BotAvatarHash.identitySeed(for: "c0demo0001"), 2017030033)
        // Stable, and independent of the process.
        XCTAssertEqual(BotAvatarHash.shapeIndex(for: "same-id"), BotAvatarHash.shapeIndex(for: "same-id"))
        // An id-less preview still gets a shipped shape and a palette colour.
        let preview = BotAvatarIdentity.resolve(identity: "")
        XCTAssertTrue(BotAvatarShape.Kind.allCases.contains(preview.shape.kind))
        XCTAssertTrue(BotAvatarPalette.colors.contains(preview.color))
    }
}

final class BotAvatarActivityParityTests: XCTestCase {

    func testToolSetsAreExactlyTheReferences() {
        XCTAssertEqual(BotAvatarActivity.readingTools, ["read_file", "web_fetch", "read_history", "skill_read"])
        XCTAssertEqual(BotAvatarActivity.writingTools, ["write_file"])
        XCTAssertEqual(BotAvatarActivity.computerTools, [
            "computer_observe", "computer_act", "browser_navigate", "browser_snapshot", "browser_act",
            "user_computer_shell", "user_computer_observe", "user_computer_act", "shell", "open_path", "launch_app",
        ])
        XCTAssertEqual(BotAvatarActivity.workingStatuses, ["queued", "leased", "running"])
        XCTAssertEqual(BotAvatarActivity.waitingStatuses, ["waiting_input", "waiting_takeover"])
    }

    func testEveryToolInEachSetGetsItsActivity() {
        for tool in BotAvatarActivity.readingTools {
            XCTAssertEqual(BotAvatarActivity.from(status: "running", toolNames: [tool]), .reading, tool)
        }
        for tool in BotAvatarActivity.writingTools {
            XCTAssertEqual(BotAvatarActivity.from(status: "running", toolNames: [tool]), .writing, tool)
        }
        for tool in BotAvatarActivity.computerTools {
            XCTAssertEqual(BotAvatarActivity.from(status: "running", toolNames: [tool]), .computer, tool)
        }
    }

    func testBackgroundWorkIsIdleBeforeAnythingElse() {
        // A tickets run must not leak into the chat as activity, whatever else is true of it.
        XCTAssertEqual(BotAvatarActivity.from(status: "running", toolNames: ["read_file"], composing: true, thinking: true, background: true), .idle)
        XCTAssertEqual(BotAvatarActivity.from(status: "running", background: true), .idle)
        XCTAssertEqual(BotAvatarActivity.from(status: "failed", background: true), .idle)
    }

    func testFailedIsErrorEvenWithAToolOut() {
        XCTAssertEqual(BotAvatarActivity.from(status: "failed", toolNames: ["read_file"]), .error)
        XCTAssertEqual(BotAvatarActivity.from(status: "failed", composing: true, thinking: true), .error)
        XCTAssertFalse(BotAvatarActivity.error.isAnimated)
        XCTAssertFalse(BotAvatarActivity.error.showsWorkingRing)
    }

    func testWaitingOnTheUserWinsOverTheToolPose() {
        XCTAssertEqual(BotAvatarActivity.from(status: "waiting_input", toolNames: ["read_file"]), .waiting)
        XCTAssertEqual(BotAvatarActivity.from(status: "waiting_takeover", toolNames: ["shell"]), .waiting)
        XCTAssertTrue(BotAvatarActivity.waiting.needsAttention)
        XCTAssertTrue(BotAvatarActivity.waiting.showsWorkingRing)
    }

    func testAFinishedOrUnknownRunIsIdle() {
        for status in ["completed", "cancelled", "", "something-else"] {
            XCTAssertEqual(BotAvatarActivity.from(status: status), .idle, status)
        }
        XCTAssertEqual(BotAvatarActivity.from(status: nil), .idle)
        XCTAssertTrue(BotAvatarActivity.idle.isAnimated)   // idle does move: it floats
        XCTAssertFalse(BotAvatarActivity.idle.showsWorkingRing)
    }

    func testAWorkingRunWithNoToolFallsToComposingThenThinkingThenWorking() {
        XCTAssertEqual(BotAvatarActivity.from(status: "running"), .working)
        XCTAssertEqual(BotAvatarActivity.from(status: "queued"), .working)
        XCTAssertEqual(BotAvatarActivity.from(status: "leased"), .working)
        XCTAssertEqual(BotAvatarActivity.from(status: "running", thinking: true), .thinking)
        XCTAssertEqual(BotAvatarActivity.from(status: "running", composing: true), .writing)
        // Composing is checked before thinking.
        XCTAssertEqual(BotAvatarActivity.from(status: "running", composing: true, thinking: true), .writing)
    }

    func testAToolOutBeatsComposingAndThinking() {
        XCTAssertEqual(BotAvatarActivity.from(status: "running", toolNames: ["read_file"], composing: true, thinking: true), .reading)
        XCTAssertEqual(BotAvatarActivity.from(status: "running", toolNames: ["write_file"], composing: true, thinking: true), .writing)
    }

    func testTheLastToolCalledIsThePose() {
        // A shell command that also read a file is at the computer: the newest call is the pose, and
        // the computer set is checked before the reading one.
        XCTAssertEqual(BotAvatarActivity.from(status: "running", toolNames: ["read_file", "shell"]), .computer)
        XCTAssertEqual(BotAvatarActivity.from(status: "running", toolNames: ["shell", "read_file"]), .reading)
        XCTAssertEqual(BotAvatarActivity.from(status: "running", toolNames: ["read_file", "some_other_tool"]), .working)
    }

    func testEveryStateSpeaksAndOnlyTwoRestWithoutARing() {
        for activity in BotAvatarActivity.allCases {
            XCTAssertFalse(activity.accessibilityDescription.isEmpty, activity.rawValue)
            XCTAssertEqual(activity.showsWorkingRing, activity != .idle && activity != .error, activity.rawValue)
        }
    }
}

final class BotAvatarMotionParityTests: XCTestCase {

    func testDurationsAreTheReferenceCycles() {
        XCTAssertEqual(BotAvatarMotion.duration(of: .idle), 1.8, accuracy: 1e-9)      // rakazo-organic-float
        XCTAssertEqual(BotAvatarMotion.duration(of: .reading), 1.6, accuracy: 1e-9)   // rakazo-organic-sway
        XCTAssertEqual(BotAvatarMotion.duration(of: .writing), 1.35, accuracy: 1e-9)  // rakazo-organic-squash
        XCTAssertEqual(BotAvatarMotion.duration(of: .thinking), 1.1, accuracy: 1e-9)  // rakazo-organic-pulse
        XCTAssertEqual(BotAvatarMotion.duration(of: .computer), 2.4, accuracy: 1e-9)  // rakazo-organic-turn
        XCTAssertEqual(BotAvatarMotion.duration(of: .working), 1.35, accuracy: 1e-9)  // rakazo-organic-ring
        XCTAssertEqual(BotAvatarMotion.duration(of: .waiting), 1.6, accuracy: 1e-9)   // rakazo-avatar-breathe
        XCTAssertEqual(BotAvatarMotion.duration(of: .error), 0, accuracy: 1e-9)
        XCTAssertEqual(BotAvatarMotion.workingRingDuration, 1.2, accuracy: 1e-9)      // rakazo-avatar-spin
    }

    func testEachActivityMovesTheWayItsKeyframesDo() {
        let traits = BotAvatarMotionTraits(phase: 0, eyeLoop: 0)

        // idle: float, 2 units down then 3 up on the reference's 120-unit box.
        let idle = BotAvatarMotion.bodyPose(activity: .idle, at: 0, traits: traits)
        XCTAssertEqual(idle.translateY, 2.0 / 120.0, accuracy: 1e-12)
        XCTAssertEqual(idle.scaleX, 1.02, accuracy: 1e-12)
        XCTAssertEqual(BotAvatarMotion.bodyPose(activity: .idle, at: 0.9, traits: traits).translateY, -3.0 / 120.0, accuracy: 1e-6)

        // thinking: pulse 0.96 → 1.06 at 45%.
        XCTAssertEqual(BotAvatarMotion.bodyPose(activity: .thinking, at: 0, traits: traits).scaleX, 0.96, accuracy: 1e-12)
        XCTAssertEqual(BotAvatarMotion.bodyPose(activity: .thinking, at: 1.1 * 0.45, traits: traits).scaleX, 1.06, accuracy: 1e-6)

        // reading sways, writing squashes, the computer turns.
        XCTAssertEqual(BotAvatarMotion.bodyPose(activity: .reading, at: 0, traits: traits).rotate, -3, accuracy: 1e-12)
        XCTAssertEqual(BotAvatarMotion.bodyPose(activity: .writing, at: 0, traits: traits).scaleY, 0.96, accuracy: 1e-12)
        XCTAssertEqual(BotAvatarMotion.bodyPose(activity: .computer, at: 0, traits: traits).rotate, -4, accuracy: 1e-12)
        XCTAssertEqual(BotAvatarMotion.bodyPose(activity: .computer, at: 1.2, traits: traits).rotate, 4, accuracy: 1e-6)

        // working: the ring wiggle, -4° → 5° at 35% → -3° at 65%.
        XCTAssertEqual(BotAvatarMotion.bodyPose(activity: .working, at: 0, traits: traits).rotate, -4, accuracy: 1e-12)
        XCTAssertEqual(BotAvatarMotion.bodyPose(activity: .working, at: 1.35 * 0.35, traits: traits).rotate, 5, accuracy: 1e-6)
        XCTAssertEqual(BotAvatarMotion.bodyPose(activity: .working, at: 1.35 * 0.65, traits: traits).rotate, -3, accuracy: 1e-6)

        // waiting: breathe, 1 → 1.07 with a brightness lift at half way.
        let breathe = BotAvatarMotion.bodyPose(activity: .waiting, at: 0.8, traits: traits)
        XCTAssertEqual(breathe.scaleX, 1.07, accuracy: 1e-6)
        XCTAssertEqual(breathe.brightness, 0.12, accuracy: 1e-6)

        // error: it rests.
        for time in [0.0, 0.3, 5.0, 600.0] {
            XCTAssertEqual(BotAvatarMotion.bodyPose(activity: .error, at: time, traits: traits), .rest)
        }
    }

    func testEveryActivityReturnsToItsFirstFrameEachCycle() {
        let traits = BotAvatarMotionTraits(phase: 0, eyeLoop: 2)
        for activity in BotAvatarActivity.allCases where activity.isAnimated {
            let duration = BotAvatarMotion.duration(of: activity)
            let first = BotAvatarMotion.bodyPose(activity: activity, at: 0, traits: traits)
            let next = BotAvatarMotion.bodyPose(activity: activity, at: duration, traits: traits)
            XCTAssertEqual(first.rotate, next.rotate, accuracy: 1e-6, activity.rawValue)
            XCTAssertEqual(first.scaleX, next.scaleX, accuracy: 1e-6, activity.rawValue)
            XCTAssertEqual(first.translateY, next.translateY, accuracy: 1e-6, activity.rawValue)
            XCTAssertEqual(first.brightness, next.brightness, accuracy: 1e-6, activity.rawValue)
        }
    }

    func testReduceMotionAndSmallSizesStopTheMotion() {
        XCTAssertTrue(BotAvatarMotion.allows(activity: .working, reduceMotion: false, size: 36))
        XCTAssertFalse(BotAvatarMotion.allows(activity: .working, reduceMotion: true, size: 36))
        XCTAssertFalse(BotAvatarMotion.allows(activity: .working, reduceMotion: false, animates: false, size: 36))
        // The reference's `canMove = motion && size >= 24`.
        XCTAssertFalse(BotAvatarMotion.allows(activity: .working, reduceMotion: false, size: 23.9))
        XCTAssertTrue(BotAvatarMotion.allows(activity: .working, reduceMotion: false, size: 24))
        XCTAssertFalse(BotAvatarMotion.allows(activity: .error, reduceMotion: false, size: 96))
    }

    func testTheEasingIsTheCSSEaseInOutCurve() {
        // cubic-bezier(0.42, 0, 0.58, 1): symmetric, and slower than linear at the start.
        XCTAssertEqual(BotAvatarMotion.easeInOut(0), 0, accuracy: 1e-12)
        XCTAssertEqual(BotAvatarMotion.easeInOut(0.5), 0.5, accuracy: 1e-3)
        XCTAssertEqual(BotAvatarMotion.easeInOut(1), 1, accuracy: 1e-12)
        XCTAssertLessThan(BotAvatarMotion.easeInOut(0.25), 0.25)
        XCTAssertGreaterThan(BotAvatarMotion.easeInOut(0.75), 0.75)
        XCTAssertEqual(BotAvatarMotion.easeInOut(0.25) + BotAvatarMotion.easeInOut(0.75), 1, accuracy: 1e-3)
    }

    func testTheFourEyeLoopsAreTheReferencePrograms() {
        // Durations and starting phases: 6.6s; 7.2s −1.4s; 6.1s −3.2s; 7.8s −2.1s.
        let loops = BotAvatarMotion.eyeLoops
        XCTAssertEqual(loops.count, 4)
        XCTAssertEqual(loops[0].duration, 6.6, accuracy: 1e-9)
        XCTAssertEqual(loops[1].duration, 7.2, accuracy: 1e-9)
        XCTAssertEqual(loops[2].duration, 6.1, accuracy: 1e-9)
        XCTAssertEqual(loops[3].duration, 7.8, accuracy: 1e-9)
        XCTAssertEqual(loops[1].phase, 1.4 / 7.2, accuracy: 1e-12)
        XCTAssertEqual(loops[2].phase, 3.2 / 6.1, accuracy: 1e-12)
        XCTAssertEqual(loops[3].phase, 2.1 / 7.8, accuracy: 1e-12)

        // Loop 0 opens with the gaze pushed left and slightly low.
        let start = BotAvatarMotion.eyePose(loop: 0, at: 0)
        XCTAssertEqual(start.offsetX, -0.09, accuracy: 1e-12)
        XCTAssertEqual(start.offsetY, 0.01, accuracy: 1e-12)
        XCTAssertEqual(start.scaleY, 0.94, accuracy: 1e-12)

        // Out-of-range loops wrap rather than crash.
        XCTAssertEqual(BotAvatarMotion.eyePose(loop: -1, at: 0), BotAvatarMotion.eyePose(loop: 3, at: 0))
        XCTAssertEqual(BotAvatarMotion.eyePose(loop: 4, at: 0), BotAvatarMotion.eyePose(loop: 0, at: 0))
    }

    func testIdentityTraitsAreStableAndInRange() {
        let traits = BotAvatarMotionTraits(identity: "research")
        XCTAssertEqual(traits.phase, 0.385531, accuracy: 1e-6) // fourth draw of logo-avatar/v2/research
        XCTAssertEqual(traits.eyeLoop, 1)                      // identitySeed % 4
        XCTAssertEqual(traits, BotAvatarMotionTraits(identity: "research"))
        for index in 0..<40 {
            let phase = BotAvatarMotionTraits(identity: "bot-\(index)").phase
            XCTAssertGreaterThanOrEqual(phase, 0)
            XCTAssertLessThan(phase, 1)
        }
    }
}
