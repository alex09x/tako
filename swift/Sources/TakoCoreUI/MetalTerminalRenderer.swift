import CoreGraphics
import CoreText
import Foundation
import Metal
import QuartzCore
import simd

// A Metal terminal renderer that belongs to no particular app.
//
// `TerminalRenderer` draws the same grid with CoreText into a `CGContext`,
// which is the right tool for an offscreen bitmap or a printout. This is the
// tool for a live pane: one instanced quad per background run, per selection
// row, per Kitty placement, per glyph and per cursor edge, drawn straight
// into a `CAMetalLayer`.
//
// Everything here is caller-neutral. The device and the shader library are
// injected, no window, view or screen is consulted, and nothing imports
// AppKit or UIKit -- CoreText rasterizes glyphs, QuartzCore supplies
// `CAMetalLayer`, and both exist on macOS and iOS. The host owns the layer
// and the run loop; this owns the pixels in it.

/// How instance colors are encoded for the render target.
///
/// Metal converts nothing on its own: a `.bgra8Unorm` drawable stores exactly
/// the components the fragment shader returns, while a `.bgra8Unorm_srgb` one
/// encodes them from linear on write. `MetalImageCache` hands out plain
/// `.bgra8Unorm` textures holding display-encoded bytes, so `displayEncoded`
/// (the default) is what keeps cell colors, glyph colors and Kitty images in
/// the same space.
@frozen public enum TerminalMetalColorEncoding: Sendable, Equatable {
    /// Components stay as the terminal delivered them, for a non-sRGB target.
    case displayEncoded
    /// Components are linearized, for a `_srgb` render target that re-encodes.
    case linear
}

/// Gamut used by the render target. Terminal RGB triples are defined in sRGB;
/// Display-P3 output converts them through linear light before encoding.
@frozen public enum TerminalMetalColorSpace: Sendable, Equatable {
    case sRGB
    case displayP3
}

/// Color conversion shared by every pass.
public enum TerminalMetalColor {
    @inline(__always)
    private static func decodeSRGB(_ value: Float) -> Float {
        if value <= 0 { return 0 }
        if value >= 1 { return 1 }
        return value <= 0.04045 ? value / 12.92 : powf((value + 0.055) / 1.055, 2.4)
    }

    @inline(__always)
    private static func encodeSRGB(_ value: Float) -> Float {
        let v = max(0, min(1, value))
        if v <= 0 { return 0 }
        if v >= 1 { return 1 }
        return v <= 0.0031308 ? v * 12.92 : 1.055 * powf(v, 1 / 2.4) - 0.055
    }

    /// One 0...255 channel as the shader wants to see it.
    @inline(__always)
    public static func component(_ byte: UInt8, encoding: TerminalMetalColorEncoding) -> Float {
        let value = Float(byte) / 255
        switch encoding {
        case .displayEncoded:
            return value
        case .linear:
            return decodeSRGB(value)
        }
    }

    /// A straight (non-premultiplied) RGBA color from terminal bytes.
    @inline(__always)
    public static func rgba(
        r: UInt8,
        g: UInt8,
        b: UInt8,
        alpha: Float = 1,
        encoding: TerminalMetalColorEncoding = .displayEncoded,
        colorSpace: TerminalMetalColorSpace = .sRGB
    ) -> SIMD4<Float> {
        var linear = SIMD3<Float>(decodeSRGB(Float(r) / 255), decodeSRGB(Float(g) / 255), decodeSRGB(Float(b) / 255))
        if colorSpace == .displayP3 {
            linear = SIMD3<Float>(
                0.8225929 * linear.x + 0.1775340 * linear.y,
                0.0331995 * linear.x + 0.9667835 * linear.y,
                0.0170854 * linear.x + 0.0723957 * linear.y + 0.9103015 * linear.z
            )
        }
        if encoding == .displayEncoded {
            linear = SIMD3<Float>(encodeSRGB(linear.x), encodeSRGB(linear.y), encodeSRGB(linear.z))
        }
        return SIMD4<Float>(linear.x, linear.y, linear.z, max(0, min(1, alpha)))
    }

    /// Every pass blends with `.one, .oneMinusSourceAlpha`, so colors reach
    /// the GPU already multiplied by their own alpha.
    @inline(__always)
    public static func premultiplied(_ color: SIMD4<Float>) -> SIMD4<Float> {
        let alpha = max(0, min(1, color.w))
        guard alpha > 0 else { return .zero }
        return SIMD4<Float>(color.x * alpha, color.y * alpha, color.z * alpha, alpha)
    }

    /// Raises foreground contrast without changing alpha. The interpolation
    /// is performed in linear light and chooses the nearer of black or white.
    public static func enforcingMinimumContrast(
        foreground: SIMD4<Float>,
        background: SIMD4<Float>,
        ratio minimumRatio: Float,
        encoding: TerminalMetalColorEncoding,
        colorSpace: TerminalMetalColorSpace = .sRGB
    ) -> SIMD4<Float> {
        guard foreground.w > 0 else { return .zero }
        let target = max(1, minimumRatio)
        func linear(_ color: SIMD4<Float>) -> SIMD3<Float> {
            let rgb = SIMD3<Float>(color.x, color.y, color.z)
            return encoding == .linear ? rgb : SIMD3<Float>(decodeSRGB(rgb.x), decodeSRGB(rgb.y), decodeSRGB(rgb.z))
        }
        func luminance(_ rgb: SIMD3<Float>) -> Float {
            colorSpace == .displayP3
                ? 0.2289746 * rgb.x + 0.6917385 * rgb.y + 0.0792869 * rgb.z
                : 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
        }
        let fg = linear(foreground)
        let bg = linear(background)
        let fgL = luminance(fg)
        let bgL = luminance(bg)
        let current = (max(fgL, bgL) + 0.05) / (min(fgL, bgL) + 0.05)
        guard current < target else { return foreground }
        let towardWhite = (1.05 / (bgL + 0.05)) >= ((bgL + 0.05) / 0.05)
        let wantedL = towardWhite
            ? min(1, target * (bgL + 0.05) - 0.05)
            : max(0, (bgL + 0.05) / target - 0.05)
        let endpoint = towardWhite ? SIMD3<Float>(repeating: 1) : .zero
        let endpointL: Float = towardWhite ? 1 : 0
        let denominator = endpointL - fgL
        let amount = denominator == 0 ? 1 : max(0, min(1, (wantedL - fgL) / denominator))
        var adjusted = fg + (endpoint - fg) * amount
        if encoding == .displayEncoded {
            adjusted = SIMD3<Float>(encodeSRGB(adjusted.x), encodeSRGB(adjusted.y), encodeSRGB(adjusted.z))
        }
        return SIMD4<Float>(adjusted.x, adjusted.y, adjusted.z, foreground.w)
    }
}

/// The colors the renderer falls back to when the terminal says "default",
/// plus the two overlays the palette never supplies. Straight (not
/// premultiplied) components, in the renderer's `colorEncoding`.
public struct TerminalMetalPalette: Equatable, Sendable {
    public var background: SIMD4<Float>
    public var foreground: SIMD4<Float>
    public var selection: SIMD4<Float>
    /// `selection-foreground`: the colour of selected text; nil keeps each
    /// cell's own.
    public var selectionForeground: SIMD4<Float>?
    /// `selection-invert-fg-bg`: a selected cell swaps its own foreground and
    /// background, and no selection colour is laid over it.
    public var selectionInvertsColors: Bool
    public var cursor: SIMD4<Float>
    /// Alpha applied to text in a pane that does not take the keys.
    public var unfocusedTextAlpha: Float
    /// Alpha applied to text drawn with SGR 2 (dim).
    public var dimAlpha: Float

    public init(
        background: SIMD4<Float>,
        foreground: SIMD4<Float>,
        selection: SIMD4<Float>,
        cursor: SIMD4<Float>,
        unfocusedTextAlpha: Float = 0.75,
        dimAlpha: Float = 0.6,
        selectionForeground: SIMD4<Float>? = nil,
        selectionInvertsColors: Bool = false
    ) {
        self.background = background
        self.foreground = foreground
        self.selection = selection
        self.selectionForeground = selectionForeground
        self.selectionInvertsColors = selectionInvertsColors
        self.cursor = cursor
        self.unfocusedTextAlpha = unfocusedTextAlpha
        self.dimAlpha = dimAlpha
    }

    /// The same defaults `TerminalRenderer` draws with: Prod's own palette,
    /// with the ember cursor the brand owns.
    public static func standard(
        encoding: TerminalMetalColorEncoding = .displayEncoded,
        colorSpace: TerminalMetalColorSpace = .sRGB
    ) -> TerminalMetalPalette {
        TerminalMetalPalette(
            background: TerminalMetalColor.rgba(r: 0x14, g: 0x10, b: 0x0e, encoding: encoding, colorSpace: colorSpace),
            foreground: TerminalMetalColor.rgba(r: 0xed, g: 0xe6, b: 0xdf, encoding: encoding, colorSpace: colorSpace),
            selection: TerminalMetalColor.rgba(r: 0xf5, g: 0x59, b: 0x1c, alpha: 0.3, encoding: encoding, colorSpace: colorSpace),
            cursor: TerminalMetalColor.rgba(r: 0xf4, g: 0x58, b: 0x1c, encoding: encoding, colorSpace: colorSpace)
        )
    }
}

/// The space around the grid, in drawable pixels, and what fills it
/// (`window-padding-color`).
public struct TerminalMetalMargins: Equatable, Sendable {
    public enum Fill: Equatable, Sendable {
        /// The frame's clear colour: the default background.
        case background
        /// The nearest cell's background. Above and below the grid only when
        /// that edge row has no default-background cell, or on the alternate
        /// screen, so a prompt's colours do not bleed into the margin.
        case extend
        /// The nearest cell's background, always.
        case extendAlways
    }

    public var left: Float
    public var top: Float
    public var right: Float
    public var bottom: Float
    public var fill: Fill

    public init(left: Float = 0, top: Float = 0, right: Float = 0, bottom: Float = 0, fill: Fill = .background) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
        self.fill = fill
    }
}

/// Cell geometry in points plus the scale that turns it into drawable pixels.
public struct TerminalMetalCellMetrics {
    public let font: CTFont
    /// Face used for cells with SGR 1 set, when the host has one.
    public let boldFont: CTFont?
    public let italicFont: CTFont?
    public let boldItalicFont: CTFont?
    /// Bold and bold-italic faces thickened at raster time.
    public let boldIsSynthetic: Bool
    public let boldItalicIsSynthetic: Bool
    /// Glyphs are shaped, so `font-feature` substitutions apply.
    public let shapesGlyphs: Bool
    /// Cell size in points.
    public let cellWidth: CGFloat
    public let cellHeight: CGFloat
    /// Points from the top of a cell down to the text baseline.
    public let ascent: CGFloat
    /// Points from the top of a cell down to the top of the underline.
    public let underlinePosition: CGFloat
    public let underlineThickness: CGFloat
    /// Drawable pixels per point. `CAMetalLayer.contentsScale` on a Retina
    /// display, 1 for an offscreen pixel-space target.
    public let scale: CGFloat

    public var pixelCellWidth: Float { Float(cellWidth * scale) }
    public var pixelCellHeight: Float { Float(cellHeight * scale) }
    public var pixelAscent: Float { Float(ascent * scale) }

    public init(
        font: CTFont,
        boldFont: CTFont? = nil,
        italicFont: CTFont? = nil,
        boldItalicFont: CTFont? = nil,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        ascent: CGFloat,
        scale: CGFloat = 1,
        boldIsSynthetic: Bool = false,
        boldItalicIsSynthetic: Bool = false,
        shapesGlyphs: Bool = false,
        underlinePosition: CGFloat? = nil,
        underlineThickness: CGFloat = 1
    ) {
        self.font = font
        self.boldFont = boldFont
        self.italicFont = italicFont
        self.boldItalicFont = boldItalicFont
        self.boldIsSynthetic = boldIsSynthetic
        self.boldItalicIsSynthetic = boldItalicIsSynthetic
        self.shapesGlyphs = shapesGlyphs
        self.cellWidth = max(cellWidth, 1)
        self.cellHeight = max(cellHeight, 1)
        self.ascent = ascent
        self.underlinePosition = underlinePosition ?? ascent + 1
        self.underlineThickness = underlineThickness
        self.scale = max(scale, 0.001)
    }

