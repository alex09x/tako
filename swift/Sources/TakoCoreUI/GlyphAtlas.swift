import CoreGraphics
import CoreText
import Foundation

/// CPU and Metal representation of one atlas page.
@frozen public enum GlyphAtlasPixelFormat: UInt32, Sendable, Equatable {
    case grayscale8 = 0
    case bgra8Premultiplied = 1

    public var bytesPerPixel: Int { self == .grayscale8 ? 1 : 4 }
}

/// Key uniquely identifying a rasterized glyph variant in the atlas.
public struct GlyphAtlasKey: Hashable, Equatable, Sendable {
    public let glyph: CGGlyph
    public let fontName: String
    public let fontSize: CGFloat
    public let scale: CGFloat
    public let pixelFormat: GlyphAtlasPixelFormat
    /// Horizontal slant from the font matrix: a synthesised italic shares
    /// its PostScript name with the upright face.
    public let skew: CGFloat
    /// Drawn thickened, as a synthesised bold.
    public let emboldened: Bool
    /// A shaped grapheme cluster rather than one glyph: `glyph` is 0 and
    /// `fontName` is the face the cluster was shaped with.
    public let cluster: String?

    public init(
        glyph: CGGlyph,
        fontName: String,
        fontSize: CGFloat,
        scale: CGFloat = 1.0,
        pixelFormat: GlyphAtlasPixelFormat = .grayscale8,
        skew: CGFloat = 0,
        emboldened: Bool = false,
        cluster: String? = nil
    ) {
        self.glyph = glyph
        self.fontName = fontName
        self.fontSize = fontSize
        self.scale = scale
        self.pixelFormat = pixelFormat
        self.skew = skew
        self.emboldened = emboldened
        self.cluster = cluster
    }

    public init(
        glyph: CGGlyph,
        font: CTFont,
        scale: CGFloat = 1.0,
        pixelFormat: GlyphAtlasPixelFormat? = nil,
        emboldened: Bool = false
    ) {
        let name = CTFontCopyPostScriptName(font) as String
        let size = CTFontGetSize(font)
        let resolvedFormat = pixelFormat ?? (Self.isColorFont(font) ? .bgra8Premultiplied : .grayscale8)
        self.init(
            glyph: glyph,
            fontName: name,
            fontSize: size,
            scale: scale,
            pixelFormat: resolvedFormat,
            skew: CTFontGetMatrix(font).c,
            emboldened: emboldened
        )
    }

    /// Whether `font` draws colour glyphs (an emoji face).
    static func isColorFont(_ font: CTFont) -> Bool {
        // kCTFontColorGlyphsTrait is not imported as a Swift member on every
        // supported SDK, but its CoreText ABI value is stable.
        CTFontGetSymbolicTraits(font).contains(CTFontSymbolicTraits(rawValue: 1 << 13))
    }
}

/// Metadata and atlas coordinates for a rasterized glyph, suitable for Metal text rendering.
public struct GlyphAtlasEntry: Sendable, Equatable {
    public let key: GlyphAtlasKey
    /// The index of the atlas page containing this glyph's mask.
    public let pageIndex: Int
    public let pixelFormat: GlyphAtlasPixelFormat
    /// Pixel bounding box (x, y, width, height) inside the atlas page.
    public let rect: CGRect
    /// Normalized texture coordinates (u, v, uWidth, vHeight) in 0.0...1.0 space.
    public let uvRect: CGRect
    /// Offset in points relative to the baseline origin to position the glyph quad.
    public let bearing: CGPoint
    /// Horizontal and vertical advance in points.
    public let advance: CGSize
    /// Pixel width of the rasterized mask.
    public let pixelWidth: Int
    /// Pixel height of the rasterized mask.
    public let pixelHeight: Int
    /// True if the glyph has no visible pixel representation (e.g. whitespace).
    public let isEmpty: Bool
    /// True if the glyph mask was rasterized and packed into an atlas page.
    public let isRasterized: Bool

    public init(
        key: GlyphAtlasKey,
        pageIndex: Int,
        pixelFormat: GlyphAtlasPixelFormat? = nil,
        rect: CGRect,
        uvRect: CGRect,
        bearing: CGPoint,
        advance: CGSize,
        pixelWidth: Int,
        pixelHeight: Int,
        isEmpty: Bool,
        isRasterized: Bool
    ) {
        self.key = key
        self.pageIndex = pageIndex
        self.pixelFormat = pixelFormat ?? key.pixelFormat
        self.rect = rect
        self.uvRect = uvRect
        self.bearing = bearing
        self.advance = advance
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isEmpty = isEmpty
        self.isRasterized = isRasterized
    }
}

