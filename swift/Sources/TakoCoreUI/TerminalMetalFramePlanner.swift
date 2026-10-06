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
import simd

/// Turns one `FfiRenderFrame` into the instance arrays the passes draw.
///
/// This is the whole CPU half of the renderer and it touches no Metal type,
/// so the geometry, the colors, the selection bounds and the pass ordering
/// are all testable on a machine with no GPU at all.
///
/// The instance arrays are properties rather than a returned value on
/// purpose: `plan` clears them keeping their capacity, so a steady-state
/// frame reuses last frame's storage instead of allocating a new array per
/// pass per frame.
public final class TerminalMetalFramePlanner {
    public let metrics: TerminalMetalCellMetrics
    public let atlas: GlyphAtlas
    public var palette: TerminalMetalPalette
    public var colorEncoding: TerminalMetalColorEncoding
    public var colorSpace: TerminalMetalColorSpace
    /// WCAG-style contrast ratio; 1 disables adjustment.
    public var minimumContrast: Float
    /// An unfocused pane dims its text and outlines its cursor.
    public var isFocused: Bool = true
    /// Host-driven blink phase; a blinking cursor is omitted while it is off.
    public var cursorBlinkPhaseOn: Bool = true
    /// `cursor-thickness`: bar/underline cursor thickness in points. Nil
    /// keeps this renderer's own default (2pt, scaled to drawable pixels).
    public var cursorThickness: CGFloat?
    /// `window-padding-color`, and the margins it fills.
    public var margins = TerminalMetalMargins()
    /// `window-colorspace = display-p3`: the terminal's RGB values are Display
    /// P3 coordinates, drawn as they are into a P3 target instead of being
    /// converted from sRGB -- so they come out more saturated, as intended.
    public var cellColorsAreDisplayP3 = false

    public internal(set) var viewport = TerminalMetalViewport(drawableWidth: 0, drawableHeight: 0)
    public internal(set) var backgroundInstances: [TerminalMetalBackgroundInstance] = []
    public internal(set) var selectionInstances: [TerminalMetalSelectionInstance] = []
    public internal(set) var imageInstances: [TerminalMetalImageInstance] = []
    public internal(set) var glyphInstances: [TerminalMetalGlyphInstance] = []
    public internal(set) var colorGlyphInstances: [TerminalMetalGlyphInstance] = []
    public internal(set) var decorationInstances: [TerminalMetalDecorationInstance] = []
    public internal(set) var cursorInstances: [TerminalMetalCursorInstance] = []
    public internal(set) var statistics = TerminalMetalFrameStatistics()

    struct CachedRow {
        var backgroundInstances: [TerminalMetalBackgroundInstance] = []
        var glyphInstances: [TerminalMetalGlyphInstance] = []
        var colorGlyphInstances: [TerminalMetalGlyphInstance] = []
        var decorationInstances: [TerminalMetalDecorationInstance] = []
        var skippedGlyphs: Int = 0
        var visitedCells: Int = 0
        var blockCursorCol: Int? = nil
        var selectedColumns: ClosedRange<Int>? = nil
        var isPopulated: Bool = false
        var packedRowData: Data? = nil
        var graphemes: [Int: String]? = nil
    }

    struct CacheState: Equatable {
        var cols: Int
        var rows: Int
        var drawableWidth: Float
        var drawableHeight: Float
        var colorEncoding: TerminalMetalColorEncoding
        var colorSpace: TerminalMetalColorSpace
        var minimumContrast: Float
        var isFocused: Bool
        var palette: TerminalMetalPalette
        var viewportOffset: UInt32
        var alternateScreen: Bool
        var margins: TerminalMetalMargins
        var cellColorsAreDisplayP3: Bool
    }

    var selectedColumnsByRow: [Int: ClosedRange<Int>] = [:]
    var rowCache: [CachedRow] = []
    var cacheState: CacheState?
    var cachedPackedCells: Data?

    public internal(set) var dirtyAtlasPages: Set<Int> = []
    public internal(set) var atlasGeneration: Int = 0

    public internal(set) var glyphPageRanges: [(page: Int, range: Range<Int>)] = []
    public internal(set) var colorGlyphPageRanges: [(page: Int, range: Range<Int>)] = []

    struct StyledScalar: Hashable { let scalar: UInt32; let traits: UInt8 }
    struct ResolvedGlyph { let font: CTFont; let glyph: CGGlyph; let emboldened: Bool }
    var resolvedGlyphs: [StyledScalar: ResolvedGlyph?] = [:]
    var blockCursorCell: (row: Int, col: Int)?
    var frameGraphemes: [Int: [Int: String]] = [:]

    public init(
        metrics: TerminalMetalCellMetrics,
        atlas: GlyphAtlas = GlyphAtlas(),
        palette: TerminalMetalPalette? = nil,
        colorEncoding: TerminalMetalColorEncoding = .displayEncoded,
        colorSpace: TerminalMetalColorSpace = .sRGB,
        minimumContrast: Float = 1
    ) {
        self.metrics = metrics
        self.atlas = atlas
        self.colorEncoding = colorEncoding
        self.colorSpace = colorSpace
        self.minimumContrast = max(1, minimumContrast)
        self.palette = palette ?? .standard(encoding: colorEncoding, colorSpace: colorSpace)
    }

    public var activePasses: [TerminalMetalRenderPass] {
        TerminalMetalRenderPass.orderedWithImages.filter { !isEmpty($0) }
    }