    /// Reuse the CoreText metrics `TerminalRenderer` already derives, so the
    /// two renderers put the same grid in the same place.
    public init(_ metrics: TerminalRenderer.Metrics, scale: CGFloat = 1) {
        self.init(
            font: metrics.font,
            boldFont: metrics.boldFont,
            italicFont: metrics.italicFont,
            boldItalicFont: metrics.boldItalicFont,
            cellWidth: metrics.cellWidth,
            cellHeight: metrics.cellHeight,
            ascent: metrics.cellHeight - metrics.baseline,
            scale: scale,
            boldIsSynthetic: metrics.boldIsSynthetic,
            boldItalicIsSynthetic: metrics.boldItalicIsSynthetic,
            shapesGlyphs: metrics.hasFontFeatures,
            underlinePosition: metrics.underlinePosition,
            underlineThickness: metrics.underlineThickness
        )
    }

    public init(fontSize: CGFloat, fontName: String? = nil, scale: CGFloat = 1) {
        self.init(TerminalRenderer.Metrics(fontSize: fontSize, fontName: fontName), scale: scale)
    }

    /// Pixel size of a `cols` x `rows` grid at these metrics.
    public func pixelSize(cols: Int, rows: Int) -> SIMD2<Float> {
        SIMD2<Float>(pixelCellWidth * Float(max(cols, 0)), pixelCellHeight * Float(max(rows, 0)))
    }
}

/// Why a frame is or is not renderable. A frame that fails validation is
/// skipped whole -- never partially drawn, never trapped on.
@frozen public enum TerminalMetalFrameValidation: Equatable, Sendable {
    case valid
    /// The snapshot describes a zero-column or zero-row viewport.
    case emptyGrid
    /// Dimensions are negative, absurd, or would overflow the byte count.
    case invalidGridDimensions
    /// Fewer packed bytes arrived than `cols * rows * TerminalCell.byteSize`.
    case truncatedPackedCells(expected: Int, actual: Int)
    /// The drawable has no usable pixel size.
    case invalidViewport
}

/// What became of a planned frame between the planner and the screen.
///
/// Planning a frame and presenting one are two different events, and only
/// the second changes a pixel. A `CAMetalLayer` whose drawable pool is
/// exhausted hands out nothing, and a command queue under pressure can
/// refuse a command buffer or an encoder; in every one of those cases the
/// layer keeps showing whatever was presented last. Reporting that plainly
/// is what lets a host retry the frame instead of settling on stale pixels
/// while its own text is already correct.
@frozen public enum TerminalMetalFramePresentation: Equatable, Sendable {
    /// Nothing was submitted: the frame failed validation, or the caller
    /// only asked for a plan.
    case notSubmitted
    /// The layer had no drawable to hand out.
    case noDrawable
    /// The command queue would not make a command buffer.
    case noCommandBuffer
    /// The command buffer would not make a render command encoder.
    case noCommandEncoder
    /// A command buffer carrying this frame was committed with a drawable
    /// presented on it. The only outcome that puts pixels on a layer.
    case presented
    /// A command buffer was committed into a caller-owned render pass with
    /// no drawable: an offscreen texture, or a test.
    case committedOffscreen

    /// True when the GPU received this frame's draw calls.
    public var wasSubmitted: Bool {
        self == .presented || self == .committedOffscreen
    }

    /// True when the frame was planned but never reached any render target,
    /// so what is on screen is older than the state that was planned. A host
    /// that stops redrawing here leaves stale rows visible indefinitely.
    public var leavesStalePixels: Bool {
        switch self {
        case .noDrawable, .noCommandBuffer, .noCommandEncoder: return true
        case .notSubmitted, .presented, .committedOffscreen: return false
        }
    }
}

/// One row's worth of highlighted columns, inclusive on both ends.
public struct TerminalMetalSelectionSpan: Equatable, Sendable {
    public var row: Int
    public var firstColumn: Int
    public var lastColumn: Int

    public init(row: Int, firstColumn: Int, lastColumn: Int) {
        self.row = row
        self.firstColumn = firstColumn
        self.lastColumn = lastColumn
    }

    public var columnCount: Int { lastColumn - firstColumn + 1 }
}

/// What one planned frame turned into. Pure data: a test can assert on it
/// without a GPU, and a host can log it without reaching into the renderer.
public struct TerminalMetalFrameStatistics: Equatable, Sendable {
    public var validation: TerminalMetalFrameValidation = .valid
    /// Whether this frame's draw calls reached a render target, and if not,
    /// why. Planning alone leaves it `.notSubmitted`.
    public var presentation: TerminalMetalFramePresentation = .notSubmitted
    public var cols: Int = 0
    public var rows: Int = 0
    /// Cells the planner actually walked, which is `cols * rows` for a
    /// complete payload.
    public var visitedCells: Int = 0
    public var replannedRows: Int = 0
    public var replannedCells: Int = 0
    /// Packed bytes compared exactly before an advisory damage list was
    /// allowed to reuse a cached row. This makes the full-frame safety cost
    /// observable and bounded in tests.
    public var comparedPackedCellBytes: Int = 0
    public var backgroundInstances: Int = 0
    public var selectionInstances: Int = 0
    public var imageInstances: Int = 0
    public var glyphInstances: Int = 0
    public var colorGlyphInstances: Int = 0
    public var decorationInstances: Int = 0
    public var cursorInstances: Int = 0
    /// Cells whose character had no rasterizable mask (blank, unmapped, or
    /// an atlas page that would not pack).
    public var skippedGlyphs: Int = 0
    /// Placements dropped because the provider had no image, or the image
    /// was malformed.
    public var skippedPlacements: Int = 0
    public var atlasPageCount: Int = 0
    /// Bumped every time the atlas rasterizes a glyph it did not have, so a
    /// host knows when the atlas textures need re-uploading.
    public var atlasGeneration: Int = 0

    public init() {}

    /// True when the frame passed validation and may be drawn.
    public var isRenderable: Bool { validation == .valid }

    /// Total quads across every pass.
    public var totalInstances: Int {
        backgroundInstances + selectionInstances + imageInstances + glyphInstances
            + decorationInstances + cursorInstances
    }
}

/// Growth policy for the reusable instance buffers, split out so the reuse
/// decision can be tested without allocating a byte of GPU memory.
public enum TerminalMetalBufferSizing {
    /// Smallest buffer worth allocating; a frame of a few dozen quads should
    /// not allocate again next frame.
    public static let minimumLength = 4096

