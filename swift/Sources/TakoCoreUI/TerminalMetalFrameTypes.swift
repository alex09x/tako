/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

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