/// A single packed texture page. Grayscale and color pixels never share a page.
public final class GlyphAtlasPage: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let pixelFormat: GlyphAtlasPixelFormat
    public private(set) var generation: UInt64 = 0
    public var bytesPerRow: Int { width * pixelFormat.bytesPerPixel }
    /// Tightly packed pixel data in `pixelFormat`.
    public private(set) var data: Data

    private var currentX: Int
    private var currentY: Int
    private var currentShelfHeight: Int
    private let padding: Int

    public init(
        width: Int = 1024,
        height: Int = 1024,
        padding: Int = 1,
        pixelFormat: GlyphAtlasPixelFormat = .grayscale8
    ) {
        self.width = width
        self.height = height
        self.padding = padding
        self.pixelFormat = pixelFormat
        self.data = Data(repeating: 0, count: width * height * pixelFormat.bytesPerPixel)
        self.currentX = padding
        self.currentY = padding
        self.currentShelfHeight = 0
    }

    /// Attempts to allocate space for a mask of size `(maskWidth, maskHeight)` and copies `maskData` into the page buffer.
    /// Returns the pixel rectangle inside the page if successful, or `nil` if the page is full.
    public func pack(maskWidth: Int, maskHeight: Int, maskData: Data) -> CGRect? {
        guard maskWidth > 0, maskHeight > 0 else { return nil }
        let sourceBytesPerRow = maskWidth * pixelFormat.bytesPerPixel
        guard maskData.count >= sourceBytesPerRow * maskHeight else { return nil }

        if currentX + maskWidth + padding > width {
            currentX = padding
            currentY += currentShelfHeight + padding
            currentShelfHeight = 0
        }

        if currentY + maskHeight + padding > height {
            return nil
        }

        let allocX = currentX
        let allocY = currentY

        data.withUnsafeMutableBytes { (pageRawBuffer: UnsafeMutableRawBufferPointer) in
            guard let pagePtr = pageRawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            maskData.withUnsafeBytes { (maskRawBuffer: UnsafeRawBufferPointer) in
                guard let maskPtr = maskRawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for row in 0..<maskHeight {
                    let pageOffset = (allocY + row) * bytesPerRow + allocX * pixelFormat.bytesPerPixel
                    let maskOffset = row * sourceBytesPerRow
                    UnsafeMutableRawPointer(pagePtr + pageOffset).copyMemory(
                        from: maskPtr + maskOffset,
                        byteCount: sourceBytesPerRow
                    )
                }
            }
        }

        currentX += maskWidth + padding
        currentShelfHeight = max(currentShelfHeight, maskHeight)
        generation &+= 1

        return CGRect(x: CGFloat(allocX), y: CGFloat(allocY), width: CGFloat(maskWidth), height: CGFloat(maskHeight))
    }
}

/// A reusable glyph atlas that rasterizes CoreText glyphs into packed 8-bit grayscale texture pages once,
/// caching results and exposing stable atlas coordinates for Metal text rendering.
public final class GlyphAtlas: @unchecked Sendable {
    public let pageSize: CGSize
    public let padding: Int

    private(set) public var pages: [GlyphAtlasPage] = []
    private var cache: [GlyphAtlasKey: GlyphAtlasEntry] = [:]
    /// Shaped clusters, by text and requested style; the entry's own key
    /// carries the pixel format shaping chose.
    private struct ClusterRequest: Hashable {
        let text: String
        let fontName: String
        let fontSize: CGFloat
        let skew: CGFloat
        let scale: CGFloat
        let emboldened: Bool
    }
    private var clusterCache: [ClusterRequest: GlyphAtlasEntry] = [:]
    /// Changes whenever any page changes or the atlas is cleared.
    public private(set) var generation: UInt64 = 0

    /// Total number of unique glyph variants currently cached in the atlas.
    public var cachedCount: Int { cache.count + clusterCache.count }

    public init(pageSize: CGSize = CGSize(width: 1024, height: 1024), padding: Int = 1) {
        self.pageSize = pageSize
        self.padding = padding
    }

    /// Stroke width, in points, that thickens a synthesised bold.
    public static func syntheticBoldStrokeWidth(fontSize: CGFloat) -> CGFloat {
        fontSize / 14
    }

    /// Checks if a glyph entry is already cached in the atlas.
    public func contains(glyph: CGGlyph, font: CTFont, scale: CGFloat = 1.0, emboldened: Bool = false) -> Bool {
        let key = GlyphAtlasKey(glyph: glyph, font: font, scale: scale, emboldened: emboldened)
        return cache[key] != nil
    }