    /// The byte length a buffer must grow to, or `nil` when the existing one
    /// is already big enough (or nothing needs uploading at all).
    public static func growth(
        existingLength: Int,
        requiredLength: Int,
        minimumLength: Int = TerminalMetalBufferSizing.minimumLength
    ) -> Int? {
        guard requiredLength > 0 else { return nil }
        guard existingLength < requiredLength else { return nil }
        var length = max(minimumLength, max(existingLength, 1))
        while length < requiredLength {
            let (doubled, overflow) = length.multipliedReportingOverflow(by: 2)
            if overflow { return requiredLength }
            length = doubled
        }
        return length
    }
}

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

    public private(set) var viewport = TerminalMetalViewport(drawableWidth: 0, drawableHeight: 0)
    public private(set) var backgroundInstances: [TerminalMetalBackgroundInstance] = []
    public private(set) var selectionInstances: [TerminalMetalSelectionInstance] = []
    public private(set) var imageInstances: [TerminalMetalImageInstance] = []
    public private(set) var glyphInstances: [TerminalMetalGlyphInstance] = []
    public private(set) var colorGlyphInstances: [TerminalMetalGlyphInstance] = []
    public private(set) var decorationInstances: [TerminalMetalDecorationInstance] = []
    public private(set) var cursorInstances: [TerminalMetalCursorInstance] = []
    public private(set) var statistics = TerminalMetalFrameStatistics()

    private struct CachedRow {
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
        /// The row's clusters by column: the packed bytes carry only a
        /// cluster's first scalar, so a changed cluster is compared here.
        var graphemes: [Int: String]? = nil
    }

    private struct CacheState: Equatable {
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

    /// Selected columns by row, for the cell passes: only filled when the
    /// selection changes how cells are drawn (`selectionForeground`,
    /// `selectionInvertsColors`); an overlay alone leaves the rows cacheable.
    private var selectedColumnsByRow: [Int: ClosedRange<Int>] = [:]

    private var rowCache: [CachedRow] = []
    private var cacheState: CacheState?
    /// `renderFrame()` always carries the complete viewport, while its damage
    /// list can be drained by a delta consumer. Keep the prior payload so an
    /// advisory list cannot leave a stale cached row on screen.
    private var cachedPackedCells: Data?

    /// Atlas pages that gained a glyph since the last upload, and the
    /// generation counter that changed with them.
    public private(set) var dirtyAtlasPages: Set<Int> = []
    public private(set) var atlasGeneration: Int = 0

    /// Contiguous `glyphInstances` ranges sharing one atlas page, in draw
    /// order. One entry for the common single-page case.
    public private(set) var glyphPageRanges: [(page: Int, range: Range<Int>)] = []
    public private(set) var colorGlyphPageRanges: [(page: Int, range: Range<Int>)] = []

    /// CoreText lookups are per unique scalar, not per cell.
    private struct StyledScalar: Hashable { let scalar: UInt32; let traits: UInt8 }
    private struct ResolvedGlyph { let font: CTFont; let glyph: CGGlyph; let emboldened: Bool }
    private var resolvedGlyphs: [StyledScalar: ResolvedGlyph?] = [:]
    private var blockCursorCell: (row: Int, col: Int)?
    /// This frame's clusters by payload row, then column.
    private var frameGraphemes: [Int: [Int: String]] = [:]

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

    /// Passes with something to draw, in the order they must be drawn.
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

    /// Called by the renderer once the dirty pages have been uploaded.
    public func clearDirtyAtlasPages() {
        dirtyAtlasPages.removeAll(keepingCapacity: true)
    }

    /// Forget the cached rows and the packed payload they were derived from.
    ///
    /// The row cache is a claim about the screen: "these rows were planned
    /// for the frame the target already holds, so an identical row need not
    /// be planned again". A frame that was planned but never submitted with
    /// a drawable was never on any screen, so its cache is a claim about
    /// pixels that do not exist. The renderer calls this whenever a frame
    /// fails to present, which costs one full replan and keeps the invariant
    /// that a cached row is only ever reused against a state the GPU
    /// actually received.
    public func discardPlannedFrame() {
        rowCache.removeAll(keepingCapacity: true)
        cacheState = nil
        cachedPackedCells = nil
    }

    // MARK: - Validation

    /// Strict, total, and free of traps: every conversion is checked, so a
    /// hostile or truncated payload is a `Validation` case, not a crash.
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
        // The payload has to cover the overscan rows too, or the strip the
        // translation exposes would be planned from bytes that are not there.
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

    /// A terminal wider or taller than this is a corrupt payload, not a
    /// window anyone opened.
    public static let maximumGridDimension = 1 << 16
    /// 16 million cells is ~256 MB of packed payload; past that, refuse.
    public static let maximumCellCount = 1 << 24
    /// Mirrors the core's own `MAX_OVERSCAN_ROWS`. A sub-cell translation
    /// exposes less than one row, so more than this is a caller bug.
    public static let maximumOverscanRows = 2

    // MARK: - Planning

    /// Plan one frame.
    ///
    /// The frame arrives as a single `FfiRenderFrame`, and the snapshot and
    /// the packed cells are read from that one value -- never fetched
    /// separately, which is what would let the grid dimensions and the cell
    /// bytes come from two different terminal states.
    @discardableResult
    /// - Parameter overscanRows: rows of `frame.packedCells` beyond the
    ///   viewport, from `render_frame_overscan`. They are laid out below the
    ///   last viewport row so a vertical translation has cells to expose;
    ///   cursor, selection and reported geometry stay viewport-relative.
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

        // One value in, one value out: the snapshot and the cells below are
        // both fields of `frame`, so they always describe the same instant.
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

        // Cell passes cover the viewport plus the overscan strip; everything
        // that is addressed in viewport coordinates keeps the viewport's own
        // row count, so an extra row below cannot move the cursor or a
        // selection.
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
            // The overscan strip is part of the picture, so a placement that
            // lands on it is drawn there. Bounding this at the viewport
            // instead would drop the image out of the strip while its cells
            // were drawn, and the image would appear to pop in on the row
            // boundary rather than slide in with everything else.
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

    private func planCellPasses(
        _ cells: TerminalFrame,
        snapshot: FfiSnapshot,
        into stats: inout TerminalMetalFrameStatistics
    ) {
        let currentState = CacheState(
            cols: cells.cols,
            rows: cells.rows,
            drawableWidth: viewport.drawableWidth,
            drawableHeight: viewport.drawableHeight,
            colorEncoding: colorEncoding,
            colorSpace: colorSpace,
            minimumContrast: minimumContrast,
            isFocused: isFocused,
            palette: palette,
            viewportOffset: snapshot.viewportOffset,
            alternateScreen: snapshot.modes.alternateScreen,
            margins: margins,
            cellColorsAreDisplayP3: cellColorsAreDisplayP3
        )

        let isFullInvalidation = cacheState != currentState || rowCache.count != cells.rows
        if isFullInvalidation {
            rowCache = Array(repeating: CachedRow(), count: cells.rows)
            cacheState = currentState
            cachedPackedCells = nil
        }

        var rowsToReplanSet = Set<Int>()
        if isFullInvalidation {
            rowsToReplanSet = Set(0..<cells.rows)
        } else {
            rowsToReplanSet.reserveCapacity(cells.rows)
            for row in snapshot.damagedRows {
                let index = Int(row)
                if index >= 0 && index < cells.rows {
                    rowsToReplanSet.insert(index)
                }
            }
            let bytesPerRow = cells.cols * TerminalCell.byteSize
            for row in 0..<cells.rows {
                if rowsToReplanSet.contains(row) { continue }
                let cached = rowCache[row]
                if !cached.isPopulated {
                    rowsToReplanSet.insert(row)
                    continue
                }
                let currentBlockCursorCol = (blockCursorCell?.row == row) ? blockCursorCell?.col : nil
                if cached.blockCursorCol != currentBlockCursorCol
                    || cached.selectedColumns != selectedColumnsByRow[row] {
                    rowsToReplanSet.insert(row)
                    continue
                }
                if cached.graphemes != frameGraphemes[row] {
                    rowsToReplanSet.insert(row)
                    continue
                }
                // `damagedRows` is advisory for a full frame: a concurrent
                // delta consumer may have drained a changed row. Compare the
                // complete packed row exactly (rather than a collision-prone
                // hash) before reusing its draw instances.
                stats.comparedPackedCellBytes += bytesPerRow
                if let cachedRowData = cached.packedRowData {
                    if !cells.rowMatches(cachedRowData, row: row) {
                        rowsToReplanSet.insert(row)
                        continue
                    }
                } else if cachedPackedCells.map({ cells.rowMatches($0, row: row) }) != true {
                    rowsToReplanSet.insert(row)
                    continue
                }
            }
        }
        let rowsToReplan = rowsToReplanSet.sorted()
        let replannedRows = rowsToReplan.count

        let cellWidth = metrics.pixelCellWidth
        let cellHeight = metrics.pixelCellHeight
        let defaultBackground = TerminalMetalColor.premultiplied(palette.background)
        var replannedCells = 0

        let margins = self.margins
        let lastCol = cells.cols - 1
        for row in rowsToReplan {
            var currentRow = -1
            var cachedRow = CachedRow()
            let rowGraphemes = frameGraphemes[row]
            var runColor = SIMD4<Float>(repeating: 0)
            var runStart = 0
            var runLength = 0
            let selected = selectedColumnsByRow[row]

            func flushRun() {
                guard runLength > 0 else { return }
                cachedRow.backgroundInstances.append(TerminalMetalBackgroundInstance(
                    x: Float(runStart) * cellWidth,
                    y: Float(currentRow) * cellHeight,
                    width: Float(runLength) * cellWidth,
                    height: cellHeight,
                    color: runColor
                ))
                runLength = 0
            }

            cells.forEachCell(
                inRows: row..<row + 1,
                inColumns: 0..<cells.cols,
                { _, col, cell in
                    currentRow = row
                    cachedRow.visitedCells += 1
                    replannedCells += 1

                    var straightBackground = self.backgroundColor(of: cell)
                    var glyphColor: SIMD4<Float>?
                    if let selected, selected.contains(col) {
                        if self.palette.selectionInvertsColors {
                            glyphColor = straightBackground
                            straightBackground = self.plainForegroundColor(of: cell)
                        } else {
                            glyphColor = self.palette.selectionForeground
                        }
                    }
                    let background = TerminalMetalColor.premultiplied(straightBackground)
                    // The left and right margins take the edge cells' colour.
                    if margins.fill != .background, col == 0 || col == lastCol, background != defaultBackground {
                        let x = col == 0 ? -margins.left : Float(cells.cols) * cellWidth
                        let width = col == 0 ? margins.left : margins.right
                        if width > 0 {
                            cachedRow.backgroundInstances.append(TerminalMetalBackgroundInstance(
                                x: x, y: Float(row) * cellHeight, width: width, height: cellHeight, color: background
                            ))
                        }
                    }
                    if background == defaultBackground {
                        flushRun()
                    } else if runLength > 0, col == runStart + runLength, background == runColor {
                        runLength += 1
                    } else {
                        flushRun()
                        runColor = background
                        runStart = col
                        runLength = 1
                    }

                    // Only a cell marked as holding a cluster looks one up.
                    let cluster = cell.hasGrapheme ? rowGraphemes?[col] : nil
                    if !self.appendGlyph(
                        for: cell, cluster: cluster, row: row, col: col, color: glyphColor, into: &cachedRow
                    ) {
                        cachedRow.skippedGlyphs += 1
                    }
                    self.appendDecorations(for: cell, row: row, col: col, into: &cachedRow)
                }
            )
            if currentRow != -1 {
                flushRun()
                cachedRow.blockCursorCol = (blockCursorCell?.row == row) ? blockCursorCell?.col : nil
                cachedRow.selectedColumns = selected
                cachedRow.packedRowData = cells.rowData(for: row)
                cachedRow.graphemes = rowGraphemes
                cachedRow.isPopulated = true
                rowCache[row] = cachedRow
            }
        }

        var visited = 0
        var skippedGlyphs = 0

        for row in 0..<cells.rows {
            let cached = rowCache[row]
            backgroundInstances.append(contentsOf: cached.backgroundInstances)
            glyphInstances.append(contentsOf: cached.glyphInstances)
            colorGlyphInstances.append(contentsOf: cached.colorGlyphInstances)
            decorationInstances.append(contentsOf: cached.decorationInstances)
            visited += cached.visitedCells
            skippedGlyphs += cached.skippedGlyphs
        }

        stats.visitedCells = visited
        stats.skippedGlyphs = skippedGlyphs
        stats.replannedRows = replannedRows
        stats.replannedCells = replannedCells
        cachedPackedCells = cells.packedData
    }

    /// Returns false when the cell contributed no glyph quad. `cluster` is
    /// the cell's whole grapheme cluster, drawn in place of `ch`; `color`,
    /// when given, replaces the cell's own foreground (a selection colour),
    /// with dimming and focus still applied to it.
    private func appendGlyph(
        for cell: TerminalCell,
        cluster: String? = nil,
        row: Int,
        col: Int,
        color override: SIMD4<Float>? = nil,
        into cachedRow: inout CachedRow
    ) -> Bool {
        // 0 is the tail of a double-width pair, 32 is a space: neither has a
        // mask, and a hidden cell must not show one.
        guard cell.ch != 0, !cell.hidden else { return false }
        guard cell.ch != 32 || cluster != nil else { return false }
        let before = atlas.generation
        let entry: GlyphAtlasEntry
        if let cluster {
            let face = baseFace(bold: cell.bold, italic: cell.italic)
            entry = atlas.clusterEntry(for: cluster, font: face.font, scale: metrics.scale, emboldened: face.synthetic)
        } else {
            guard let resolved = resolveGlyph(for: cell.ch, bold: cell.bold, italic: cell.italic) else { return false }
            entry = atlas.glyphEntry(
                for: resolved.glyph, font: resolved.font, scale: metrics.scale, emboldened: resolved.emboldened
            )
        }
        if atlas.generation != before, entry.isRasterized {
            atlasGeneration = Int(truncatingIfNeeded: atlas.generation)
            dirtyAtlasPages.insert(entry.pageIndex)
        }
        guard entry.isRasterized, entry.pixelWidth > 0, entry.pixelHeight > 0 else { return false }

        let scale = Float(metrics.scale)
        let originX = Float(col) * metrics.pixelCellWidth
        let baselineY = Float(row) * metrics.pixelCellHeight + metrics.pixelAscent
        let spanWidth = metrics.pixelCellWidth * (cell.wide ? 2 : 1)
        let advance = Float(entry.advance.width) * scale
        let centering = max(0, (spanWidth - advance) / 2)
        let left = originX + centering + Float(entry.bearing.x) * scale
        // `bearing.y` is the mask's lowest point relative to the baseline, so
        // the top edge sits a full mask height above it.
        let top = baselineY - Float(entry.bearing.y) * scale - Float(entry.pixelHeight)

        var alpha: Float = cell.dim ? palette.dimAlpha : 1
        if !isFocused { alpha *= palette.unfocusedTextAlpha }
        let overBlockCursor = blockCursorCell?.row == row && blockCursorCell?.col == col
        let straightColor: SIMD4<Float>
        if entry.pixelFormat == .bgra8Premultiplied {
            straightColor = SIMD4<Float>(1, 1, 1, alpha)
        } else if overBlockCursor {
            straightColor = TerminalMetalColor.enforcingMinimumContrast(
                foreground: SIMD4<Float>(palette.background.x, palette.background.y, palette.background.z, alpha),
                background: palette.cursor,
                ratio: max(minimumContrast, 3),
                encoding: colorEncoding,
                colorSpace: colorSpace
            )
        } else if let override {
            straightColor = SIMD4<Float>(override.x, override.y, override.z, override.w * alpha)
        } else {
            straightColor = foregroundColor(of: cell, alpha: alpha)
        }
        let color = TerminalMetalColor.premultiplied(straightColor)

        var flags: UInt32 = 0
        if cell.bold { flags |= 1 << 0 }
        if cell.italic { flags |= 1 << 1 }
        if cell.wide { flags |= 1 << 2 }
        if entry.pixelFormat == .bgra8Premultiplied { flags |= TerminalMetalGlyphInstance.colorGlyphFlag }

        let instance = TerminalMetalGlyphInstance(
            x: left,
            y: top,
            width: Float(entry.pixelWidth),
            height: Float(entry.pixelHeight),
            uvRect: SIMD4<Float>(
                Float(entry.uvRect.minX),
                Float(entry.uvRect.minY),
                Float(entry.uvRect.maxX),
                Float(entry.uvRect.maxY)
            ),
            color: color,
            atlasPage: UInt32(truncatingIfNeeded: entry.pageIndex),
            flags: flags
        )
        if entry.pixelFormat == .bgra8Premultiplied {
            cachedRow.colorGlyphInstances.append(instance)
        } else {
            cachedRow.glyphInstances.append(instance)
        }
        return true
    }

    /// A draw binds one atlas page, so instances are grouped by page. Almost
    /// every frame has exactly one page and skips the sort entirely.
    private func finishGlyphPass() {
        groupGlyphs(&glyphInstances, into: &glyphPageRanges)
        groupGlyphs(&colorGlyphInstances, into: &colorGlyphPageRanges)
    }

    private func groupGlyphs(
        _ instances: inout [TerminalMetalGlyphInstance],
        into ranges: inout [(page: Int, range: Range<Int>)]
    ) {
        guard !instances.isEmpty else { return }
        let firstPage = instances[0].atlasPage
        if instances.contains(where: { $0.atlasPage != firstPage }) {
            instances.sort { $0.atlasPage < $1.atlasPage }
        }
        var start = 0
        var page = instances[0].atlasPage
        for index in 1..<instances.count where instances[index].atlasPage != page {
            ranges.append((page: Int(page), range: start..<index))
            start = index
            page = instances[index].atlasPage
        }
        ranges.append((page: Int(page), range: start..<instances.count))
    }

    /// Resolves symbolic style first, then CoreText fallback for the scalar.
    public func resolvedFontName(for scalar: UInt32, bold: Bool = false, italic: Bool = false) -> String? {
        guard let resolved = resolveGlyph(for: scalar, bold: bold, italic: italic) else { return nil }
        return CTFontCopyPostScriptName(resolved.font) as String
    }

    private func resolveGlyph(for scalar: UInt32, bold: Bool, italic: Bool) -> ResolvedGlyph? {
        let traits = UInt8(bold ? 1 : 0) | UInt8(italic ? 2 : 0)
        let key = StyledScalar(scalar: scalar, traits: traits)
        if let cached = resolvedGlyphs[key] { return cached }
        guard let unicodeScalar = UnicodeScalar(scalar) else { return nil }
        let string = String(unicodeScalar)
        let (base, synthetic) = baseFace(bold: bold, italic: italic)
        var result = metrics.shapesGlyphs ? Self.shapedGlyph(string, font: base) : nil
        if result == nil {
            let utf16 = Array(string.utf16)
            let fallback = CTFontCreateForString(base, string as CFString, CFRange(location: 0, length: utf16.count))
            var glyphs = [CGGlyph](repeating: 0, count: max(utf16.count, 1))
            let ok = CTFontGetGlyphsForCharacters(fallback, utf16, &glyphs, utf16.count)
            result = ok && glyphs.first != 0 ? (fallback, glyphs[0]) : nil
        }
        // Only the face that lacks the weight is thickened, not a fallback.
        let resolved = result.map { found in
            ResolvedGlyph(
                font: found.0,
                glyph: found.1,
                emboldened: synthetic && CTFontCopyPostScriptName(found.0) == CTFontCopyPostScriptName(base)
            )
        }
        resolvedGlyphs[key] = resolved
        return resolved
    }

    /// The face for a style, and whether it is a synthesised bold.
    private func baseFace(bold: Bool, italic: Bool) -> (font: CTFont, synthetic: Bool) {
        switch (bold, italic) {
        case (true, true):
            return (metrics.boldItalicFont ?? metrics.boldFont ?? metrics.italicFont ?? metrics.font,
                    metrics.boldItalicIsSynthetic)
        case (true, false):
            return (metrics.boldFont ?? metrics.font, metrics.boldIsSynthetic)
        case (false, true):
            return (metrics.italicFont ?? metrics.font, false)
        case (false, false):
            return (metrics.font, false)
        }
    }

    /// The glyph CoreText's shaper picks for `string`, which is where the
    /// font's feature settings (`ss01`, `zero`) take effect.
    private static func shapedGlyph(_ string: String, font: CTFont) -> (CTFont, CGGlyph)? {
        let attributed = CFAttributedStringCreate(
            kCFAllocatorDefault, string as CFString, [kCTFontAttributeName: font] as CFDictionary
        )!
        let line = CTLineCreateWithAttributedString(attributed)
        guard let run = (CTLineGetGlyphRuns(line) as? [CTRun])?.first, CTRunGetGlyphCount(run) > 0 else {
            return nil
        }
        var glyph: CGGlyph = 0
        CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard glyph != 0, let runFont = attributes[kCTFontAttributeName] else { return nil }
        return (runFont as! CTFont, glyph)
    }

    private func appendDecorations(for cell: TerminalCell, row: Int, col: Int, into cachedRow: inout CachedRow) {
        guard !cell.hidden else { return }
        let hasUnderline = cell.underline || cell.underlineStyle > 0
        guard hasUnderline || cell.strikethrough || cell.overline else { return }
        let scale = Float(metrics.scale)
        let thickness = max(1, scale.rounded())
        let x = Float(col) * metrics.pixelCellWidth
        let y = Float(row) * metrics.pixelCellHeight
        let width = metrics.pixelCellWidth * (cell.wide ? 2 : 1)
        var alpha: Float = cell.dim ? palette.dimAlpha : 1
        if !isFocused { alpha *= palette.unfocusedTextAlpha }
        let background = backgroundColor(of: cell)
        let foreground = foregroundColor(of: cell, alpha: alpha)

        func color(_ raw: SIMD4<Float>) -> SIMD4<Float> {
            TerminalMetalColor.premultiplied(TerminalMetalColor.enforcingMinimumContrast(
                foreground: raw,
                background: background,
                ratio: minimumContrast,
                encoding: colorEncoding,
                colorSpace: colorSpace
            ))
        }
        func append(
            _ style: TerminalMetalDecorationStyle,
            top: Float,
            height: Float,
            lineThickness: Float? = nil,
            color value: SIMD4<Float>
        ) {
            cachedRow.decorationInstances.append(TerminalMetalDecorationInstance(
                rect: SIMD4<Float>(x, top, width, height),
                color: color(value),
                style: style,
                thickness: lineThickness ?? thickness
            ))
        }
        if hasUnderline {
            let style = TerminalMetalDecorationStyle(rawValue: UInt32(max(cell.underlineStyle, 1))) ?? .singleUnderline
            let lineThickness = max(1, Float(metrics.underlineThickness * metrics.scale).rounded())
            let height: Float = style == .doubleUnderline || style == .curlyUnderline ? 4 * lineThickness : lineThickness
            let underline = TerminalMetalColor.rgba(
                r: cell.ulR, g: cell.ulG, b: cell.ulB, alpha: alpha,
                encoding: colorEncoding, colorSpace: colorSpace
            )
            let position = Float(metrics.underlinePosition * metrics.scale).rounded()
            append(style, top: min(y + metrics.pixelCellHeight - height, y + position), height: height,
                   lineThickness: lineThickness, color: underline)
        }
        if cell.strikethrough {
            append(.strikethrough, top: y + (metrics.pixelCellHeight - thickness) / 2, height: thickness, color: foreground)
        }
        if cell.overline {
            append(.overline, top: y, height: thickness, color: foreground)
        }
    }

    // MARK: - Selection

    /// The highlighted columns per row: full rows between the endpoints and
    /// partial rows at each end for a linear selection, a column box for a
    /// rectangular one. Endpoints are normalized and clamped to the grid, so
    /// a stale or reversed range cannot address a cell that is not there.
    public static func selectionSpans(
        for selection: FfiSelectionRange,
        cols: Int,
        rows: Int
    ) -> [TerminalMetalSelectionSpan] {
        guard cols > 0, rows > 0 else { return [] }
        let startRow = Int(selection.startRow)
        let endRow = Int(selection.endRow)
        let startCol = Int(selection.startCol)
        let endCol = Int(selection.endCol)

        // Reading order: the earlier row wins, and within one row the
        // smaller column.
        let reversed = (endRow, endCol) < (startRow, startCol)
        let firstRow = reversed ? endRow : startRow
        let firstCol = reversed ? endCol : startCol
        let lastRow = reversed ? startRow : endRow
        let lastCol = reversed ? startCol : endCol

        let clampedFirstRow = max(firstRow, 0)
        let clampedLastRow = min(lastRow, rows - 1)
        guard clampedFirstRow <= clampedLastRow else { return [] }

        var spans: [TerminalMetalSelectionSpan] = []
        spans.reserveCapacity(clampedLastRow - clampedFirstRow + 1)
        for row in clampedFirstRow...clampedLastRow {
            var first: Int
            var last: Int
            switch selection.mode {
            case .linear:
                first = row == firstRow ? firstCol : 0
                last = row == lastRow ? lastCol : cols - 1
            case .rectangular:
                first = min(firstCol, lastCol)
                last = max(firstCol, lastCol)
            }
            first = max(first, 0)
            last = min(last, cols - 1)
            guard first <= last else { continue }
            spans.append(TerminalMetalSelectionSpan(row: row, firstColumn: first, lastColumn: last))
        }
        return spans
    }

    private func planSelection(
        _ selection: FfiSelectionRange,
        cols: Int,
        rows: Int
    ) {
        let color = TerminalMetalColor.premultiplied(palette.selection)
        for span in Self.selectionSpans(for: selection, cols: cols, rows: rows) {
            selectionInstances.append(TerminalMetalSelectionInstance(
                x: Float(span.firstColumn) * metrics.pixelCellWidth,
                y: Float(span.row) * metrics.pixelCellHeight,
                width: Float(span.columnCount) * metrics.pixelCellWidth,
                height: metrics.pixelCellHeight,
                color: color
            ))
        }
    }

    // MARK: - Kitty graphics

    private func planImages(
        _ placements: [FfiGraphicsPlacement],
        cols: Int,
        rows: Int,
        provider: (UInt32) -> FfiStoredImage?,
        metadataProvider: (UInt32) -> FfiGraphicsImageMetadata?,
        into stats: inout TerminalMetalFrameStatistics
    ) {
        guard !placements.isEmpty else { return }
        imageInstances.reserveCapacity(placements.count)
        var skipped = 0
        var metadataByImageId: [UInt32: FfiGraphicsImageMetadata] = [:]
        var missingImageIds = Set<UInt32>()
        for placement in placements {
            guard let row = Int(exactly: placement.row), let col = Int(exactly: placement.col),
                  row >= 0, row < rows, col >= 0, col < cols else {
                skipped += 1
                continue
            }
            // Production callers provide metadata from core without copying
            // the image payload. Keep the full-image provider as a backwards
            // compatible fallback for hosts that have not adopted it yet.
            let metadata: FfiGraphicsImageMetadata? = {
                if let cached = metadataByImageId[placement.imageId] { return cached }
                if missingImageIds.contains(placement.imageId) { return nil }
                let resolved: FfiGraphicsImageMetadata?
                if let value = metadataProvider(placement.imageId) {
                    resolved = value
                } else if let stored = provider(placement.imageId) {
                    resolved = FfiGraphicsImageMetadata(
                        format: stored.format,
                        width: stored.width,
                        height: stored.height,
                        generation: 0
                    )
                } else {
                    resolved = nil
                }
                if let resolved {
                    metadataByImageId[placement.imageId] = resolved
                } else {
                    missingImageIds.insert(placement.imageId)
                }
                return resolved
            }()
            guard let metadata,
                  metadata.width > 0, metadata.height > 0,
                  let width = Int(exactly: metadata.width), let height = Int(exactly: metadata.height) else {
                skipped += 1
                continue
            }
            // A placement anchors the image's top-left at the cell's
            // top-left; the image keeps its own pixel size.
            imageInstances.append(TerminalMetalImageInstance(
                x: Float(col) * metrics.pixelCellWidth,
                y: Float(row) * metrics.pixelCellHeight,
                width: Float(width),
                height: Float(height),
                imageId: placement.imageId
            ))
        }
        stats.skippedPlacements = skipped
    }

    // MARK: - Cursor

    private func planCursor(
        _ snapshot: FfiSnapshot,
        cols: Int,
        rows: Int
    ) {
        guard snapshot.cursorVisible else { return }
        // Scrollback is a historical viewport, never the live cursor. An
        // unfocused pane keeps its outline visible even while its blink timer
        // is in the off phase, matching Tako's inactive-pane behaviour.
        guard snapshot.viewportOffset == 0 else { return }
        guard !snapshot.cursorStyle.blinking || !isFocused || cursorBlinkPhaseOn else { return }
        guard let row = Int(exactly: snapshot.cursorRow), let col = Int(exactly: snapshot.cursorCol),
              row >= 0, row < rows, col >= 0, col < cols else { return }

        let x = Float(col) * metrics.pixelCellWidth
        let y = Float(row) * metrics.pixelCellHeight
        let width = metrics.pixelCellWidth
        let height = metrics.pixelCellHeight
        let thickness = cursorThickness.map { max(1, Float($0) * Float(metrics.scale)) }
            ?? max(1, (2 * Float(metrics.scale)).rounded())
        let color = TerminalMetalColor.premultiplied(palette.cursor)
        let blink: UInt32 = snapshot.cursorStyle.blinking ? 1 : 0

        func append(_ rect: SIMD4<Float>, _ shape: TerminalMetalCursorShape) {
            cursorInstances.append(TerminalMetalCursorInstance(
                rect: rect,
                shape: shape,
                blinkState: blink,
                color: color
            ))
        }

        switch snapshot.cursorStyle.shape {
        case .block:
            guard isFocused else {
                // An unfocused pane outlines its cursor instead of filling
                // it. The fragment stage has no per-instance state, so the
                // outline is four edge quads rather than a shader branch.
                append(SIMD4<Float>(x, y, width, thickness), .hollowBlock)
                append(SIMD4<Float>(x, y + height - thickness, width, thickness), .hollowBlock)
                append(SIMD4<Float>(x, y + thickness, thickness, height - 2 * thickness), .hollowBlock)
                append(
                    SIMD4<Float>(x + width - thickness, y + thickness, thickness, height - 2 * thickness),
                    .hollowBlock
                )
                return
            }
            blockCursorCell = (row, col)
            append(SIMD4<Float>(x, y, width, height), .block)
        case .underline:
            append(SIMD4<Float>(x, y + height - thickness, width, thickness), .underline)
        case .bar:
            append(SIMD4<Float>(x, y, thickness, height), .bar)
        }
    }

    // MARK: - Margins

    /// The strips above and below the grid, per column, when
    /// `window-padding-color` extends the edge rows. The side strips are
    /// planned with their rows, which cache them.
    private func planMargins(_ cells: TerminalFrame, snapshot: FfiSnapshot, rows: Int) {
        guard margins.fill != .background, cells.cols > 0, rows > 0 else { return }
        let cellWidth = metrics.pixelCellWidth
        let cellHeight = metrics.pixelCellHeight
        let defaultBackground = TerminalMetalColor.premultiplied(palette.background)
        for (row, y, height) in [(0, -margins.top, margins.top), (rows - 1, Float(rows) * cellHeight, margins.bottom)]
        where height > 0 {
            var colors: [SIMD4<Float>] = []
            colors.reserveCapacity(cells.cols)
            cells.forEachCell(inRows: row..<row + 1, inColumns: 0..<cells.cols) { _, _, cell in
                colors.append(TerminalMetalColor.premultiplied(self.backgroundColor(of: cell)))
            }
            if margins.fill == .extend, !snapshot.modes.alternateScreen,
               colors.contains(defaultBackground) {
                continue
            }
            for (col, color) in colors.enumerated() where color != defaultBackground {
                backgroundInstances.append(TerminalMetalBackgroundInstance(
                    x: Float(col) * cellWidth, y: y, width: cellWidth, height: height, color: color
                ))
            }
        }
    }

    // MARK: - Cell colors

    /// The space the cell colours are converted from: a P3 target shows sRGB
    /// values converted, or -- with `cellColorsAreDisplayP3` -- takes the
    /// values as its own.
    private var cellColorConversion: TerminalMetalColorSpace {
        cellColorsAreDisplayP3 ? .sRGB : colorSpace
    }

    /// SGR 7 swaps the pair, so reverse video is resolved once, here.
    public func backgroundColor(of cell: TerminalCell) -> SIMD4<Float> {
        let (r, g, b) = cell.reverse
            ? (cell.fgR, cell.fgG, cell.fgB)
            : (cell.bgR, cell.bgG, cell.bgB)
        return TerminalMetalColor.rgba(r: r, g: g, b: b, encoding: colorEncoding, colorSpace: cellColorConversion)
    }

    /// The cell's foreground as the terminal set it, before any contrast
    /// adjustment -- what an inverted selection paints the cell with.
    func plainForegroundColor(of cell: TerminalCell) -> SIMD4<Float> {
        let (r, g, b) = cell.reverse
            ? (cell.bgR, cell.bgG, cell.bgB)
            : (cell.fgR, cell.fgG, cell.fgB)
        return TerminalMetalColor.rgba(r: r, g: g, b: b, encoding: colorEncoding, colorSpace: cellColorConversion)
    }

    public func foregroundColor(of cell: TerminalCell, alpha: Float = 1) -> SIMD4<Float> {
        let (r, g, b) = cell.reverse
            ? (cell.bgR, cell.bgG, cell.bgB)
            : (cell.fgR, cell.fgG, cell.fgB)
        let foreground = TerminalMetalColor.rgba(
            r: r, g: g, b: b, alpha: alpha,
            encoding: colorEncoding, colorSpace: cellColorConversion
        )
        return TerminalMetalColor.enforcingMinimumContrast(
            foreground: foreground,
            background: backgroundColor(of: cell),
            ratio: minimumContrast,
            encoding: colorEncoding,
            colorSpace: colorSpace
        )
    }
}

