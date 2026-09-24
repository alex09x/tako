import CoreText
import XCTest
@testable import TakoCoreUI

final class TerminalFontResolutionTests: XCTestCase {
    private let fontSize: CGFloat = 13

    func testSystemFamilyAndPostScriptNamesResolveTheSameRegularFaceWithCyrillic() {
        let regular = CTFontCreateWithName("Menlo-Regular" as CFString, fontSize, nil)
        let postScriptName = CTFontCopyPostScriptName(regular) as String
        let familyName = CTFontCopyFamilyName(regular) as String

        assertIdentityAndCyrillic(
            TerminalRenderer.Metrics(fontSize: fontSize, fontName: familyName).font,
            matches: regular
        )
        assertIdentityAndCyrillic(
            TerminalRenderer.Metrics(fontSize: fontSize, fontName: familyName + "-Regular").font,
            matches: regular
        )
        assertIdentityAndCyrillic(
            TerminalRenderer.Metrics(fontSize: fontSize, fontName: postScriptName).font,
            matches: regular
        )
    }

    func testSystemFullNameAliasResolvesTheSameRegularFace() {
        let regular = CTFontCreateWithName("Menlo-Regular" as CFString, fontSize, nil)
        let fullName = CTFontCopyFullName(regular) as String

        assertIdentityAndCyrillic(
            TerminalRenderer.Metrics(fontSize: fontSize, fontName: fullName).font,
            matches: regular
        )
    }

    func testUnknownNameFallsBackToMenlo() {
        let fallback = CTFontCreateWithName("Menlo-Regular" as CFString, fontSize, nil)
        let metrics = TerminalRenderer.Metrics(
            fontSize: fontSize,
            fontName: "TakoDefinitelyNotARegisteredFont"
        )

        assertIdentityAndCyrillic(metrics.font, matches: fallback)
    }

    func testBundledJetBrainsFamilyAndPostScriptNamesWhenAssetIsAvailable() throws {
        let asset = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/fonts/JetBrainsMonoNerdFont-Regular.ttf")
        guard FileManager.default.fileExists(atPath: asset.path) else {
            throw XCTSkip("Bundled JetBrains Mono asset is unavailable")
        }

        var registrationError: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(asset as CFURL, .process, &registrationError) else {
            throw XCTSkip("Could not register bundled JetBrains Mono asset")
        }
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(asset as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first else {
            throw XCTSkip("Bundled JetBrains Mono asset has no CoreText descriptor")
        }
        let regular = CTFontCreateWithFontDescriptor(descriptor, fontSize, nil)
        let postScriptName = CTFontCopyPostScriptName(regular) as String
        let familyName = CTFontCopyFamilyName(regular) as String

        assertIdentityAndCyrillic(
            TerminalRenderer.Metrics(fontSize: fontSize, fontName: familyName).font,
            matches: regular
        )
        assertIdentityAndCyrillic(
            TerminalRenderer.Metrics(fontSize: fontSize, fontName: familyName + "-Regular").font,
            matches: regular
        )
        assertIdentityAndCyrillic(
            TerminalRenderer.Metrics(fontSize: fontSize, fontName: postScriptName).font,
            matches: regular
        )
    }

    func testExplicitCellDimensionsOverrideDerivedMetrics() {
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, fontSize, nil)
        let derived = derivedMetrics(for: font)

        let metrics = TerminalRenderer.Metrics(
            fontSize: fontSize,
            fontName: "Menlo",
            cellWidth: 15.0,
            cellHeight: 25.0
        )
        XCTAssertEqual(metrics.cellWidth, 15.0)
        XCTAssertEqual(metrics.cellHeight, 25.0)
        XCTAssertEqual(metrics.baseline, derived.baseline)
        assertIdentityAndCyrillic(metrics.font, matches: font)

        let widthOnly = TerminalRenderer.Metrics(
            fontSize: fontSize,
            fontName: "Menlo",
            cellWidth: 14.0
        )
        XCTAssertEqual(widthOnly.cellWidth, 14.0)
        XCTAssertEqual(widthOnly.cellHeight, derived.height)

        let heightOnly = TerminalRenderer.Metrics(
            fontSize: fontSize,
            fontName: "Menlo",
            cellHeight: 22.0
        )
        XCTAssertEqual(heightOnly.cellWidth, derived.width)
        XCTAssertEqual(heightOnly.cellHeight, 22.0)
    }

    func testNonFiniteCellWidthOverrideFallsBackToDerivedWidth() {
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, fontSize, nil)
        let derived = derivedMetrics(for: font)

        let nanMetrics = TerminalRenderer.Metrics(
            fontSize: fontSize,
            fontName: "Menlo",
            cellWidth: .nan
        )
        XCTAssertFalse(nanMetrics.cellWidth.isNaN)
        XCTAssertEqual(nanMetrics.cellWidth, derived.width)

        let infMetrics = TerminalRenderer.Metrics(
            fontSize: fontSize,
            fontName: "Menlo",
            cellWidth: .infinity
        )
        XCTAssertNotEqual(infMetrics.cellWidth, .infinity)
        XCTAssertEqual(infMetrics.cellWidth, derived.width)

