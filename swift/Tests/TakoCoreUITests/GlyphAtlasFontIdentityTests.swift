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

final class GlyphAtlasFontIdentityTests: XCTestCase {
    func testRepeatedGlyphAndClusterLookupsReadFontMetadataOnce() {
        let atlas = GlyphAtlas()
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        let initial = atlas.glyphEntry(for: CGGlyph(12), font: font)
        for _ in 0..<500 {
            XCTAssertEqual(atlas.glyphEntry(for: CGGlyph(12), font: font), initial)
            XCTAssertTrue(atlas.contains(glyph: 12, font: font))
            _ = atlas.clusterEntry(for: "e\u{301}", font: font)
        }
        XCTAssertEqual(atlas.fontIdentityReadCount, 1)
        XCTAssertEqual(atlas.cachedCount, 2)
        atlas.clear()
        _ = atlas.glyphEntry(for: CGGlyph(12), font: font)
        XCTAssertEqual(atlas.fontIdentityReadCount, 2)
    }

    func testCachedIdentityPreservesFontSizeMatrixScaleAndSyntheticBold() {
        let atlas = GlyphAtlas()
        let base = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        let larger = CTFontCreateCopyWithAttributes(base, 18, nil, nil)
        var matrix = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
        let slanted = CTFontCreateCopyWithAttributes(base, 14, &matrix, nil)
        let emoji = CTFontCreateWithName("AppleColorEmoji" as CFString, 14, nil)
        var keys = Set<GlyphAtlasKey>()
        for font in [base, larger, slanted, emoji] {
            for scale: CGFloat in [1, 2] {
                for bold in [false, true] {
                    let actual = atlas.glyphKey(12, font: font, scale: scale, emboldened: bold)
                    let expected = GlyphAtlasKey(glyph: 12, font: font, scale: scale, emboldened: bold)
                    XCTAssertEqual(actual, expected)
                    keys.insert(actual)
                }
            }
        }
        XCTAssertEqual(keys.count, 16)
        XCTAssertEqual(atlas.fontIdentityReadCount, 4)
    }

    func testVariableInstancesKeepDistinctCoordinates() throws {
        // The shared fixture: an installed font with a real wght axis on
        // macOS and the iOS simulator alike (Skia is macOS-only).
        let base = CTFontCreateCopyWithAttributes(try VariableFontFixture.weightVariableFont(size: 16), 16, nil, nil)
        let axis = try XCTUnwrap(TerminalRenderer.Metrics.weightAxis(base))
        XCTAssertLessThan(axis.min, axis.max, "a real axis range, not a single value")
        // Two coordinates away from the axis default, where CoreText omits
        // the coordinate: the far end, and halfway to it.
        let far = abs(axis.max - axis.defaultValue) >= abs(axis.min - axis.defaultValue) ? axis.max : axis.min
        let id = axis.id
        let halfway = NSNumber(value: (axis.defaultValue + far) / 2)
        let end = NSNumber(value: far)
        XCTAssertNotEqual(halfway.doubleValue, axis.defaultValue)
        XCTAssertNotEqual(halfway, end)
        func instance(_ value: NSNumber) -> CTFont {
            let descriptor = CTFontDescriptorCreateWithAttributes(
                [kCTFontVariationAttribute: [id: value]] as CFDictionary
            )
            return CTFontCreateCopyWithAttributes(base, 16, nil, descriptor)
        }
        let light = instance(halfway)
        let heavy = instance(end)
        let atlas = GlyphAtlas()
        let first = atlas.glyphKey(12, font: light, scale: 2, emboldened: false)
        let second = atlas.glyphKey(12, font: heavy, scale: 2, emboldened: false)
        XCTAssertFalse(first.variations.isEmpty)
        XCTAssertFalse(second.variations.isEmpty)
        XCTAssertNotEqual(first.variations, second.variations)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first, GlyphAtlasKey(glyph: 12, font: light, scale: 2))
        XCTAssertEqual(second, GlyphAtlasKey(glyph: 12, font: heavy, scale: 2))
    }

    func testFallbackFontIdentityStorageIsBoundedWithoutChangingKeys() {
        let atlas = GlyphAtlas()
        var fonts: [CTFont] = []
        for index in 0..<140 {
            let font = CTFontCreateWithName("Menlo" as CFString, CGFloat(10 + index), nil)
            fonts.append(font)
            XCTAssertEqual(
                atlas.glyphKey(12, font: font, scale: 1, emboldened: false),
                GlyphAtlasKey(glyph: 12, font: font)
            )
            XCTAssertLessThanOrEqual(atlas.fontIdentities.count, 128)
        }
        let first = fonts[0]
        XCTAssertEqual(atlas.glyphKey(12, font: first, scale: 1, emboldened: false),
                       GlyphAtlasKey(glyph: 12, font: first))
    }
}