/// Everything that can go wrong while standing the renderer up. All of it is
/// thrown, never trapped: a host without a GPU, without the shader library or
/// without memory gets an error it can show.
public enum MetalTerminalRendererError: Error, Equatable {
    case defaultLibraryUnavailable
    case commandQueueUnavailable
    case missingShaderFunction(String)
    case pipelineCreationFailed(pass: String, message: String)
    case samplerCreationFailed
    case bufferAllocationFailed(length: Int)
}

/// Draws a terminal frame into a `CAMetalLayer` with Metal.
///
/// The device and the shader library are injected, so the same renderer
/// serves a macOS window, an iOS view, and an offscreen texture in a test.
/// Nothing here imports AppKit or UIKit.
public final class MetalTerminalRenderer {
    /// Backgrounds first, then selection and Kitty images; cursor geometry is
    /// below text/decorations so block cursors retain a legible cell glyph.
    public static let passOrder: [TerminalMetalRenderPass] = TerminalMetalRenderPass.orderedWithImages

    /// Triple buffering: the CPU may be assembling frame N+2's instances
    /// while the GPU still reads frame N's, so each frame in flight gets its
    /// own set of buffers and a semaphore keeps the CPU from lapping it.
    public static let framesInFlight = 3

    public let device: MTLDevice
    public let library: MTLLibrary
    public let planner: TerminalMetalFramePlanner
    public let colorPixelFormat: MTLPixelFormat
    /// Resolves a Kitty image id to the stored image the engine decoded.
    public var imageProvider: (UInt32) -> FfiStoredImage?
    /// Resolves an image's cheap identity and geometry without copying bytes.
    public var imageMetadataProvider: (UInt32) -> FfiGraphicsImageMetadata?

