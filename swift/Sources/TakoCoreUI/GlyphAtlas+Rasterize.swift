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

extension GlyphAtlas {
    func rasterizeAndPack(key: GlyphAtlasKey, font: CTFont) -> GlyphAtlasEntry {
        var glyph = key.glyph
        var boundingRect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .default, &glyph, &boundingRect, 1)
        if key.emboldened, !boundingRect.isEmpty {
            let outset = Self.syntheticBoldStrokeWidth(fontSize: CTFontGetSize(font)) / 2
            boundingRect = boundingRect.insetBy(dx: -outset, dy: -outset)
        }

        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)

        let scale = max(key.scale, 0.001)
        boundingRect = Self.pixelAligned(boundingRect, scale: scale)
        let widthPixels = Int(ceil(boundingRect.width * scale))
        let heightPixels = Int(ceil(boundingRect.height * scale))

        let bearing = CGPoint(x: boundingRect.minX, y: boundingRect.minY)

        if widthPixels <= 0 || heightPixels <= 0 {
            return GlyphAtlasEntry(
                key: key,
                pageIndex: 0,
                rect: .zero,
                uvRect: .zero,
                bearing: bearing,
                advance: advance,
                pixelWidth: 0,
                pixelHeight: 0,
                isEmpty: true,
                isRasterized: false
            )
        }

        guard let (maskWidth, maskHeight, maskData) = renderGlyph(
            glyph: glyph,
            font: font,
            boundingRect: boundingRect,
            scale: scale,
            pixelFormat: key.pixelFormat,
            emboldened: key.emboldened
        ) else {
            return GlyphAtlasEntry(
                key: key,
                pageIndex: 0,
                rect: .zero,
                uvRect: .zero,
                bearing: bearing,
                advance: advance,
                pixelWidth: 0,
                pixelHeight: 0,
                isEmpty: true,
                isRasterized: false
            )
        }

        return pack(
            key: key,
            maskWidth: maskWidth,
            maskHeight: maskHeight,
            maskData: maskData,
            bearing: bearing,
            advance: advance
        )
    }

    func pack(
        key: GlyphAtlasKey,
        maskWidth: Int,
        maskHeight: Int,
        maskData: Data,
        bearing: CGPoint,
        advance: CGSize
    ) -> GlyphAtlasEntry {
        var pageIdx = 0
        var packedRect: CGRect? = nil

        for (idx, page) in pages.enumerated() where page.pixelFormat == key.pixelFormat {
            if let r = page.pack(maskWidth: maskWidth, maskHeight: maskHeight, maskData: maskData) {
                pageIdx = idx
                packedRect = r
                break
            }
        }

        if packedRect == nil {
            let newPage = GlyphAtlasPage(
                width: Int(pageSize.width),
                height: Int(pageSize.height),
                padding: padding,
                pixelFormat: key.pixelFormat
            )
            pageIdx = pages.count
            packedRect = newPage.pack(maskWidth: maskWidth, maskHeight: maskHeight, maskData: maskData)
            pages.append(newPage)
        }

        guard let rect = packedRect else {
            return GlyphAtlasEntry(
                key: key,
                pageIndex: 0,
                rect: .zero,
                uvRect: .zero,
                bearing: bearing,
                advance: advance,
                pixelWidth: maskWidth,
                pixelHeight: maskHeight,
                isEmpty: false,
                isRasterized: false
            )
        }
        generation &+= 1

        let atlasW = CGFloat(Int(pageSize.width))
        let atlasH = CGFloat(Int(pageSize.height))
        let uvRect = CGRect(
            x: rect.origin.x / atlasW,
            y: rect.origin.y / atlasH,
            width: rect.width / atlasW,
            height: rect.height / atlasH
        )

        return GlyphAtlasEntry(
            key: key,
            pageIndex: pageIdx,
            rect: rect,
            uvRect: uvRect,
            bearing: bearing,
            advance: advance,
            pixelWidth: maskWidth,
            pixelHeight: maskHeight,
            isEmpty: false,
            isRasterized: true
        )
    }

    private func renderGlyph(
        glyph: CGGlyph,
        font: CTFont,
        boundingRect: CGRect,
        scale: CGFloat,
        pixelFormat: GlyphAtlasPixelFormat,
        emboldened: Bool
    ) -> (Int, Int, Data)? {
        renderMask(boundingRect: boundingRect, scale: scale, pixelFormat: pixelFormat) { context, ink in
            if emboldened {
                context.setStrokeColor(ink)
                context.setLineWidth(Self.syntheticBoldStrokeWidth(fontSize: CTFontGetSize(font)))
                context.setTextDrawingMode(.fillStroke)
            }
            var g = glyph
            var position = CGPoint.zero
            CTFontDrawGlyphs(font, &g, &position, 1, context)
        }
    }

    /// `rect` grown out to whole device pixels. Ink starts a fraction of a
    /// pixel from the baseline, different for every glyph, while the quad is
    /// drawn on whole pixels: an unaligned rect left each glyph shifted by
    /// its own remainder, so neighbours sat up to a pixel higher or lower --
    /// most visibly in Cyrillic, whose letters reach below the baseline by
    /// many different amounts.
    public static func pixelAligned(_ rect: CGRect, scale: CGFloat) -> CGRect {
        guard !rect.isNull, !rect.isEmpty else { return rect }
        let minX = floor(rect.minX * scale) / scale
        let minY = floor(rect.minY * scale) / scale
        let maxX = ceil(rect.maxX * scale) / scale
        let maxY = ceil(rect.maxY * scale) / scale
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Rasterizes `draw` -- which draws with its origin on the baseline, in
    /// points -- into a zeroed mask covering `boundingRect`.
    private func renderMask(
        boundingRect: CGRect,
        scale: CGFloat,
        pixelFormat: GlyphAtlasPixelFormat,
        draw: (CGContext, CGColor) -> Void
    ) -> (Int, Int, Data)? {
        let widthPixels = Int(ceil(boundingRect.width * scale))
        let heightPixels = Int(ceil(boundingRect.height * scale))
        guard widthPixels > 0, heightPixels > 0 else { return nil }

        let bytesPerRow = widthPixels * pixelFormat.bytesPerPixel
        var pixelData = Data(repeating: 0, count: bytesPerRow * heightPixels)

        let colorSpace = pixelFormat == .grayscale8
            ? CGColorSpaceCreateDeviceGray()
            : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
        let bitmapInfo: UInt32 = pixelFormat == .grayscale8
            ? CGImageAlphaInfo.none.rawValue
            : (CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        let rendered = pixelData.withUnsafeMutableBytes { raw -> Bool in
            guard let baseAddress = raw.baseAddress else { return false }
            guard let context = CGContext(
                data: baseAddress,
                width: widthPixels,
                height: heightPixels,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }

            context.setShouldAntialias(true)
            context.setAllowsAntialiasing(true)
            context.setShouldSmoothFonts(true)
            context.textMatrix = .identity

            let ink = pixelFormat == .grayscale8
                ? CGColor(gray: 1.0, alpha: 1.0)
                : CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.setFillColor(ink)

            context.saveGState()
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -boundingRect.origin.x, y: -boundingRect.origin.y)
            draw(context, ink)
            context.restoreGState()
            context.flush()
            return true
        }
        guard rendered else { return nil }

        return (widthPixels, heightPixels, pixelData)
    }

    private static func shapedLine(_ text: String, font: CTFont) -> (line: CTLine, runs: [CTRun], isColor: Bool) {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorFromContextAttributeName: true,
        ]
        let attributed = CFAttributedStringCreate(
            kCFAllocatorDefault, text as CFString, attributes as CFDictionary
        )!
        let line = CTLineCreateWithAttributedString(attributed)
        let runs = (CTLineGetGlyphRuns(line) as? [CTRun]) ?? []
        let isColor = runs.contains { run in
            CTRunGetGlyphCount(run) > 0 && Self.font(of: run).map(GlyphAtlasKey.isColorFont) == true
        }
        return (line, runs, isColor)
    }

    func rasterizeAndPackCluster(request: ClusterRequest, font: CTFont) -> GlyphAtlasEntry {
        let (line, runs, isColor) = Self.shapedLine(request.text, font: font)
        let baseName = request.fontName
        let strokeWidth = Self.syntheticBoldStrokeWidth(fontSize: request.fontSize)

        var bounds = CGRect.null
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let runFont = Self.font(of: run) ?? font
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var rects = [CGRect](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTFontGetBoundingRectsForGlyphs(runFont, .default, glyphs, &rects, count)
            let outset = request.emboldened && CTFontCopyPostScriptName(runFont) as String == baseName
                ? strokeWidth / 2 : 0
            for index in 0..<count where !rects[index].isEmpty {
                bounds = bounds.union(rects[index]
                    .offsetBy(dx: positions[index].x, dy: positions[index].y)
                    .insetBy(dx: -outset, dy: -outset))
            }
        }

        let pixelFormat: GlyphAtlasPixelFormat = isColor ? .bgra8Premultiplied : .grayscale8
        let key = GlyphAtlasKey(
            glyph: 0,
            fontName: request.fontName,
            fontSize: request.fontSize,
            scale: request.scale,
            pixelFormat: pixelFormat,
            skew: request.skew,
            emboldened: request.emboldened,
            cluster: request.text
        )
        let advance = CGSize(width: CTLineGetTypographicBounds(line, nil, nil, nil), height: 0)
        let scale = max(request.scale, 0.001)
        bounds = Self.pixelAligned(bounds, scale: scale)
        let bearing = bounds.isNull ? .zero : CGPoint(x: bounds.minX, y: bounds.minY)
        let empty = GlyphAtlasEntry(
            key: key,
            pageIndex: 0,
            rect: .zero,
            uvRect: .zero,
            bearing: bearing,
            advance: advance,
            pixelWidth: 0,
            pixelHeight: 0,
            isEmpty: true,
            isRasterized: false
        )
        guard !bounds.isNull, !bounds.isEmpty,
              let (maskWidth, maskHeight, maskData) = renderMask(
                  boundingRect: bounds, scale: scale, pixelFormat: pixelFormat, draw: { context, ink in
                      for run in runs {
                          let runFont = Self.font(of: run) ?? font
                          let thicken = request.emboldened
                              && CTFontCopyPostScriptName(runFont) as String == baseName
                          context.setTextDrawingMode(thicken ? .fillStroke : .fill)
                          if thicken {
                              context.setStrokeColor(ink)
                              context.setLineWidth(strokeWidth)
                          }
                          context.textPosition = .zero
                          CTRunDraw(run, context, CFRange(location: 0, length: 0))
                      }
                  }) else {
            return empty
        }
        return pack(
            key: key,
            maskWidth: maskWidth,
            maskHeight: maskHeight,
            maskData: maskData,
            bearing: bearing,
            advance: advance
        )
    }

    private static func font(of run: CTRun) -> CTFont? {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let value = attributes[kCTFontAttributeName] else { return nil }
        return (value as! CTFont)
    }
}