        let negInfMetrics = TerminalRenderer.Metrics(
            fontSize: fontSize,
            fontName: "Menlo",
            cellWidth: -.infinity
        )
        XCTAssertNotEqual(negInfMetrics.cellWidth, -.infinity)
        XCTAssertEqual(negInfMetrics.cellWidth, derived.width)
    }

    func testNonFiniteCellHeightOverrideFallsBackToDerivedHeight() {
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, fontSize, nil)
        let derived = derivedMetrics(for: font)

        let nanMetrics = TerminalRenderer.Metrics(
            fontSize: fontSize,
            fontName: "Menlo",
            cellHeight: .nan
        )
        XCTAssertFalse(nanMetrics.cellHeight.isNaN)
        XCTAssertEqual(nanMetrics.cellHeight, derived.height)

        let infMetrics = TerminalRenderer.Metrics(
            fontSize: fontSize,
            fontName: "Menlo",
            cellHeight: .infinity
        )
        XCTAssertNotEqual(infMetrics.cellHeight, .infinity)
        XCTAssertEqual(infMetrics.cellHeight, derived.height)

        let negInfMetrics = TerminalRenderer.Metrics(
            fontSize: fontSize,
            fontName: "Menlo",
            cellHeight: -.infinity
        )
        XCTAssertNotEqual(negInfMetrics.cellHeight, -.infinity)
        XCTAssertEqual(negInfMetrics.cellHeight, derived.height)
    }

    func testZeroCellWidthOverrideFallsBackToDerivedWidth() {
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, fontSize, nil)
        let derived = derivedMetrics(for: font)

        let metrics = TerminalRenderer.Metrics(
            fontSize: fontSize,
            fontName: "Menlo",
            cellWidth: 0.0
        )
        XCTAssertNotEqual(metrics.cellWidth, 0.0)
        XCTAssertEqual(metrics.cellWidth, derived.width)
    }

    func testZeroCellHeightOverrideFallsBackToDerivedHeight() {
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, fontSize, nil)
        let derived = derivedMetrics(for: font)

        let metrics = TerminalRenderer.Metrics(
            fontSize: fontSize,
            fontName: "Menlo",
            cellHeight: 0.0
        )
        XCTAssertNotEqual(metrics.cellHeight, 0.0)
        XCTAssertEqual(metrics.cellHeight, derived.height)
    }

    func testNegativeCellWidthOverrideFallsBackToDerivedWidth() {
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, fontSize, nil)
        let derived = derivedMetrics(for: font)

        let metrics = TerminalRenderer.Metrics(
            fontSize: fontSize,
            fontName: "Menlo",
            cellWidth: -10.0
        )
        XCTAssertNotEqual(metrics.cellWidth, -10.0)
        XCTAssertEqual(metrics.cellWidth, derived.width)
    }

    func testNegativeCellHeightOverrideFallsBackToDerivedHeight() {
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, fontSize, nil)
        let derived = derivedMetrics(for: font)

        let metrics = TerminalRenderer.Metrics(
            fontSize: fontSize,
            fontName: "Menlo",
            cellHeight: -10.0
        )
        XCTAssertNotEqual(metrics.cellHeight, -10.0)
        XCTAssertEqual(metrics.cellHeight, derived.height)
    }

    func testDerivedCellWidthEqualsCeilOfGlyphMAdvance() {
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, fontSize, nil)
        let glyph = CTFontGetGlyphWithName(font, "M" as CFString)
        var advance = CGSize.zero
        var glyphs = [glyph]
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advance, 1)
        let expectedWidth = ceil(advance.width)

        let metrics = TerminalRenderer.Metrics(fontSize: fontSize, fontName: "Menlo")
        XCTAssertEqual(metrics.cellWidth, expectedWidth)
        XCTAssertEqual(metrics.cellWidth, 8.0)
    }

    func testDerivedCellHeightEqualsCeilOfAscentDescentAndLeading() {
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, fontSize, nil)
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        let expectedHeight = ceil(ascent + descent + leading)

        let metrics = TerminalRenderer.Metrics(fontSize: fontSize, fontName: "Menlo")
        XCTAssertEqual(metrics.cellHeight, expectedHeight)
        XCTAssertEqual(metrics.cellHeight, 16.0)

        // Menlo reports leading 0, so the assertions above cannot tell
        // ceil(ascent + descent + leading) from ceil(ascent + descent).
        // Monaco carries a non-zero leading and does pin that term. iOS has
        // no Monaco: CoreText and the renderer fall back to different fonts.
        #if os(macOS)
        let leaded = CTFontCreateWithName("Monaco" as CFString, fontSize, nil)
        let leadedLeading = CTFontGetLeading(leaded)
        XCTAssertGreaterThan(leadedLeading, 0, "Monaco must carry leading for this test to mean anything")
        let leadedAscent = CTFontGetAscent(leaded)
        let leadedDescent = CTFontGetDescent(leaded)
        let leadedMetrics = TerminalRenderer.Metrics(fontSize: fontSize, fontName: "Monaco")
        XCTAssertEqual(leadedMetrics.cellHeight, ceil(leadedAscent + leadedDescent + leadedLeading))
        XCTAssertNotEqual(leadedMetrics.cellHeight, ceil(leadedAscent + leadedDescent))
        #endif
    }

    func testBaselineEqualsCeilOfDescentAndLeading() {
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, fontSize, nil)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        let expectedBaseline = ceil(descent + leading)

        let metrics = TerminalRenderer.Metrics(fontSize: fontSize, fontName: "Menlo")
        XCTAssertEqual(metrics.baseline, expectedBaseline)
        XCTAssertEqual(metrics.baseline, 4.0)

        // Same blind spot as the cell-height test: with Menlo's zero leading
        // ceil(descent + leading) equals ceil(descent). Monaco separates them
        // (macOS only, as above).
        #if os(macOS)
        let leaded = CTFontCreateWithName("Monaco" as CFString, fontSize, nil)
        let leadedLeading = CTFontGetLeading(leaded)
        XCTAssertGreaterThan(leadedLeading, 0, "Monaco must carry leading for this test to mean anything")
        let leadedDescent = CTFontGetDescent(leaded)
        let leadedMetrics = TerminalRenderer.Metrics(fontSize: fontSize, fontName: "Monaco")
        XCTAssertEqual(leadedMetrics.baseline, ceil(leadedDescent + leadedLeading))
        XCTAssertNotEqual(leadedMetrics.baseline, ceil(leadedDescent))
        #endif
    }

    func testMetricsConvenienceInitializerFromTheme() {
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, fontSize, nil)
        let derived = derivedMetrics(for: font)

        let themeWithOverrides = TerminalTheme(
            fontFamily: "Menlo",
            fontSize: fontSize,
            cellWidth: 16.0,
            cellHeight: 28.0
        )
        let overrideMetrics = TerminalRenderer.Metrics(theme: themeWithOverrides)
        XCTAssertEqual(overrideMetrics.cellWidth, 16.0)
        XCTAssertEqual(overrideMetrics.cellHeight, 28.0)
        XCTAssertEqual(overrideMetrics.baseline, derived.baseline)
        assertIdentityAndCyrillic(overrideMetrics.font, matches: font)

        let themeWithoutOverrides = TerminalTheme(
            fontFamily: "Menlo",
            fontSize: fontSize
        )
        let derivedThemeMetrics = TerminalRenderer.Metrics(theme: themeWithoutOverrides)
        XCTAssertEqual(derivedThemeMetrics.cellWidth, derived.width)
        XCTAssertEqual(derivedThemeMetrics.cellHeight, derived.height)
        XCTAssertEqual(derivedThemeMetrics.baseline, derived.baseline)
        assertIdentityAndCyrillic(derivedThemeMetrics.font, matches: font)

        let themeWithInvalidOverrides = TerminalTheme(
            fontFamily: "Menlo",
            fontSize: fontSize,
            cellWidth: -5.0,
            cellHeight: 0.0
        )
        let fallbackMetrics = TerminalRenderer.Metrics(theme: themeWithInvalidOverrides)
        XCTAssertNotEqual(fallbackMetrics.cellWidth, -5.0)
        XCTAssertEqual(fallbackMetrics.cellWidth, derived.width)
        XCTAssertNotEqual(fallbackMetrics.cellHeight, 0.0)
        XCTAssertEqual(fallbackMetrics.cellHeight, derived.height)

        let themeWithNonFiniteOverrides = TerminalTheme(
            fontFamily: "Menlo",
            fontSize: fontSize,
            cellWidth: .nan,
            cellHeight: .infinity
        )
        let nonFiniteMetrics = TerminalRenderer.Metrics(theme: themeWithNonFiniteOverrides)
        XCTAssertFalse(nonFiniteMetrics.cellWidth.isNaN)
        XCTAssertEqual(nonFiniteMetrics.cellWidth, derived.width)
        XCTAssertNotEqual(nonFiniteMetrics.cellHeight, .infinity)
        XCTAssertEqual(nonFiniteMetrics.cellHeight, derived.height)
    }

    private func assertIdentityAndCyrillic(_ actual: CTFont, matches expected: CTFont) {
        XCTAssertEqual(
            CTFontCopyPostScriptName(actual) as String,
            CTFontCopyPostScriptName(expected) as String
        )
        var characters: [UniChar] = [0x0416] // Cyrillic capital Zhe: Ж
        var glyphs: [CGGlyph] = [0]
        XCTAssertTrue(CTFontGetGlyphsForCharacters(actual, &characters, &glyphs, 1))
        XCTAssertNotEqual(glyphs[0], 0)
    }

    private func derivedMetrics(for font: CTFont) -> (width: CGFloat, height: CGFloat, baseline: CGFloat) {
        let glyph = CTFontGetGlyphWithName(font, "M" as CFString)
        var advance = CGSize.zero
        var glyphs = [glyph]
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advance, 1)
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        return (
            width: ceil(advance.width),
            height: ceil(ascent + descent + leading),
            baseline: ceil(descent + leading)
        )
    }
}