    /// Statistics for the most recently planned frame.
    public private(set) var statistics = TerminalMetalFrameStatistics()
    /// How many MTLBuffers have been allocated over the renderer's life. It
    /// stops climbing once the buffers are big enough, which is the whole
    /// point of the ring.
    public var bufferAllocationCount: Int {
        backgroundRing.allocations + selectionRing.allocations
            + imageRing.allocations + glyphRing.allocations + colorGlyphRing.allocations
            + decorationRing.allocations + cursorRing.allocations
    }

    private let commandQueue: MTLCommandQueue
    private let backgroundPipeline: MTLRenderPipelineState
    private let selectionPipeline: MTLRenderPipelineState
    private let imagePipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState
    private let colorGlyphPipeline: MTLRenderPipelineState
    private let decorationPipeline: MTLRenderPipelineState
    private let cursorPipeline: MTLRenderPipelineState
    private let quadIndexBuffer: MTLBuffer
    private let glyphSampler: MTLSamplerState
    private let imageSampler: MTLSamplerState

    private let backgroundRing: InstanceRing
    private let selectionRing: InstanceRing
    private let imageRing: InstanceRing
    private let glyphRing: InstanceRing
    private let colorGlyphRing: InstanceRing
    private let decorationRing: InstanceRing
    private let cursorRing: InstanceRing

    private let inFlight = DispatchSemaphore(value: MetalTerminalRenderer.framesInFlight)
    private var slot = 0

    private let imageCache: MetalImageCache
    private var atlasTextures: [MTLTexture?] = []
    private var atlasTextureGenerations: [UInt64] = []
    public private(set) var atlasUploadCount: Int = 0
    private var resolvedImageTextures: [UInt32: MTLTexture] = [:]
    private var resolvedImageMetadata: [UInt32: FfiGraphicsImageMetadata] = [:]
    /// Direct metadata lookups are shared by planning and texture resolution,
    /// so each live image id crosses the FFI boundary at most once per frame.
    private var frameImageMetadata: [UInt32: FfiGraphicsImageMetadata] = [:]
    private var frameImageIdsWithoutMetadata = Set<UInt32>()

    /// Internal inspection hook for renderer tests; retaining a returned
    /// texture also makes copy-on-write replacement directly observable.
    var atlasTexturesForTesting: [MTLTexture?] { atlasTextures }

    /// Where a layer-backed frame gets its drawable.
    ///
    /// Production reads `layer.nextDrawable()`, which returns nil once the
    /// pool is drained -- which is precisely the condition this renderer has
    /// to survive, because a burst of full-screen updates drains it. A
    /// `CAMetalLayer` with no screen behind it, which is all a Simulator test
    /// process can build, keeps vending drawables forever and so cannot
    /// produce that condition on its own. Tests substitute the refusal here
    /// rather than assert on something the host will never do.
    var nextDrawableProvider: (CAMetalLayer) -> CAMetalDrawable? = { $0.nextDrawable() }

    /// The pixels a layer-backed frame actually committed, and the frame they
    /// came from.
    ///
    /// A render of the same terminal state through a second renderer proves
    /// what the screen *should* look like; it says nothing about what is on
    /// it. This is the only way to read back what a host's own presentation
    /// path put into a drawable: the blit is encoded into that frame's own
    /// command buffer, ahead of the present, so the bytes handed over are the
    /// ones the drawable carried to the compositor.
    ///
    /// Nil in production, where the whole thing costs one optional test. When
    /// it is set the frame is waited on, and the layer must have been left
    /// blit-readable (`framebufferOnly = false`), which only a test does.
    var committedFrameCaptureForTesting: ((FfiRenderFrame, [UInt8]) -> Void)?

    /// `custom-shader` passes, applied in order to every frame. Empty when
    /// none are configured or any of them failed; see `customShaderErrors`.
    public private(set) var customShaders: [TerminalCustomShader] = []
    /// Why the configured custom shaders are not applied, one entry per
    /// failure. Empty while they run or when none are configured.
    public private(set) var customShaderErrors: [String] = []
    /// Seconds on a monotonic clock; drives `iTime` and `iTimeDelta`.
    var customShaderClock: () -> CFTimeInterval = { CACurrentMediaTime() }
    /// Uniforms of the most recent shaded frame.
    private(set) var customShaderUniforms = TerminalCustomShaderUniforms()
    private var customShaderStartTime: CFTimeInterval = 0
    private var customShaderLastFrameTime: CFTimeInterval?
    private var customShaderTargets: [MTLTexture] = []

    /// Two triangles over the four corners the vertex shaders derive from
    /// `vertex_id`; every pass draws the same quad, instanced.
    private static let quadIndices: [UInt16] = [0, 1, 2, 0, 2, 3]

