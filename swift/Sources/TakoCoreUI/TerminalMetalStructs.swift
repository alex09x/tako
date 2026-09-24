import CoreGraphics
import Foundation
import simd

/// Rendering pass order: backgrounds and images, cursor geometry, then text
/// and decorations so an opaque block cursor never erases its cell's glyph.
@frozen public enum TerminalMetalRenderPass: UInt8, CaseIterable, Sendable {
    case background = 0
    case selection = 1
    case cursor = 2
    case grayscaleGlyph = 3
    /// Kitty Graphics placements, drawn over the cell backgrounds but under
    /// the text so a glyph on top of an image stays readable.
    case kittyImage = 4
    case colorGlyph = 5
    case decoration = 6
}

public extension TerminalMetalRenderPass {
    /// Stable draw ordering for the pass bundle.
    static var ordered: [TerminalMetalRenderPass] {
        [.background, .selection, .cursor, .grayscaleGlyph, .colorGlyph, .decoration]
    }

    /// Full draw ordering once Kitty Graphics placements are part of the frame.
    static var orderedWithImages: [TerminalMetalRenderPass] {
        [.background, .selection, .kittyImage, .cursor, .grayscaleGlyph, .colorGlyph, .decoration]
    }
}

/// Drawable-space viewport, with explicit pixel width/height and scale.
@frozen public struct TerminalMetalViewport: Equatable, Sendable {
    public var drawableWidth: Float
    public var drawableHeight: Float
    public var backingScale: Float
    /// Carries the color space/encoding selector to the shader. Named as a pad
    /// before it had that job; kept under the old name so the public layout
    /// does not shift under consumers.
    public var _pad: Float
    /// Whole-grid vertical translation in drawable pixels, applied by every
    /// vertex shader through `terminalDrawableToClip`. Positive moves content
    /// down. This is how a fraction of a cell is presented: one uniform, so
    /// backgrounds, glyphs, images, decorations, selection and cursor cannot
    /// drift apart from one another.
    public var verticalPixelOffset: Float
    /// Whole-grid horizontal translation in drawable pixels, positive to the
    /// right: the left padding. With `verticalPixelOffset` it places the grid
    /// inside the view, so a margin is drawn at negative grid coordinates.
    public var horizontalPixelOffset: Float

    public init(
        drawableWidth: Float,
        drawableHeight: Float,
        backingScale: Float = 1,
        verticalPixelOffset: Float = 0,
        horizontalPixelOffset: Float = 0
    ) {
        self.drawableWidth = drawableWidth
        self.drawableHeight = drawableHeight
        self.backingScale = backingScale
        self._pad = 0
        self.verticalPixelOffset = verticalPixelOffset
        self.horizontalPixelOffset = horizontalPixelOffset
    }

    public init(
        drawableSize: CGSize,
        backingScale: Float = 1,
        verticalPixelOffset: Float = 0,
        horizontalPixelOffset: Float = 0
    ) {
        self.init(
            drawableWidth: Float(drawableSize.width),
            drawableHeight: Float(drawableSize.height),
            backingScale: backingScale,
            verticalPixelOffset: verticalPixelOffset,
            horizontalPixelOffset: horizontalPixelOffset
        )
    }

    /// Size passed to shaders. `CAMetalLayer.drawableSize` is already in pixels;
    /// do not multiply it by `backingScale` a second time on Retina displays.
    public var drawablePixelSize: SIMD2<Float> {
        SIMD2<Float>(drawableWidth, drawableHeight)
    }

    /// Corresponding logical point size for host layout calculations.
    public var logicalPointSize: SIMD2<Float> {
        let scale = max(backingScale, 1)
        return SIMD2<Float>(drawableWidth / scale, drawableHeight / scale)
    }
}

@frozen public struct TerminalMetalBackgroundInstance: Equatable, Sendable {
    public static let pass: TerminalMetalRenderPass = .background

    /// `(x, y, width, height)` in drawable pixels, top-left origin.
    public var rect: SIMD4<Float>
    /// Linear RGBA color.
    public var color: SIMD4<Float>

    public init(rect: SIMD4<Float>, color: SIMD4<Float>) {
        self.rect = rect
        self.color = color
    }

    public init(x: Float, y: Float, width: Float, height: Float, color: SIMD4<Float>) {
        self.init(rect: SIMD4<Float>(x, y, width, height), color: color)
    }

