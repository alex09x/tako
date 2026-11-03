/*
 * tako — Synthesis-off fallback retains the configured variable weight
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import CoreText
import Foundation
import XCTest
@testable import TakoCoreUI

final class TerminalFontWeightFallbackTests: XCTestCase {
    private func theme() throws -> TerminalTheme {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/fonts/FiraCode-VF.ttf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        return TerminalTheme(fontFamily: "Fira Code", fontSize: 32, fontWeight: 550)
    }

    private func weight(_ font: CTFont) -> Double? {
        let values = CTFontCopyVariation(font) as? [NSNumber: NSNumber]
        return values?[NSNumber(value: 0x77676874)]?.doubleValue
    }

    private func glyphPixels(_ font: CTFont) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 96, height: 96, bitsPerComponent: 8,
            bytesPerRow: 96, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        var glyph = CTFontGetGlyphWithName(font, "M" as CFString)
        var origin = CGPoint(x: 8, y: 32)
        CTFontDrawGlyphs(font, &glyph, &origin, 1, context)
        return Data(bytes: try XCTUnwrap(context.data), count: 96 * 96)
    }

    func testUnavailableItalicFacesFallBackToWeightedRegularWhenSynthesisIsDisabled() throws {
        var style = try theme()
        style.fontSyntheticStyle = []
        let metrics = TerminalRenderer.Metrics(theme: style)
        XCTAssertEqual(weight(metrics.font), 550)
        XCTAssertEqual(try glyphPixels(metrics.italicFont), try glyphPixels(metrics.font))
        XCTAssertEqual(try glyphPixels(metrics.boldItalicFont), try glyphPixels(metrics.font))
        XCTAssertEqual(weight(metrics.italicFont), 550)
        XCTAssertEqual(weight(metrics.boldItalicFont), 550)
        XCTAssertFalse(metrics.boldItalicIsSynthetic)
        // A real bold face is still selected rather than flattened to 550.
        XCTAssertNotEqual(try glyphPixels(metrics.boldFont), try glyphPixels(metrics.font))
    }

    func testExplicitWeightStillOverridesAFallbackWithoutCreatingSyntheticSlant() throws {
        var style = try theme()
        style.fontSyntheticStyle = []
        style.fontWeightBoldItalic = 650
        let metrics = TerminalRenderer.Metrics(theme: style)
        XCTAssertEqual(weight(metrics.boldItalicFont), 650)
        XCTAssertEqual(CTFontGetMatrix(metrics.boldItalicFont).c, 0)
        XCTAssertFalse(metrics.boldItalicIsSynthetic)
    }
}