    public init(
        device: MTLDevice,
        library: MTLLibrary,
        metrics: TerminalMetalCellMetrics,
        palette: TerminalMetalPalette? = nil,
        colorEncoding: TerminalMetalColorEncoding = .displayEncoded,
        colorSpace: TerminalMetalColorSpace = .sRGB,
        minimumContrast: Float = 1,
        colorPixelFormat: MTLPixelFormat = .bgra8Unorm,
        atlas: GlyphAtlas = GlyphAtlas(),
        presentationClock: TerminalPresentationClock = TerminalPresentationClock(),
        imageProvider: @escaping (UInt32) -> FfiStoredImage? = { _ in nil },
        imageMetadataProvider: @escaping (UInt32) -> FfiGraphicsImageMetadata? = { _ in nil }
    ) throws {
        self.presentationClock = presentationClock
        self.device = device
        self.library = library
        self.colorPixelFormat = colorPixelFormat
        self.imageProvider = imageProvider
        self.imageMetadataProvider = imageMetadataProvider
        self.planner = TerminalMetalFramePlanner(
            metrics: metrics,
            atlas: atlas,
            palette: palette,
            colorEncoding: colorEncoding,
            colorSpace: colorSpace,
            minimumContrast: minimumContrast
        )
        self.imageCache = MetalImageCache(device: device)

        guard let queue = device.makeCommandQueue() else {
            throw MetalTerminalRendererError.commandQueueUnavailable
        }
        queue.label = "TakoCoreUI.MetalTerminalRenderer"
        self.commandQueue = queue

        self.backgroundPipeline = try Self.makePipeline(
            device: device,
            library: library,
            pass: "background",
            vertex: "terminalBackgroundVertex",
            fragment: "terminalBackgroundFragment",
            pixelFormat: colorPixelFormat
        )
        self.selectionPipeline = try Self.makePipeline(
            device: device,
            library: library,
            pass: "selection",
            vertex: "terminalSelectionVertex",
            fragment: "terminalSelectionFragment",
            pixelFormat: colorPixelFormat
        )
        self.imagePipeline = try Self.makePipeline(
            device: device,
            library: library,
            pass: "kittyImage",
            vertex: "terminalImageVertex",
            fragment: "terminalImageFragment",
            pixelFormat: colorPixelFormat
        )
        self.glyphPipeline = try Self.makePipeline(
            device: device,
            library: library,
            pass: "grayscaleGlyph",
            vertex: "terminalGrayscaleGlyphVertex",
            fragment: "terminalGrayscaleGlyphFragment",
            pixelFormat: colorPixelFormat
        )
        self.colorGlyphPipeline = try Self.makePipeline(
            device: device,
            library: library,
            pass: "colorGlyph",
            vertex: "terminalGrayscaleGlyphVertex",
            fragment: "terminalColorGlyphFragment",
            pixelFormat: colorPixelFormat
        )
        self.decorationPipeline = try Self.makePipeline(
            device: device,
            library: library,
            pass: "decoration",
            vertex: "terminalDecorationVertex",
            fragment: "terminalDecorationFragment",
            pixelFormat: colorPixelFormat
        )
        self.cursorPipeline = try Self.makePipeline(
            device: device,
            library: library,
            pass: "cursor",
            vertex: "terminalCursorVertex",
            fragment: "terminalCursorFragment",
            pixelFormat: colorPixelFormat
        )

        let indexLength = MemoryLayout<UInt16>.stride * Self.quadIndices.count
        guard let indexBuffer = device.makeBuffer(
            bytes: Self.quadIndices,
            length: indexLength,
            options: .storageModeShared
        ) else {
            throw MetalTerminalRendererError.bufferAllocationFailed(length: indexLength)
        }
        indexBuffer.label = "TerminalQuadIndices"
        self.quadIndexBuffer = indexBuffer

        // Glyph masks are rasterized at the drawable's own scale, so any
        // filtering would only blur them; images may be scaled, so they get
        // linear filtering.
        self.glyphSampler = try Self.makeSampler(device: device, filter: .nearest)
        self.imageSampler = try Self.makeSampler(device: device, filter: .linear)

        self.backgroundRing = InstanceRing(device: device, label: "TerminalBackground")
        self.selectionRing = InstanceRing(device: device, label: "TerminalSelection")
        self.imageRing = InstanceRing(device: device, label: "TerminalImage")
        self.glyphRing = InstanceRing(device: device, label: "TerminalGlyph")
        self.colorGlyphRing = InstanceRing(device: device, label: "TerminalColorGlyph")
        self.decorationRing = InstanceRing(device: device, label: "TerminalDecoration")
        self.cursorRing = InstanceRing(device: device, label: "TerminalCursor")
    }

    /// Convenience for hosts that ship the shaders as a compiled default
    /// library. Tries the given bundle first, then the process default, and
    /// throws rather than trapping when neither has one.
    public convenience init(
        device: MTLDevice,
        metrics: TerminalMetalCellMetrics,
        bundle: Bundle? = nil,
        palette: TerminalMetalPalette? = nil,
        colorEncoding: TerminalMetalColorEncoding = .displayEncoded,
        colorSpace: TerminalMetalColorSpace = .sRGB,
        minimumContrast: Float = 1,
        colorPixelFormat: MTLPixelFormat = .bgra8Unorm,
        atlas: GlyphAtlas = GlyphAtlas(),
        imageProvider: @escaping (UInt32) -> FfiStoredImage? = { _ in nil },
        imageMetadataProvider: @escaping (UInt32) -> FfiGraphicsImageMetadata? = { _ in nil }
    ) throws {
        guard let library = Self.defaultLibrary(device: device, bundle: bundle) else {
            throw MetalTerminalRendererError.defaultLibraryUnavailable
        }
        try self.init(
            device: device,
            library: library,
            metrics: metrics,
            palette: palette,
            colorEncoding: colorEncoding,
            colorSpace: colorSpace,
            minimumContrast: minimumContrast,
            colorPixelFormat: colorPixelFormat,
            atlas: atlas,
            imageProvider: imageProvider,
            imageMetadataProvider: imageMetadataProvider
        )
    }

    /// The shader library a host most likely has, or nil. Never traps: both
    /// `makeDefaultLibrary` variants fail by returning nil or throwing.
    public static func defaultLibrary(device: MTLDevice, bundle: Bundle? = nil) -> MTLLibrary? {
        if let bundle, let library = try? device.makeDefaultLibrary(bundle: bundle),
           library.functionNames.contains(requiredFunction) {
            return library
        }
        if let library = device.makeDefaultLibrary(),
           library.functionNames.contains(requiredFunction) {
            return library
        }
        // Compiled from the shader source the package ships.
        //
        // A prebuilt default.metallib is what Xcode puts in an app bundle, and
        // it is the fast path above. SwiftPM has no Metal build rule, so a
        // command-line consumer receives TerminalShaders.metal as a resource
        // and nothing compiled -- makeDefaultLibrary then returns nil or, worse,
        // the host application's own library, which has none of these
        // functions. Shipping a prebuilt .metallib instead would not fix it:
        // a metallib is built for one target, and both platforms would have to
        // claim the same `default.metallib` filename.
        //
        // Compiling the source at runtime costs one compile when the first
        // renderer is built, works on whichever platform is actually running,
        // and cannot go stale, because the source in the bundle is the source.
        if let bundle {
            return compiledFromShippedSource(device: device, bundle: bundle)
        }
        return nil
    }

    /// One entry point that only this package's shaders define.
    ///
    /// A library is not usable just because Metal handed one back: an
    /// application with its own default.metallib gets it from
    /// `makeDefaultLibrary()`, and the failure then surfaces much later as a
    /// pipeline that will not build.
    private static let requiredFunction = "terminalGrayscaleGlyphVertex"

