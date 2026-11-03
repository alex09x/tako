/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import TakoCoreUI

final class TerminalFontWeightTests: XCTestCase {
    let keys = ["font-weight", "font-weight-bold", "font-weight-italic", "font-weight-bold-italic"]
    let weights: [KeyPath<TerminalTheme, Int?>] = [
        \.fontWeight, \.fontWeightBold, \.fontWeightItalic, \.fontWeightBoldItalic,
    ]
    let base = "font-family = Menlo\nfont-size = 32\n"

    func metrics(_ config: String) -> TerminalRenderer.Metrics {
        .init(theme: .parse(config: base + config, honourTheme: false))
    }

    func faces(_ metrics: TerminalRenderer.Metrics) -> [CTFont] {
        [metrics.font, metrics.boldFont, metrics.italicFont, metrics.boldItalicFont]
    }

    func pixels(_ entry: GlyphAtlasEntry, in atlas: GlyphAtlas) throws -> [UInt8] {
        XCTAssertTrue(entry.isRasterized)
        let page = try XCTUnwrap(atlas.pages.indices.contains(entry.pageIndex) ? atlas.pages[entry.pageIndex] : nil)
        let x = Int(entry.rect.minX) * page.pixelFormat.bytesPerPixel
        let count = entry.pixelWidth * page.pixelFormat.bytesPerPixel
        return (0..<entry.pixelHeight).flatMap { row in
            let start = (Int(entry.rect.minY) + row) * page.bytesPerRow + x
            return Array(page.data[start..<(start + count)])
        }
    }

    func mask(_ font: CTFont, emboldened: Bool = false) throws -> [UInt8] {
        let atlas = GlyphAtlas()
        let glyph = CTFontGetGlyphWithName(font, "M" as CFString)
        XCTAssertNotEqual(glyph, 0)
        return try pixels(atlas.glyphEntry(for: glyph, font: font, scale: 2, emboldened: emboldened), in: atlas)
    }

    func assertSameRendering(_ lhs: TerminalRenderer.Metrics, _ rhs: TerminalRenderer.Metrics) throws {
        XCTAssertEqual(lhs.cellWidth, rhs.cellWidth)
        XCTAssertEqual(lhs.cellHeight, rhs.cellHeight)
        XCTAssertEqual(lhs.baseline, rhs.baseline)
        XCTAssertEqual(lhs.underlinePosition, rhs.underlinePosition)
        XCTAssertEqual(lhs.underlineThickness, rhs.underlineThickness)
        XCTAssertEqual(lhs.boldIsSynthetic, rhs.boldIsSynthetic)
        XCTAssertEqual(lhs.boldItalicIsSynthetic, rhs.boldItalicIsSynthetic)
        for (left, right) in zip(faces(lhs), faces(rhs)) {
            XCTAssertTrue(CFEqual(left, right))
            XCTAssertEqual(try mask(left), try mask(right))
        }
    }

    func testParsingBoundsAndIntermediateIntegersReachRealFaces() throws {
        for value in [100, 400, 550, 600, 900] {
            let config = keys.map { "\($0) = \(value)" }.joined(separator: "\n")
            let theme = TerminalTheme.parse(config: base + config)
            for path in weights { XCTAssertEqual(theme[keyPath: path], value) }
            let resolved = TerminalRenderer.Metrics(theme: theme)
            let reference = metrics("font-weight = \(value >= 600 ? 700 : 400)")
            XCTAssertEqual(try mask(resolved.font), try mask(reference.font))
        }
        XCTAssertNotEqual(try mask(metrics("font-weight = 100").font), try mask(metrics("font-weight = 900").font))
    }

    func testInvalidValuesPreserveOverlayAndEmptyValuesReset() throws {
        let config = keys.map { "\($0) = 700" }.joined(separator: "\n")
        let original = TerminalTheme.parse(config: base + config)
        for invalid in ["99", "901", "550.0", "bold", "nan", "-1", "99999999999999999999999999"] {
            let overlay = keys.map { "\($0) = \(invalid)" }.joined(separator: "\n")
            let parsed = TerminalTheme.parse(config: overlay, base: original)
            for path in weights { XCTAssertEqual(parsed[keyPath: path], 700) }
            try assertSameRendering(.init(theme: parsed), .init(theme: original))
        }
        let reset = TerminalTheme.parse(config: keys.map { "\($0) =" }.joined(separator: "\n"), base: original)
        for path in weights { XCTAssertNil(reset[keyPath: path]) }
        try assertSameRendering(.init(theme: reset), metrics(""))
    }

    func testAbsentWeightsPreserveLegacyRenderingAndMetrics() throws {
        var theme = TerminalTheme(fontFamily: "Menlo", fontSize: 32)
        for path in weights { XCTAssertNil(theme[keyPath: path]) }
        theme.fontFeatures = [.init(tag: "zero", value: 1)]
        theme.adjustCellHeight = .init(configValue: "10%")
        let parsed = TerminalTheme.parse(config: "foreground = #123456", base: theme)
        try assertSameRendering(.init(theme: theme), .init(theme: parsed))
        try assertSameRendering(.init(fontSize: 32, fontName: "Menlo"), metrics(""))
        let plain = metrics("")
        let expected = ["Menlo-Regular", "Menlo-Bold", "Menlo-Italic", "Menlo-BoldItalic"]
        for (font, name) in zip(faces(plain), expected) {
            let legacy = CTFontCreateWithName(name as CFString, 32, nil)
            XCTAssertTrue(CFEqual(font, legacy))
            XCTAssertEqual(try mask(font), try mask(legacy))
        }
    }