    public static func cellRect(
        column: Int,
        row: Int,
        cellWidth: Float,
        cellHeight: Float
    ) -> SIMD4<Float> {
        SIMD4<Float>(Float(column) * cellWidth, Float(row) * cellHeight, cellWidth, cellHeight)
    }
}

@frozen public struct TerminalMetalSelectionInstance: Equatable, Sendable {
    public static let pass: TerminalMetalRenderPass = .selection

    /// `(x, y, width, height)` in drawable pixels, top-left origin.
    public var rect: SIMD4<Float>
    /// Selection overlay color in linear RGBA.
    public var color: SIMD4<Float>

    public init(rect: SIMD4<Float>, color: SIMD4<Float>) {
        self.rect = rect
        self.color = color
    }

    public init(x: Float, y: Float, width: Float, height: Float, color: SIMD4<Float>) {
        self.init(rect: SIMD4<Float>(x, y, width, height), color: color)
    }
}

@frozen public enum TerminalMetalCursorShape: UInt32, Sendable {
    case block = 0
    case bar = 1
    case underline = 2
    case hollowBlock = 3
}

@frozen public struct TerminalMetalCursorInstance: Equatable, Sendable {
    public static let pass: TerminalMetalRenderPass = .cursor

    /// `(x, y, width, height)` in drawable pixels, top-left origin.
    public var rect: SIMD4<Float>
    public var shape: UInt32
    public var blinkState: UInt32
    public var _pad: SIMD2<Float>
    public var color: SIMD4<Float>

    public init(
        rect: SIMD4<Float>,
        shape: TerminalMetalCursorShape,
        blinkState: UInt32 = 1,
        color: SIMD4<Float>
    ) {
        self.rect = rect
        self.shape = shape.rawValue
        self.blinkState = blinkState
        self._pad = SIMD2<Float>(0, 0)
        self.color = color
    }

    public init(
        x: Float,
        y: Float,
        width: Float,
        height: Float,
        shape: TerminalMetalCursorShape,
        blinkState: UInt32 = 1,
        color: SIMD4<Float>
    ) {
        self.init(
            rect: SIMD4<Float>(x, y, width, height),
            shape: shape,
            blinkState: blinkState,
            color: color
        )
    }

    /// Helper for blinking-state toggles without touching host-side logic.
    public var isBlinkingOn: Bool {
        blinkState != 0
    }
}

@frozen public struct TerminalMetalGlyphInstance: Equatable, Sendable {
    public static let pass: TerminalMetalRenderPass = .grayscaleGlyph

    /// `(x, y, width, height)` in drawable pixels, top-left origin.
    public var destRect: SIMD4<Float>
    /// `(u0, v0, u1, v1)` normalized UV coordinates for a grayscale glyph texture.
    public var uvRect: SIMD4<Float>
    /// Pre-multiplied linear RGBA color.
    public var color: SIMD4<Float>
    /// Target atlas page index.
    public var atlasPage: UInt32
    /// Reserved for future glyph flags.
    public var flags: UInt32
    public var _pad: SIMD2<Float>

    public init(
        destRect: SIMD4<Float>,
        uvRect: SIMD4<Float>,
        color: SIMD4<Float>,
        atlasPage: UInt32 = 0,
        flags: UInt32 = 0
    ) {
        self.destRect = destRect
        self.uvRect = uvRect
        self.color = color
        self.atlasPage = atlasPage
        self.flags = flags
        self._pad = SIMD2<Float>(0, 0)
    }

    public init(
        x: Float,
        y: Float,
        width: Float,
        height: Float,
        uvRect: SIMD4<Float>,
        color: SIMD4<Float>,
        atlasPage: UInt32 = 0,
        flags: UInt32 = 0
    ) {
        self.init(
            destRect: SIMD4<Float>(x, y, width, height),
            uvRect: uvRect,
            color: color,
            atlasPage: atlasPage,
            flags: flags
        )
    }

    public static func premultipliedColor(_ color: SIMD4<Float>) -> SIMD4<Float> {
        let alpha = color.w
        return SIMD4<Float>(color.x * alpha, color.y * alpha, color.z * alpha, alpha)
    }
}

public extension TerminalMetalGlyphInstance {
    /// The atlas sample contains premultiplied color instead of an alpha mask.
    static let colorGlyphFlag: UInt32 = 1 << 3
}