    private static func compiledFromShippedSource(device: MTLDevice, bundle: Bundle) -> MTLLibrary? {
        guard let url = bundle.url(forResource: "TerminalShaders", withExtension: "metal"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return try? device.makeLibrary(source: source, options: nil)
    }

    // MARK: - Custom shaders

    /// Compile `custom-shader` sources, applied in the given order. As
    /// upstream does, one failure disables them all: the terminal is drawn
    /// as if none were configured and the reasons are returned.
    @discardableResult
    public func setCustomShaders(_ sources: [(name: String, glsl: String)]) -> [String] {
        var compiled: [TerminalCustomShader] = []
        var errors: [String] = []
        for source in sources {
            do {
                compiled.append(try TerminalCustomShader.compile(
                    glsl: source.glsl, name: source.name, device: device, pixelFormat: colorPixelFormat))
            } catch {
                errors.append(String(describing: error))
            }
        }
        applyCustomShaders(errors.isEmpty ? compiled : [], errors: errors)
        return errors
    }

    /// Read and compile `custom-shader` files. An unreadable file is a
    /// failure like a compile error.
    @discardableResult
    public func loadCustomShaders(paths: [String]) -> [String] {
        var sources: [(name: String, glsl: String)] = []
        var errors: [String] = []
        for path in paths {
            do {
                sources.append((URL(fileURLWithPath: path).lastPathComponent, try String(contentsOfFile: path, encoding: .utf8)))
            } catch {
                errors.append(String(describing: TerminalCustomShaderError.unreadable(
                    path: path, reason: (error as NSError).localizedDescription)))
            }
        }
        guard errors.isEmpty else {
            applyCustomShaders([], errors: errors)
            return errors
        }
        return setCustomShaders(sources)
    }

    private func applyCustomShaders(_ shaders: [TerminalCustomShader], errors: [String]) {
        customShaders = shaders
        customShaderErrors = errors
        customShaderTargets = []
        customShaderUniforms = TerminalCustomShaderUniforms()
        customShaderStartTime = customShaderClock()
        customShaderLastFrameTime = nil
    }

    /// The offscreen textures the terminal passes and all but the last
    /// shader draw into, or nil when `target` cannot be shaded.
    private func customShaderIntermediates(for target: MTLTexture) -> [MTLTexture]? {
        guard target.pixelFormat == colorPixelFormat else { return nil }
        let count = customShaders.count > 1 ? 2 : 1
        if customShaderTargets.count == count,
           customShaderTargets.allSatisfy({ $0.width == target.width && $0.height == target.height }) {
            return customShaderTargets
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: colorPixelFormat, width: target.width, height: target.height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        var textures: [MTLTexture] = []
        for index in 0..<count {
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            texture.label = "CustomShaderTarget.\(index)"
            textures.append(texture)
        }
        customShaderTargets = textures
        return textures
    }

    /// Advance time, frame and cursor for the frame about to be shaded.
    private func advanceCustomShaderUniforms(width: Int, height: Int) {
        var uniforms = customShaderUniforms
        let now = customShaderClock()
        let size = SIMD4<Float>(Float(width), Float(height), 1, 0)
        uniforms.resolution = size
        uniforms.channelResolution = size
        uniforms.time = Float(now - customShaderStartTime)
        uniforms.timeDelta = customShaderLastFrameTime.map { Float(now - $0) } ?? 0
        uniforms.frame = customShaderLastFrameTime == nil ? 0 : uniforms.frame &+ 1
        customShaderLastFrameTime = now

        // Shadertoy's iDate: year, zero-based month, day, seconds since midnight.
        let date = Date()
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = Float(parts.year ?? 0)
        let month = Float((parts.month ?? 1) - 1)
        let day = Float(parts.day ?? 1)
        let seconds = Float(date.timeIntervalSince(calendar.startOfDay(for: date)))
        uniforms.date = SIMD4<Float>(year, month, day, seconds)

        // The cursor is whatever the cursor pass drew: the union of its quads.
        if let first = planner.cursorInstances.first {
            var minX = first.rect.x, minY = first.rect.y
            var maxX = first.rect.x + first.rect.z, maxY = first.rect.y + first.rect.w
            for instance in planner.cursorInstances.dropFirst() {
                minX = min(minX, instance.rect.x)
                minY = min(minY, instance.rect.y)
                maxX = max(maxX, instance.rect.x + instance.rect.z)
                maxY = max(maxY, instance.rect.y + instance.rect.w)
            }
            // Where the cursor landed on the target: the grid's offsets (the
            // padding, and a sub-cell scroll) moved every quad.
            let x = minX + planner.viewport.horizontalPixelOffset
            let top = minY + planner.viewport.verticalPixelOffset
            let cursor = SIMD4<Float>(x, Float(height) - top, maxX - minX, maxY - minY)
            if cursor != uniforms.currentCursor || first.color != uniforms.currentCursorColor {
                uniforms.previousCursor = uniforms.currentCursor == .zero ? cursor : uniforms.currentCursor
                uniforms.previousCursorColor = uniforms.currentCursor == .zero ? first.color : uniforms.currentCursorColor
                uniforms.currentCursor = cursor
                uniforms.currentCursorColor = first.color
                uniforms.timeCursorChange = uniforms.time
            }
        }
        customShaderUniforms = uniforms
    }

    /// Run every custom shader as a full-screen pass: the terminal image in
    /// `intermediates[0]`, ping-ponging through `intermediates[1]`, the last
    /// pass writing `target`. False when an encoder could not be made.
    private func encodeCustomShaders(
        into commandBuffer: MTLCommandBuffer,
        intermediates: [MTLTexture],
        target: MTLTexture
    ) -> Bool {
        advanceCustomShaderUniforms(width: target.width, height: target.height)
        var uniforms = customShaderUniforms
        var input = intermediates[0]
        for (index, shader) in customShaders.enumerated() {
            let output = index == customShaders.count - 1 ? target : intermediates[(index + 1) % intermediates.count]
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
            encoder.label = "CustomShader.\(shader.name)"
            encoder.setRenderPipelineState(shader.pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TerminalCustomShaderUniforms>.stride, index: 0)
            encoder.setFragmentTexture(input, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            input = output
        }
        return true
    }

    // MARK: - Presented-frame cadence

    /// How many frames this renderer has actually put on screen.
    ///
    /// Presentation cadence for the surface this renderer draws into.
    ///
    /// Held, not owned: a surface hands the same clock to every renderer it
    /// builds, so rebuilding one for a theme or scale change does not restart
    /// the count. A renderer constructed without one gets its own, which is
    /// what an offscreen or test renderer wants.
    let presentationClock: TerminalPresentationClock

    /// One coherent read of sequence, presented time and interval.
    public var presentationCadence: TerminalPresentationCadence {
        presentationClock.cadence
    }

    /// Point a layer at this renderer's device, pixel format and output
    /// gamut. The layer metadata must match the planner's conversion or a
    /// Display-P3 frame will be composited as sRGB by Core Animation.
    public func configure(layer: CAMetalLayer) {
        layer.device = device
        layer.pixelFormat = colorPixelFormat
        switch planner.colorSpace {
        case .sRGB:
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        case .displayP3:
            layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        }
        layer.framebufferOnly = true
        layer.isOpaque = true
    }

    // MARK: - Rendering

    /// Plan and draw one frame into a layer's next drawable.
    ///
    /// Returns the frame's statistics whether or not anything was drawn: an
    /// invalid frame, or a layer with no drawable to hand out, is skipped and
    /// reported, not trapped on.
    /// - Parameters:
    ///   - overscanRows: extra rows below the viewport carried by `frame`.
    ///   - verticalPixelOffset: whole-grid translation in drawable pixels,
    ///     positive downward. Sub-cell scrolling drives this; the overscan
    ///     rows are what keeps the exposed strip from being empty. The top
    ///     padding is part of it.
    ///   - horizontalPixelOffset: the left padding, in drawable pixels.
    @discardableResult
    public func render(
        frame: FfiRenderFrame,
        in layer: CAMetalLayer,
        overscanRows: Int = 0,
        verticalPixelOffset: Float = 0,
        horizontalPixelOffset: Float = 0
    ) -> TerminalMetalFrameStatistics {
        let scale = Float(layer.contentsScale)
        let viewport = TerminalMetalViewport(
            drawableSize: layer.drawableSize,
            backingScale: scale,
            verticalPixelOffset: verticalPixelOffset,
            horizontalPixelOffset: horizontalPixelOffset
        )
        var stats = plan(frame: frame, viewport: viewport, overscanRows: overscanRows)
        guard stats.isRenderable else { return finish(stats, .notSubmitted) }
        // A layer whose drawable pool is exhausted returns nil here. Nothing
        // is drawn, nothing is presented, and the layer keeps the pixels it
        // already had -- so this frame must not be recorded as if it had
        // reached the screen.
        guard let drawable = nextDrawableProvider(layer) else { return finish(stats, .noDrawable) }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = clearColor
        let presentation = draw(
            viewport: viewport,
            descriptor: descriptor,
            drawable: drawable,
            capture: committedFrameCaptureForTesting.map { hook in
                { (pixels: [UInt8]) in hook(frame, pixels) }
            }
        )
        stats = finish(stats, presentation)
        return stats
    }

    /// Record how a frame ended and, when it never reached a render target,
    /// drop the planner's claim on it. `statistics` is the value a host reads
    /// after a redraw, so it carries the outcome too.
    private func finish(
        _ stats: TerminalMetalFrameStatistics,
        _ presentation: TerminalMetalFramePresentation
    ) -> TerminalMetalFrameStatistics {
        var stats = stats
        stats.presentation = presentation
        if presentation.leavesStalePixels {
            planner.discardPlannedFrame()
        }
        statistics = stats
        return stats
    }

    /// Plan and draw one frame into an arbitrary render pass -- an offscreen
    /// texture, a shared drawable, a test.
    @discardableResult
    public func render(
        frame: FfiRenderFrame,
        viewport: TerminalMetalViewport,
        descriptor: MTLRenderPassDescriptor,
        drawable: MTLDrawable? = nil,
        waitUntilCompleted: Bool = false,
        overscanRows: Int = 0
    ) -> TerminalMetalFrameStatistics {
        let stats = plan(frame: frame, viewport: viewport, overscanRows: overscanRows)
        guard stats.isRenderable else { return finish(stats, .notSubmitted) }
        let presentation = draw(
            viewport: viewport,
            descriptor: descriptor,
            drawable: drawable,
            waitUntilCompleted: waitUntilCompleted
        )
        return finish(stats, presentation)
    }

    /// Plan a frame without touching the GPU. Consumes the whole
    /// `FfiRenderFrame`, so the cells and the snapshot always agree.
    @discardableResult
    public func plan(
        frame: FfiRenderFrame,
        viewport: TerminalMetalViewport,
        overscanRows: Int = 0
    ) -> TerminalMetalFrameStatistics {
        frameImageMetadata.removeAll(keepingCapacity: true)
        frameImageIdsWithoutMetadata.removeAll(keepingCapacity: true)
        statistics = planner.plan(
            frame: frame,
            viewport: viewport,
            overscanRows: overscanRows,
            imageProvider: imageProvider,
            imageMetadataProvider: { [weak self] imageId in
                guard let self else { return nil }
                if let cached = self.frameImageMetadata[imageId] { return cached }
                if self.frameImageIdsWithoutMetadata.contains(imageId) {
                    return self.resolvedImageMetadata[imageId]
                }
                // A legacy host has no core metadata. Once its first upload
                // succeeds, cached texture metadata supplies planning
                // geometry, avoiding another clone of its image bytes.
                if let metadata = self.imageMetadataProvider(imageId) {
                    self.frameImageMetadata[imageId] = metadata
                    return metadata
                }
                self.frameImageIdsWithoutMetadata.insert(imageId)
                return self.resolvedImageMetadata[imageId]
            }
        )
        return statistics
    }

    /// The default background, as the render pass clears to it: every cell
    /// that keeps the default color then costs no instance at all.
    public var clearColor: MTLClearColor {
        let color = TerminalMetalColor.premultiplied(planner.palette.background)
        return MTLClearColor(
            red: Double(color.x),
            green: Double(color.y),
            blue: Double(color.z),
            alpha: Double(color.w)
        )
    }

    /// Drop cached image textures so the next frame re-decodes them. Call it
    /// when the engine replaces an image's contents under the same id.
    public func invalidateImages(imageIds: Set<UInt32>? = nil) {
        guard let imageIds else {
            resolvedImageTextures.removeAll(keepingCapacity: true)
            resolvedImageMetadata.removeAll(keepingCapacity: true)
            return
        }
        for imageId in imageIds {
            resolvedImageTextures.removeValue(forKey: imageId)
            resolvedImageMetadata.removeValue(forKey: imageId)
        }
    }

    @discardableResult
    private func draw(
        viewport: TerminalMetalViewport,
        descriptor: MTLRenderPassDescriptor,
        drawable: MTLDrawable?,
        waitUntilCompleted: Bool = false,
        capture: (([UInt8]) -> Void)? = nil
    ) -> TerminalMetalFramePresentation {
        // Wait before touching this slot's buffers: the GPU may still be
        // reading the frame that used them.
        inFlight.wait()
        slot = (slot + 1) % Self.framesInFlight

        uploadDirtyAtlasPages()
        resolveImageTextures()

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlight.signal()
            return .noCommandBuffer
        }
        commandBuffer.label = "TerminalFrame"
        commandBuffer.addCompletedHandler { [inFlight] _ in inFlight.signal() }

        // With custom shaders the terminal passes draw offscreen, and the
        // shaders carry that image to the render target.
        var terminalDescriptor = descriptor
        var shaderIntermediates: [MTLTexture] = []
        if !customShaders.isEmpty, let target = descriptor.colorAttachments[0].texture,
           let intermediates = customShaderIntermediates(for: target),
           let offscreen = descriptor.copy() as? MTLRenderPassDescriptor {
            offscreen.colorAttachments[0].texture = intermediates[0]
            terminalDescriptor = offscreen
            shaderIntermediates = intermediates
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: terminalDescriptor) else {
            // Committed only to release the semaphore through the completion
            // handler; nothing was encoded, so the drawable is dropped
            // unpresented and this frame is owed another attempt.
            commandBuffer.commit()
            return .noCommandEncoder
        }
        encoder.label = "TerminalPasses"
        encode(into: encoder, viewport: viewport)
        encoder.endEncoding()

        if let target = descriptor.colorAttachments[0].texture, !shaderIntermediates.isEmpty,
           !encodeCustomShaders(into: commandBuffer, intermediates: shaderIntermediates, target: target) {
            commandBuffer.commit()
            return .noCommandEncoder
        }

        // Read the render target back inside this same command buffer, after
        // the passes and before the present, so a test inspects the pixels
        // this frame committed rather than a later re-render of them.
        let captureBuffer = capture == nil ? nil : encodeCapture(into: commandBuffer, from: descriptor)

        if let drawable {
            // Recorded from the drawable's own presented handler, not from
            // commit. A command buffer being committed says the GPU has been
            // asked; it says nothing about when the frame reached the display,
            // and a consumer measuring frame gaps needs the second of those.
            // `presentedTime` is the system's own presentation timestamp on the
            // same monotonic clock as CACurrentMediaTime.
            #if targetEnvironment(simulator)
            // The iOS simulator's SDK does not surface `addPresentedHandler`
            // or `presentedTime` to Swift on `MTLDrawable` or on
            // `CAMetalDrawable`, though the headers declare both for
            // ios(10.3) and a device build compiles them. There is no other
            // API on this path that reports true presentation, and encode or
            // commit time is a different measurement wearing the same name --
            // so the counters simply stay at zero here rather than being fed
            // something that would read as display cadence and is not.
            #else
            drawable.addPresentedHandler { [weak self] presented in
                self?.presentationClock.record(presentedAt: presented.presentedTime)
            }
            #endif
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
        // Committed, with a drawable, for the screen: the frame is on its way
        // and nothing further on this side can stop it. An offscreen capture
        // has no drawable and is not on its way anywhere, so it is not
        // counted -- and a frame rejected before this point never reached
        // `draw` at all.
        if drawable != nil {
            presentationClock.recordSubmitted()
        }
        if waitUntilCompleted || captureBuffer != nil {
            commandBuffer.waitUntilCompleted()
        }
        if let capture, let captureBuffer {
            let raw = captureBuffer.contents().assumingMemoryBound(to: UInt8.self)
            capture([UInt8](UnsafeBufferPointer(start: raw, count: captureBuffer.length)))
        }
        return drawable == nil ? .committedOffscreen : .presented
    }

    /// Blit this pass's color target into shared memory. Returns nil -- and
    /// encodes nothing -- when the target cannot be read back, so a capture
    /// that is impossible degrades to no capture rather than to a wrong one.
    private func encodeCapture(
        into commandBuffer: MTLCommandBuffer,
        from descriptor: MTLRenderPassDescriptor
    ) -> MTLBuffer? {
        guard let texture = descriptor.colorAttachments[0].texture else { return nil }
        let bytesPerRow = texture.width * 4
        let length = bytesPerRow * texture.height
        guard length > 0,
              let buffer = device.makeBuffer(length: length, options: .storageModeShared),
              let blit = commandBuffer.makeBlitCommandEncoder()
        else { return nil }
        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: length)
        blit.endEncoding()
        return buffer
    }

    private func encode(into encoder: MTLRenderCommandEncoder, viewport: TerminalMetalViewport) {
        var uniform = viewport
        switch (planner.colorSpace, planner.colorEncoding) {
        case (.sRGB, .displayEncoded): uniform._pad = 0
        case (.sRGB, .linear): uniform._pad = 1
        case (.displayP3, .displayEncoded): uniform._pad = 2
        case (.displayP3, .linear): uniform._pad = 3
        }
        for pass in Self.passOrder where !planner.isEmpty(pass) {
            switch pass {
            case .background:
                guard let buffer = backgroundRing.upload(planner.backgroundInstances, slot: slot) else { continue }
                bind(encoder, pipeline: backgroundPipeline, uniform: &uniform, instances: buffer)
                drawQuads(encoder, instanceCount: planner.backgroundInstances.count)
            case .selection:
                guard let buffer = selectionRing.upload(planner.selectionInstances, slot: slot) else { continue }
                bind(encoder, pipeline: selectionPipeline, uniform: &uniform, instances: buffer)
                drawQuads(encoder, instanceCount: planner.selectionInstances.count)
            case .kittyImage:
                encodeImages(encoder, uniform: &uniform)
            case .grayscaleGlyph:
                encodeGlyphs(
                    encoder,
                    uniform: &uniform,
                    instances: planner.glyphInstances,
                    ranges: planner.glyphPageRanges,
                    ring: glyphRing,
                    pipeline: glyphPipeline
                )
            case .colorGlyph:
                encodeGlyphs(
                    encoder,
                    uniform: &uniform,
                    instances: planner.colorGlyphInstances,
                    ranges: planner.colorGlyphPageRanges,
                    ring: colorGlyphRing,
                    pipeline: colorGlyphPipeline
                )
            case .decoration:
                guard let buffer = decorationRing.upload(planner.decorationInstances, slot: slot) else { continue }
                bind(encoder, pipeline: decorationPipeline, uniform: &uniform, instances: buffer)
                drawQuads(encoder, instanceCount: planner.decorationInstances.count)
            case .cursor:
                guard let buffer = cursorRing.upload(planner.cursorInstances, slot: slot) else { continue }
                bind(encoder, pipeline: cursorPipeline, uniform: &uniform, instances: buffer)
                drawQuads(encoder, instanceCount: planner.cursorInstances.count)
            }
        }
    }

    private func encodeImages(_ encoder: MTLRenderCommandEncoder, uniform: inout TerminalMetalViewport) {
        guard let buffer = imageRing.upload(planner.imageInstances, slot: slot) else { return }
        encoder.setRenderPipelineState(imagePipeline)
        encoder.setVertexBytes(&uniform, length: MemoryLayout<TerminalMetalViewport>.size, index: 0)
        encoder.setFragmentSamplerState(imageSampler, index: 0)
        let stride = MemoryLayout<TerminalMetalImageInstance>.stride
        // One texture per placement, so one draw per placement.
        for (index, instance) in planner.imageInstances.enumerated() {
            guard let texture = resolvedImageTextures[instance.imageId] else { continue }
            encoder.setVertexBuffer(buffer, offset: index * stride, index: 1)
            encoder.setFragmentTexture(texture, index: 0)
            drawQuads(encoder, instanceCount: 1)
        }
    }

    private func encodeGlyphs(
        _ encoder: MTLRenderCommandEncoder,
        uniform: inout TerminalMetalViewport,
        instances: [TerminalMetalGlyphInstance],
        ranges: [(page: Int, range: Range<Int>)],
        ring: InstanceRing,
        pipeline: MTLRenderPipelineState
    ) {
        guard let buffer = ring.upload(instances, slot: slot) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniform, length: MemoryLayout<TerminalMetalViewport>.size, index: 0)
        encoder.setFragmentSamplerState(glyphSampler, index: 0)
        let stride = MemoryLayout<TerminalMetalGlyphInstance>.stride
        for group in ranges {
            guard group.page >= 0, group.page < atlasTextures.count,
                  let atlasTexture = atlasTextures[group.page], !group.range.isEmpty else { continue }
            encoder.setVertexBuffer(buffer, offset: group.range.lowerBound * stride, index: 1)
            encoder.setFragmentTexture(atlasTexture, index: 0)
            drawQuads(encoder, instanceCount: group.range.count)
        }
    }

    private func bind(
        _ encoder: MTLRenderCommandEncoder,
        pipeline: MTLRenderPipelineState,
        uniform: inout TerminalMetalViewport,
        instances: MTLBuffer
    ) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniform, length: MemoryLayout<TerminalMetalViewport>.size, index: 0)
        encoder.setVertexBuffer(instances, offset: 0, index: 1)
    }

    private func drawQuads(_ encoder: MTLRenderCommandEncoder, instanceCount: Int) {
        guard instanceCount > 0 else { return }
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: Self.quadIndices.count,
            indexType: .uint16,
            indexBuffer: quadIndexBuffer,
            indexBufferOffset: 0,
            instanceCount: instanceCount
        )
    }

    // MARK: - Atlas and image textures

    /// Upload only changed generations, copy-on-writing each texture so a
    /// command buffer sampling the previous generation can finish safely.
    private func uploadDirtyAtlasPages() {
        let pages = planner.atlas.pages
        if atlasTextures.count > pages.count {
            atlasTextures.removeLast(atlasTextures.count - pages.count)
            atlasTextureGenerations.removeLast(atlasTextureGenerations.count - pages.count)
        }
        while atlasTextures.count < pages.count {
            atlasTextures.append(nil)
            atlasTextureGenerations.append(0)
        }

        for index in pages.indices where atlasTextures[index] == nil || atlasTextureGenerations[index] != pages[index].generation {
            guard let data = planner.atlas.textureData(pageIndex: index) else { continue }
            let page = pages[index]
            guard data.count >= page.bytesPerRow * page.height else { continue }
            // Never mutate the texture currently referenced by an earlier
            // in-flight command buffer. A failed allocation leaves the old
            // generation untouched, so this page is retried next frame.
            guard let texture = makeAtlasTexture(page: page) else { continue }
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                texture.replace(
                    region: MTLRegionMake2D(0, 0, page.width, page.height),
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: page.bytesPerRow
                )
            }
            // Publish only after the replacement was created and populated.
            atlasTextures[index] = texture
            atlasTextureGenerations[index] = page.generation
            atlasUploadCount += 1
        }
        planner.clearDirtyAtlasPages()
    }

    private func makeAtlasTexture(page: GlyphAtlasPage) -> MTLTexture? {
        guard page.width > 0, page.height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: page.pixelFormat == .grayscale8 ? .r8Unorm : .bgra8Unorm,
            width: page.width,
            height: page.height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = page.pixelFormat == .grayscale8 ? "TerminalGlyphAtlas.Gray" : "TerminalGlyphAtlas.Color"
        return texture
    }

    /// Decode and upload the images this frame's placements need, once each.
    /// A malformed image is dropped -- `MetalImageCache` throws rather than
    /// trapping, and the placement simply does not draw.
    private func resolveImageTextures() {
        guard !planner.imageInstances.isEmpty else {
            if !resolvedImageTextures.isEmpty {
                resolvedImageTextures.removeAll(keepingCapacity: true)
                resolvedImageMetadata.removeAll(keepingCapacity: true)
            }
            imageCache.purge(unusedByImageIds: [])
            return
        }

        var live = Set<UInt32>()
        for instance in planner.imageInstances {
            let imageId = instance.imageId
            live.insert(imageId)
            let metadata = frameImageMetadata[imageId]
            if resolvedImageTextures[imageId] != nil {
                // The legacy byte-only API keeps its existing explicit
                // invalidation behaviour. Metadata-aware hosts re-fetch only
                // when core reports a changed identity or geometry.
                guard let metadata else { continue }
                guard resolvedImageMetadata[imageId] != metadata else { continue }
            }
            guard let stored = imageProvider(imageId) else { continue }
            guard let entry = try? imageCache.cache(imageId: imageId, storedImage: stored),
                  let texture = entry.texture else { continue }
            resolvedImageTextures[imageId] = texture
            resolvedImageMetadata[imageId] = metadata ?? FfiGraphicsImageMetadata(
                format: stored.format,
                width: stored.width,
                height: stored.height,
                generation: 0
            )
        }

        for imageId in resolvedImageTextures.keys.filter({ !live.contains($0) }) {
            resolvedImageTextures.removeValue(forKey: imageId)
            resolvedImageMetadata.removeValue(forKey: imageId)
        }
        imageCache.purge(unusedByImageIds: live)
    }

    // MARK: - Pipeline construction

    private static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        pass: String,
        vertex: String,
        fragment: String,
        pixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        guard let vertexFunction = library.makeFunction(name: vertex) else {
            throw MetalTerminalRendererError.missingShaderFunction(vertex)
        }
        guard let fragmentFunction = library.makeFunction(name: fragment) else {
            throw MetalTerminalRendererError.missingShaderFunction(fragment)
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "TerminalPass.\(pass)"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction

        // Explicit premultiplied-alpha blending, spelled out rather than
        // inherited: glyph masks, selection overlays and Kitty images all
        // arrive premultiplied, so source alpha must not be applied twice.
        let attachment = descriptor.colorAttachments[0]
        attachment?.pixelFormat = pixelFormat
        attachment?.isBlendingEnabled = true
        attachment?.rgbBlendOperation = .add
        attachment?.alphaBlendOperation = .add
        attachment?.sourceRGBBlendFactor = .one
        attachment?.sourceAlphaBlendFactor = .one
        attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw MetalTerminalRendererError.pipelineCreationFailed(
                pass: pass,
                message: (error as NSError).localizedDescription
            )
        }
    }

    private static func makeSampler(device: MTLDevice, filter: MTLSamplerMinMagFilter) throws -> MTLSamplerState {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = filter
        descriptor.magFilter = filter
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else {
            throw MetalTerminalRendererError.samplerCreationFailed
        }
        return sampler
    }

    /// One instance buffer per frame in flight, grown on demand and reused
    /// forever after.
    private final class InstanceRing {
        private let device: MTLDevice
        private let label: String
        private var slots: [MTLBuffer?]
        private(set) var allocations = 0

        init(device: MTLDevice, label: String, slotCount: Int = MetalTerminalRenderer.framesInFlight) {
            self.device = device
            self.label = label
            self.slots = Array(repeating: nil, count: max(slotCount, 1))
        }

        func upload<Instance>(_ instances: [Instance], slot: Int) -> MTLBuffer? {
            guard !instances.isEmpty else { return nil }
            let index = slot % slots.count
            let required = MemoryLayout<Instance>.stride * instances.count
            if let length = TerminalMetalBufferSizing.growth(
                existingLength: slots[index]?.length ?? 0,
                requiredLength: required
            ) {
                guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
                    return nil
                }
                buffer.label = "\(label).\(index)"
                slots[index] = buffer
                allocations += 1
            }
            guard let buffer = slots[index] else { return nil }
            instances.withUnsafeBytes { raw in
                guard let base = raw.baseAddress, raw.count <= buffer.length else { return }
                buffer.contents().copyMemory(from: base, byteCount: raw.count)
            }
            return buffer
        }
    }
}
