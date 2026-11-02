/*
 * tako — Rendered appearance assertions for XCUITest
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Vision
import XCTest

extension TakoScopedAppearanceHelpers {
    struct GlyphObservation {
        let bounds: CGRect
        let pixels: Data
        let screenshot: XCUIScreenshot
    }

    static func samplePixelColor(from element: XCUIElement) -> NSColor? {
        let image = element.screenshot().image
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        guard let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let offset = (Int(Double(cg.height) * 0.9) * cg.width + Int(Double(cg.width) * 0.9)) * 4
        return NSColor(srgbRed: CGFloat(data[offset]) / 255, green: CGFloat(data[offset + 1]) / 255,
                       blue: CGFloat(data[offset + 2]) / 255, alpha: 1)
    }

    static func colorDifference(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let a = a.usingColorSpace(.sRGB) ?? a, b = b.usingColorSpace(.sRGB) ?? b
        return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
    }

    static func glyphs(in element: XCUIElement) throws -> GlyphObservation {
        let screenshot = element.screenshot()
        guard let cg = screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ObservationError.unavailable("Screenshot image unavailable")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: cg).perform([request])
        guard let word = request.results?.first(where: { $0.topCandidates(1).first?.string == "ALPHABET" }) else {
            throw ObservationError.unavailable("Font witness not yet rendered")
        }
        let rect = CGRect(x: word.boundingBox.minX * CGFloat(cg.width), y: (1 - word.boundingBox.maxY) * CGFloat(cg.height),
                          width: word.boundingBox.width * CGFloat(cg.width), height: word.boundingBox.height * CGFloat(cg.height))
        guard let crop = cg.cropping(to: rect.insetBy(dx: -2, dy: -2).integral), let pixels = crop.dataProvider?.data else {
            throw ObservationError.unavailable("Glyph raster unavailable")
        }
        return GlyphObservation(bounds: rect, pixels: pixels as Data, screenshot: screenshot)
    }
}
