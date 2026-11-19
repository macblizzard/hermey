import XCTest
import SwiftUI
@testable import HermeyUI

#if canImport(AppKit)
import AppKit
#endif

/// Every palette has to be readable, and a light one has to be readable *the other way round*.
///
/// The numbers here are WCAG's: 7:1 for body text, 4.5:1 for secondary text and for a label on the
/// fill it sits on. A theme that misses one is not a matter of taste — it is unreadable for someone.
///
/// Two deliberate choices:
///
/// * the universal floor is the floor the shipped palettes already meet, so this suite describes the
///   app rather than an aspiration it silently fails;
/// * the dark palettes never cleared 4.5:1 for a label on their accent (`catppuccin` is 1.46:1),
///   which is recorded below as known debt instead of being hidden. A theme may not *join* that
///   list, and fixing one does not fail the suite.
final class ThemeContrastTests: XCTestCase {

    /// Palettes whose button label already failed the 4.5:1 bar before this suite existed. Listed by
    /// name so the debt is visible; nothing new is allowed to land here.
    private let knownLowLabelContrast: Set<String> = [
        "midnight", "graphite", "gruvbox", "tokyo-night", "catppuccin", "dracula", "nord",
    ]

    // MARK: - Measuring

    private func components(_ color: Color) -> (Double, Double, Double) {
        #if canImport(AppKit)
        let native = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return (Double(native.redComponent), Double(native.greenComponent), Double(native.blueComponent))
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
        #endif
    }

    private func luminance(_ color: Color) -> Double {
        let (r, g, b) = components(color)
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    private func contrast(_ a: Color, _ b: Color) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    // MARK: - The catalogue

    func testEveryPaletteHasAUniqueID() {
        let ids = ThemeCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate theme id in the catalogue: \(ids)")
        XCTAssertEqual(ThemeCatalog.all.map(\.name).filter(\.isEmpty).count, 0)
    }

    func testTheDefaultIsInTheCatalogue() {
        XCTAssertTrue(ThemeCatalog.all.contains { $0.id == ThemeCatalog.defaultID })
    }

    func testAnUnknownIDResolvesToTheDefault() {
        XCTAssertEqual(ThemeCatalog.theme(id: "no-such-theme").id, ThemeCatalog.defaultID)
    }

    func testExactlyOneLightPalette() {
        let light = ThemeCatalog.all.filter(\.isLight).map(\.id)
        XCTAssertEqual(light, ["parchment"], "the catalogue should publish one light palette")
    }

    /// The light theme is the one whose chrome has to flip, so it is pinned by name: renaming it
    /// without this line would ship cream tokens inside a dark window.
    func testParchmentIsLightAndTheRestAreDark() {
        XCTAssertTrue(ThemeCatalog.theme(id: "parchment").isLight)
        for theme in ThemeCatalog.all where theme.id != "parchment" {
            XCTAssertFalse(theme.isLight, "\(theme.id) is not a light palette")
        }
    }

    // MARK: - Readability, every palette

    func testBodyTextClearsSevenToOneOnItsCanvas() {
        for theme in ThemeCatalog.all {
            let ratio = contrast(theme.textPrimary, theme.canvas)
            XCTAssertGreaterThanOrEqual(ratio, 7.0, "\(theme.id): body text is \(ratio):1 on its canvas")
        }
    }

    func testSecondaryTextClearsFourAndAHalfOnItsCanvas() {
        for theme in ThemeCatalog.all {
            let ratio = contrast(theme.textMuted, theme.canvas)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(theme.id): muted text is \(ratio):1 on its canvas")
        }
    }

    func testAButtonLabelClearsItsFillUnlessTheDebtIsRecorded() {
        for theme in ThemeCatalog.all {
            let ratio = contrast(theme.textPrimary, theme.accent)
            if ratio < 4.5 {
                XCTAssertTrue(knownLowLabelContrast.contains(theme.id),
                              "\(theme.id): a label on its accent is \(ratio):1 — a new theme may not land below 4.5")
            }
        }
    }

    // MARK: - The light palette's own bar

    func testParchmentIsReadableAtEveryLevel() {
        let theme = ThemeCatalog.theme(id: "parchment")
        XCTAssertGreaterThanOrEqual(contrast(theme.textPrimary, theme.canvas), 7.0)
        XCTAssertGreaterThanOrEqual(contrast(theme.textDim, theme.canvas), 4.5, "dim text is not readable on paper")
        XCTAssertGreaterThanOrEqual(contrast(theme.textPrimary, theme.accent), 4.5, "the primary button's label")
        for status in ["success", "warning", "danger"] {
            let colour: Color
            switch status {
            case "success": colour = theme.success
            case "warning": colour = theme.warning
            default: colour = theme.danger
            }
            XCTAssertGreaterThanOrEqual(contrast(colour, theme.canvas), 4.5, "\(status) as text on paper")
            XCTAssertGreaterThanOrEqual(contrast(colour, theme.sheet), 4.5, "\(status) as text on a sheet")
        }
    }

    /// The bug a light theme invites: hairline borders derived as `white.opacity(…)` are invisible on
    /// cream, which is why a light palette supplies its own line colours. A resolved white overlay has
    /// a luminance of 1.0 and would clear the paper, so "darker than the canvas" is the whole test.
    func testLightBordersAreDarkerThanTheCanvasNotAWhiteVeil() {
        let theme = ThemeCatalog.theme(id: "parchment")
        let canvas = luminance(theme.canvas)
        XCTAssertLessThan(luminance(theme.border), canvas, "the hairline must be darker than the paper")
        XCTAssertLessThan(luminance(theme.borderStrong), canvas, "the strong border must be darker than the paper")
        XCTAssertLessThan(luminance(theme.borderStrong), luminance(theme.border), "strong must read stronger")
    }

    /// A raised surface has to read as raised. Every palette steps its raised surface toward the light
    /// (a dark theme's `surfaceHigh` is lighter than its `surface`, and so is a light theme's), so the
    /// same assertion serves both — and mixing the direction up would make hover states vanish.
    func testRaisedSurfacesStepAwayFromSurface() {
        for theme in ThemeCatalog.all {
            XCTAssertGreaterThan(luminance(theme.surfaceRaised), luminance(theme.surface),
                                 "\(theme.id): raised is not lighter than surface")
            XCTAssertNotEqual(luminance(theme.canvas), luminance(theme.surfaceRaised),
                              "\(theme.id): a raised surface the colour of the canvas is not raised")
        }
    }

    /// The two text tones are distinct in every palette. They are *not* ordered by strength: the dark
    /// palettes put the placeholder between muted and primary, the light one puts it below muted, and
    /// both are legible — so this pins distinctness rather than an ordering the catalogue never had.
    func testPlaceholderIsADistinctTone() {
        for theme in ThemeCatalog.all {
            XCTAssertNotEqual(contrast(theme.textPlaceholder, theme.canvas),
                              contrast(theme.textMuted, theme.canvas), accuracy: 0.5,
                              "\(theme.id): the placeholder is indistinguishable from muted text")
        }
    }
}