    func testStaticFamilyChoosesActualFaceAndOverridesNamedWeight() throws {
        let regular = metrics("font-weight = 400")
        let bold = metrics("font-weight = 700")
        XCTAssertNil(TerminalRenderer.Metrics.weightAxis(regular.font), "Menlo must be a static fixture")
        XCTAssertEqual(CTFontCopyFamilyName(bold.font) as String, "Menlo")
        XCTAssertEqual(CTFontGetSize(bold.font), 32)
        XCTAssertNotEqual(try mask(regular.font), try mask(bold.font))
        XCTAssertEqual(try mask(metrics("font-weight = 600").font), try mask(bold.font))
        let intermediate = metrics("font-weight = 550").font
        XCTAssertTrue(["Menlo-Regular", "Menlo-Bold"].contains(CTFontCopyPostScriptName(intermediate) as String))
        XCTAssertTrue(GlyphAtlasKey.variations(of: intermediate).isEmpty)
        XCTAssertEqual(try mask(metrics("font-style = Bold\nfont-weight = 400").font), try mask(regular.font))
        let italic = metrics("font-style = Bold Italic\nfont-weight = 400").font
        XCTAssertTrue(CTFontGetSymbolicTraits(italic).contains(.traitItalic))
        XCTAssertEqual(try mask(italic), try mask(regular.italicFont))
    }

    func testBaseInheritanceAndExplicitFourFaceOverrides() throws {
        let normal = metrics("")
        let light = metrics("font-weight = 100")
        XCTAssertEqual(try mask(light.boldFont), try mask(normal.boldFont))
        XCTAssertEqual(try mask(light.boldItalicFont), try mask(normal.boldItalicFont))
        let heavy = metrics("font-weight = 700")
        XCTAssertEqual(try mask(heavy.italicFont), try mask(normal.boldItalicFont))
        let configured = metrics("""
            font-weight = 700
            font-weight-bold = 400
            font-weight-italic = 400
            font-weight-bold-italic = 400
            """)
        XCTAssertEqual(try mask(configured.font), try mask(normal.boldFont))
        XCTAssertEqual(try mask(configured.boldFont), try mask(normal.font))
        XCTAssertEqual(try mask(configured.italicFont), try mask(normal.italicFont))
        XCTAssertEqual(try mask(configured.boldItalicFont), try mask(normal.italicFont))
        XCTAssertFalse(configured.boldIsSynthetic)
        XCTAssertFalse(configured.boldItalicIsSynthetic)
    }

    func testDisabledStylesIgnoreExplicitWeights() throws {
        let disabled = metrics("""
            font-weight = 400
            font-style-bold = false
            font-style-italic = false
            font-style-bold-italic = false
            font-weight-bold = 900
            font-weight-italic = 900
            font-weight-bold-italic = 900
            """)
        for font in faces(disabled) { XCTAssertEqual(try mask(font), try mask(disabled.font)) }
        XCTAssertFalse(disabled.boldIsSynthetic)
        XCTAssertFalse(disabled.boldItalicIsSynthetic)
    }

    func testFullPresetsResetWeightsLegacyThemesPreserveThemAndConfigOverlaysWin() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preset = "# tako-preset-version: 1\n" + base + keys.map { "\($0) = 700" }.joined(separator: "\n")
        try preset.write(to: directory.appendingPathComponent("Heavy"), atomically: true, encoding: .utf8)
        try ("# tako-preset-version: 1\n" + base).write(to: directory.appendingPathComponent("Reset"), atomically: true, encoding: .utf8)
        try (base + "font-weight = 100\nforeground = #112233").write(to: directory.appendingPathComponent("Legacy"), atomically: true, encoding: .utf8)
        let paths = [directory.path]
        let heavy = TerminalTheme().applyingTheme(named: "Heavy", searchPaths: paths)
        XCTAssertTrue(TerminalTheme.presetContainsTypography(named: "Heavy", searchPaths: paths))
        XCTAssertFalse(TerminalTheme.presetContainsTypography(named: "Legacy", searchPaths: paths))
        for path in weights { XCTAssertEqual(heavy[keyPath: path], 700) }
        let legacy = heavy.applyingTheme(named: "Legacy", searchPaths: paths)
        try assertSameRendering(.init(theme: heavy), .init(theme: legacy))
        let reset = heavy.applyingTheme(named: "Reset", searchPaths: paths)
        for path in weights { XCTAssertNil(reset[keyPath: path]) }
        try assertSameRendering(.init(theme: reset), metrics(""))
        for config in ["font-weight = 400\ntheme = Heavy", "theme = Heavy\nfont-weight = 400"] {
            let overlay = TerminalTheme.parse(config: config, base: .takoDefault, honourTheme: true, themeSearchPaths: paths)
            XCTAssertEqual(try mask(TerminalRenderer.Metrics(theme: overlay).font), try mask(metrics("").font))
            XCTAssertEqual(overlay.fontWeightBold, 700)
        }
    }
}
