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

extension TerminalFontWeightTests {
    private func designWeight(_ font: CTFont) -> Double? {
        let id = NSNumber(value: 0x77676874)
        if let value = (CTFontCopyVariation(font) as? [NSNumber: NSNumber])?[id] {
            return value.doubleValue
        }
        // CoreText omits coordinates at the font's default, including 400
        // for STIX Two Text. The axis metadata is authoritative in that case.
        let axes = CTFontCopyVariationAxes(font) as? [[CFString: Any]] ?? []
        let axis = axes.first { ($0[kCTFontVariationAxisIdentifierKey] as? NSNumber) == id }
        return (axis?[kCTFontVariationAxisDefaultValueKey] as? NSNumber)?.doubleValue
    }

    private func variableFixture() throws -> CTFont {
        let names = ["STIXTwoText", "KefaIII-Regular"]
            + (CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? [])
        for name in names {
            let font = CTFontCreateWithName(name as CFString, 32, nil)
            guard let axis = TerminalRenderer.Metrics.weightAxis(font), axis.min <= 400, axis.max >= 600 else { continue }
            guard CTFontGetGlyphWithName(font, "M" as CFString) != 0 else { continue }
            print("Variable font fixture: \(CTFontCopyPostScriptName(font)), wght \(axis.min)...\(axis.max)")
            return font
        }
        throw XCTSkip("No actual system variable font with a wght range spanning 400...600; variable rendering/cache coverage unavailable")
    }

    func testVariableWeightsChangeGlyphsAndSeparateBothAtlasCaches() throws {
        let fixture = try variableFixture()
        let name = CTFontCopyPostScriptName(fixture) as String
        let fonts = [400, 550, 600].map { weight in
            TerminalRenderer.Metrics(theme: TerminalTheme(fontFamily: name, fontSize: 32, fontWeight: weight)).font
        }
        for (font, weight) in zip(fonts, [400.0, 550.0, 600.0]) {
            XCTAssertEqual(designWeight(font), weight)
            XCTAssertEqual(CTFontGetSize(font), 32)
            XCTAssertEqual(CTFontCopyFamilyName(font) as String, CTFontCopyFamilyName(fixture) as String)
        }
        let atlas = GlyphAtlas()
        var glyphEntries: [GlyphAtlasEntry] = []
        var clusters: [GlyphAtlasEntry] = []
        for font in fonts {
            let glyph = CTFontGetGlyphWithName(font, "M" as CFString)
            XCTAssertNotEqual(glyph, 0)
            XCTAssertFalse(atlas.contains(glyph: glyph, font: font, scale: 2))
            glyphEntries.append(atlas.glyphEntry(for: glyph, font: font, scale: 2))
            clusters.append(atlas.clusterEntry(for: "Mm", font: font, scale: 2))
        }
        XCTAssertEqual(Set(glyphEntries.map(\.key)).count, 3)
        XCTAssertEqual(Set(clusters.map(\.key)).count, 3)
        // CoreText may generate distinct PostScript instance names. Remove
        // that distinction to exercise same-name identity using the actual
        // variation coordinates and glyphs that were rasterized above.
        let sameNameKeys = glyphEntries.map { entry in
            GlyphAtlasKey(glyph: entry.key.glyph, fontName: name, fontSize: 32,
                          variations: entry.key.variations)
        }
        XCTAssertEqual(Set(sameNameKeys).count, 3)
        XCTAssertEqual(atlas.cachedCount, 6)
        for index in 1..<fonts.count {
            XCTAssertNotEqual(try pixels(glyphEntries[index - 1], in: atlas), try pixels(glyphEntries[index], in: atlas))
            XCTAssertNotEqual(try pixels(clusters[index - 1], in: atlas), try pixels(clusters[index], in: atlas))
        }
        // Returning to an earlier instance reuses its own pixels/entry.
        let reused = atlas.glyphEntry(for: CTFontGetGlyphWithName(fonts[0], "M" as CFString), font: fonts[0], scale: 2)
        XCTAssertEqual(reused.key, glyphEntries[0].key)
        XCTAssertEqual(reused.rect, glyphEntries[0].rect)
        XCTAssertEqual(atlas.cachedCount, 6)
    }

    func testVariableWeightsSurviveFeaturesAndMetalGlyphResolution() throws {
        let fixture = try variableFixture()
        let name = CTFontCopyPostScriptName(fixture) as String
        var masks: [[UInt8]] = []
        let atlas = GlyphAtlas()
        for weight in [400, 550, 600] {
            var theme = TerminalTheme(fontFamily: name, fontSize: 32, fontWeight: weight)
            theme.fontFeatures = [.init(tag: "zero", value: 1)]
            theme.adjustCellHeight = .init(configValue: "10%")
            let metrics = TerminalRenderer.Metrics(theme: theme)
            XCTAssertTrue(metrics.hasFontFeatures)
            let planner = TerminalMetalFramePlanner(metrics: TerminalMetalCellMetrics(metrics, scale: 2), atlas: atlas)
            let resolved = try XCTUnwrap(planner.resolveGlyph(for: 0x4D, bold: false, italic: false))
            XCTAssertEqual(designWeight(resolved.font), Double(weight))
            let entry = atlas.glyphEntry(for: resolved.glyph, font: resolved.font, scale: 2)
            masks.append(try pixels(entry, in: atlas))
        }
        XCTAssertEqual(atlas.cachedCount, 3)
        XCTAssertNotEqual(masks[0], masks[1])
        XCTAssertNotEqual(masks[1], masks[2])
    }

    func testLegacyVariableAxisMapsCSSWeightsAroundRegularDefault() throws {
        let fixture = CTFontCreateWithName("Skia-Regular" as CFString, 32, nil)
        guard let axis = TerminalRenderer.Metrics.weightAxis(fixture), axis.max < 100 else {
            throw XCTSkip("System Skia with its legacy GX weight axis is unavailable")
        }
        var masks: [[UInt8]] = []
        for weight in [400, 550, 600] {
            let font = metrics("font-family = Skia-Regular\nfont-weight = \(weight)").font
            let expected = axis.defaultValue + Double(weight - 400) / 500 * (axis.max - axis.defaultValue)
            XCTAssertEqual(try XCTUnwrap(designWeight(font)), expected, accuracy: 0.001)
            masks.append(try mask(font))
        }
        XCTAssertEqual(masks[0], try mask(fixture))
        XCTAssertNotEqual(masks[0], masks[1])
        XCTAssertNotEqual(masks[1], masks[2])
    }
}