    public func isEmpty(_ pass: TerminalMetalRenderPass) -> Bool {
        switch pass {
        case .background: return backgroundInstances.isEmpty
        case .selection: return selectionInstances.isEmpty
        case .kittyImage: return imageInstances.isEmpty
        case .grayscaleGlyph: return glyphInstances.isEmpty
        case .colorGlyph: return colorGlyphInstances.isEmpty
        case .decoration: return decorationInstances.isEmpty
        case .cursor: return cursorInstances.isEmpty
        }
    }

    public func clearDirtyAtlasPages() {
        dirtyAtlasPages.removeAll(keepingCapacity: true)
    }

    public func discardPlannedFrame() {
        rowCache.removeAll(keepingCapacity: true)
        cacheState = nil
        cachedPackedCells = nil
    }

    // MARK: - Validation

    public static func validate(
        frame: FfiRenderFrame,
        viewport: TerminalMetalViewport,
        overscanRows: Int = 0
    ) -> TerminalMetalFrameValidation {
        guard viewport.drawableWidth.isFinite, viewport.drawableHeight.isFinite,
              viewport.drawableWidth >= 1, viewport.drawableHeight >= 1 else {
            return .invalidViewport
        }
        guard let cols = Int(exactly: frame.snapshot.cols),
              let viewportRows = Int(exactly: frame.snapshot.rows),
              cols <= maximumGridDimension, viewportRows <= maximumGridDimension else {
            return .invalidGridDimensions
        }
        guard cols > 0, viewportRows > 0 else { return .emptyGrid }
        guard overscanRows >= 0, overscanRows <= maximumOverscanRows else {
            return .invalidGridDimensions
        }
        let rows = viewportRows + overscanRows
        guard rows <= maximumGridDimension else { return .invalidGridDimensions }

        let cells = cols.multipliedReportingOverflow(by: rows)
        guard !cells.overflow, cells.partialValue <= maximumCellCount else {
            return .invalidGridDimensions
        }
        let expected = cells.partialValue.multipliedReportingOverflow(by: TerminalCell.byteSize)
        guard !expected.overflow else { return .invalidGridDimensions }

        let actual = frame.packedCells.count
        guard actual >= expected.partialValue else {
            return .truncatedPackedCells(expected: expected.partialValue, actual: actual)
        }
        return .valid
    }

    public static let maximumGridDimension = 1 << 16
    public static let maximumCellCount = 1 << 24
    public static let maximumOverscanRows = 2

    // MARK: - Planning

    @discardableResult
    public func plan(
        frame: FfiRenderFrame,
        viewport: TerminalMetalViewport,
        overscanRows: Int = 0,
        imageProvider: (UInt32) -> FfiStoredImage? = { _ in nil },
        imageMetadataProvider: (UInt32) -> FfiGraphicsImageMetadata? = { _ in nil }
    ) -> TerminalMetalFrameStatistics {
        backgroundInstances.removeAll(keepingCapacity: true)
        selectionInstances.removeAll(keepingCapacity: true)
        imageInstances.removeAll(keepingCapacity: true)
        glyphInstances.removeAll(keepingCapacity: true)
        colorGlyphInstances.removeAll(keepingCapacity: true)
        decorationInstances.removeAll(keepingCapacity: true)
        cursorInstances.removeAll(keepingCapacity: true)
        glyphPageRanges.removeAll(keepingCapacity: true)
        colorGlyphPageRanges.removeAll(keepingCapacity: true)
        blockCursorCell = nil

        self.viewport = viewport
        atlasGeneration = Int(truncatingIfNeeded: atlas.generation)
        var stats = TerminalMetalFrameStatistics()
        stats.validation = Self.validate(frame: frame, viewport: viewport, overscanRows: overscanRows)
        stats.atlasGeneration = atlasGeneration
        stats.atlasPageCount = atlas.pages.count

        let snapshot = frame.snapshot
        guard stats.validation == .valid else {
            cacheState = nil
            rowCache = []
            cachedPackedCells = nil
            statistics = stats
            return stats
        }

        let cols = Int(snapshot.cols)
        let rows = Int(snapshot.rows)
        stats.cols = cols
        stats.rows = rows

        let cells = TerminalFrame(packed: frame.packedCells, cols: cols, rows: rows + overscanRows)
        frameGraphemes.removeAll(keepingCapacity: true)
        for grapheme in frame.graphemes {
            frameGraphemes[Int(grapheme.row), default: [:]][Int(grapheme.col)] = grapheme.text
        }
        planCursor(snapshot, cols: cols, rows: rows)
        selectedColumnsByRow = [:]
        if let selection = snapshot.selection,
           palette.selectionForeground != nil || palette.selectionInvertsColors {
            for span in Self.selectionSpans(for: selection, cols: cols, rows: rows) {
                selectedColumnsByRow[span.row] = span.firstColumn...span.lastColumn
            }
        }
        planCellPasses(cells, snapshot: snapshot, into: &stats)
        planMargins(cells, snapshot: snapshot, rows: rows)
        if let selection = snapshot.selection, !palette.selectionInvertsColors {
            planSelection(selection, cols: cols, rows: rows)
        }
        planImages(
            snapshot.graphicsPlacements,
            cols: cols,
            rows: rows + overscanRows,
            provider: imageProvider,
            metadataProvider: imageMetadataProvider,
            into: &stats
        )
        finishGlyphPass()

        stats.backgroundInstances = backgroundInstances.count
        stats.selectionInstances = selectionInstances.count
        stats.imageInstances = imageInstances.count
        stats.colorGlyphInstances = colorGlyphInstances.count
        stats.glyphInstances = glyphInstances.count + colorGlyphInstances.count
        stats.decorationInstances = decorationInstances.count
        stats.cursorInstances = cursorInstances.count
        stats.atlasPageCount = atlas.pages.count
        stats.atlasGeneration = atlasGeneration
        statistics = stats
        return stats
    }
}