    /// Looks up or rasterizes a CoreText glyph, returning a stable `GlyphAtlasEntry`.
    /// `emboldened` thickens it, for a bold the font does not have.
    public func glyphEntry(
        for glyph: CGGlyph,
        font: CTFont,
        scale: CGFloat = 1.0,
        emboldened: Bool = false
    ) -> GlyphAtlasEntry {
        let key = GlyphAtlasKey(glyph: glyph, font: font, scale: scale, emboldened: emboldened)
        if let existing = cache[key] {
            return existing
        }

        let entry = rasterizeAndPack(key: key, font: font)
        cache[key] = entry
        return entry
    }

    /// Convenience lookup by character for a font and scale factor.
    public func glyphEntry(for character: Character, font: CTFont, scale: CGFloat = 1.0) -> GlyphAtlasEntry? {
        let utf16 = Array(character.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        guard CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count), let firstGlyph = glyphs.first else {
            return nil
        }
        return glyphEntry(for: firstGlyph, font: font, scale: scale)
    }

    /// Looks up or rasterizes a grapheme cluster shaped with CoreText from
    /// `font`, falling back per run as CoreText does, into one entry. The
    /// entry is colour when any run's font is a colour font. `emboldened`
    /// thickens only the runs drawn in `font` itself.
    public func clusterEntry(
        for text: String,
        font: CTFont,
        scale: CGFloat = 1.0,
        emboldened: Bool = false
    ) -> GlyphAtlasEntry {
        let request = ClusterRequest(
            text: text,
            fontName: CTFontCopyPostScriptName(font) as String,
            fontSize: CTFontGetSize(font),
            skew: CTFontGetMatrix(font).c,
            scale: scale,
            emboldened: emboldened
        )
        if let existing = clusterCache[request] {
            return existing
        }
        let entry = rasterizeAndPackCluster(request: request, font: font)
        clusterCache[request] = entry
        return entry
    }

    /// Resets all pages and clears the glyph cache.
    public func clear() {
        pages.removeAll()
        cache.removeAll()
        clusterCache.removeAll()
        generation &+= 1
    }

    /// Returns the raw 8-bit grayscale pixel data for a given page index.
    public func textureData(pageIndex: Int) -> Data? {
        guard pageIndex >= 0, pageIndex < pages.count else { return nil }
        return pages[pageIndex].data
    }

    /// Generates a CGImage representation of an atlas page for rendering or inspection.
    public func cgImage(pageIndex: Int) -> CGImage? {
        guard pageIndex >= 0, pageIndex < pages.count else { return nil }
        let page = pages[pageIndex]
        let colorSpace = page.pixelFormat == .grayscale8
            ? CGColorSpaceCreateDeviceGray()
            : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
        guard let provider = CGDataProvider(data: page.data as CFData) else { return nil }
        let bitmapInfo: CGBitmapInfo = page.pixelFormat == .grayscale8
            ? CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
            : [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)]
        return CGImage(
            width: page.width,
            height: page.height,
            bitsPerComponent: 8,
            bitsPerPixel: 8 * page.pixelFormat.bytesPerPixel,
            bytesPerRow: page.bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    // MARK: - Private Rasterization & Packing Logic

    private func rasterizeAndPack(key: GlyphAtlasKey, font: CTFont) -> GlyphAtlasEntry {
        var glyph = key.glyph
        var boundingRect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .default, &glyph, &boundingRect, 1)
        if key.emboldened, !boundingRect.isEmpty {
            // The stroke reaches half its width outside the outline.
            let outset = Self.syntheticBoldStrokeWidth(fontSize: CTFontGetSize(font)) / 2
            boundingRect = boundingRect.insetBy(dx: -outset, dy: -outset)
        }

        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)

        let scale = max(key.scale, 0.001)
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

    private func pack(
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
        // The bitmap context does not own `pixelData`'s storage. Keep its
        // entire lifetime inside the unsafe-bytes closure: an optimized build
        // is otherwise free to move or release the Data buffer before the
        // deferred CoreGraphics calls touch it.
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

            // pixelData is already zero-filled from Data(repeating:0,...) above;
            // calling context.clear() here is redundant and crashes on some
            // glyph+scale combinations (SIGSEGV inside CGContextClearRect).
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

    /// `text` shaped from `font`, with CoreText's own per-run fallback.
    private static func shapedLine(_ text: String, font: CTFont) -> (line: CTLine, runs: [CTRun], isColor: Bool) {
        // The context supplies the ink, so a grayscale mask stays a coverage
        // mask; colour glyphs ignore it.
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

    private func rasterizeAndPackCluster(request: ClusterRequest, font: CTFont) -> GlyphAtlasEntry {
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
        let bearing = bounds.isNull ? .zero : CGPoint(x: bounds.minX, y: bounds.minY)
        let scale = max(request.scale, 0.001)
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