@frozen public enum TerminalMetalDecorationStyle: UInt32, CaseIterable, Sendable {
    case singleUnderline = 1
    case doubleUnderline = 2
    case curlyUnderline = 3
    case dottedUnderline = 4
    case dashedUnderline = 5
    case strikethrough = 6
    case overline = 7
}

/// One GPU-generated decoration. Patterned underlines are evaluated by the
/// fragment shader, keeping each decoration to a single instance.
@frozen public struct TerminalMetalDecorationInstance: Equatable, Sendable {
    public static let pass: TerminalMetalRenderPass = .decoration
    public var rect: SIMD4<Float>
    public var color: SIMD4<Float>
    public var style: UInt32
    public var thickness: Float
    public var _pad: SIMD2<Float>

    public init(
        rect: SIMD4<Float>,
        color: SIMD4<Float>,
        style: TerminalMetalDecorationStyle,
        thickness: Float
    ) {
        self.rect = rect
        self.color = color
        self.style = style.rawValue
        self.thickness = thickness
        self._pad = .zero
    }
}

/// One Kitty Graphics placement, already resolved to drawable pixels. The
/// texture itself is bound per draw (one image id per instance), so the
/// instance only carries geometry, the sub-rect of the image to sample and a
/// premultiplied tint.
@frozen public struct TerminalMetalImageInstance: Equatable, Sendable {
    public static let pass: TerminalMetalRenderPass = .kittyImage

    /// `(x, y, width, height)` in drawable pixels, top-left origin.
    public var destRect: SIMD4<Float>
    /// `(u0, v0, u1, v1)` normalized UV coordinates into the image texture.
    public var uvRect: SIMD4<Float>
    /// Pre-multiplied RGBA modulation; opaque white leaves the image alone.
    public var tint: SIMD4<Float>
    /// Kitty image id, used host-side to pick the texture for this draw.
    public var imageId: UInt32
    /// Reserved for future placement flags.
    public var flags: UInt32
    public var _pad: SIMD2<Float>

    public init(
        destRect: SIMD4<Float>,
        uvRect: SIMD4<Float> = SIMD4<Float>(0, 0, 1, 1),
        tint: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1),
        imageId: UInt32,
        flags: UInt32 = 0
    ) {
        self.destRect = destRect
        self.uvRect = uvRect
        self.tint = tint
        self.imageId = imageId
        self.flags = flags
        self._pad = SIMD2<Float>(0, 0)
    }

    public init(
        x: Float,
        y: Float,
        width: Float,
        height: Float,
        uvRect: SIMD4<Float> = SIMD4<Float>(0, 0, 1, 1),
        tint: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1),
        imageId: UInt32,
        flags: UInt32 = 0
    ) {
        self.init(
            destRect: SIMD4<Float>(x, y, width, height),
            uvRect: uvRect,
            tint: tint,
            imageId: imageId,
            flags: flags
        )
    }
}

public extension TerminalMetalBackgroundInstance {
    static var abiStride: Int { MemoryLayout<TerminalMetalBackgroundInstance>.stride }
    static var abiAlignment: Int { MemoryLayout<TerminalMetalBackgroundInstance>.alignment }
}

public extension TerminalMetalSelectionInstance {
    static var abiStride: Int { MemoryLayout<TerminalMetalSelectionInstance>.stride }
    static var abiAlignment: Int { MemoryLayout<TerminalMetalSelectionInstance>.alignment }
}

public extension TerminalMetalCursorInstance {
    static var abiStride: Int { MemoryLayout<TerminalMetalCursorInstance>.stride }
    static var abiAlignment: Int { MemoryLayout<TerminalMetalCursorInstance>.alignment }
}

public extension TerminalMetalGlyphInstance {
    static var abiStride: Int { MemoryLayout<TerminalMetalGlyphInstance>.stride }
    static var abiAlignment: Int { MemoryLayout<TerminalMetalGlyphInstance>.alignment }
}

public extension TerminalMetalImageInstance {
    static var abiStride: Int { MemoryLayout<TerminalMetalImageInstance>.stride }
    static var abiAlignment: Int { MemoryLayout<TerminalMetalImageInstance>.alignment }
}

public extension TerminalMetalDecorationInstance {
    static var abiStride: Int { MemoryLayout<TerminalMetalDecorationInstance>.stride }
    static var abiAlignment: Int { MemoryLayout<TerminalMetalDecorationInstance>.alignment }
}
