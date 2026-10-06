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
import Metal
import QuartzCore
import XCTest
@testable import TakoCoreUI

#if canImport(UIKit)
import UIKit
#endif

/// Pixels that settled a frame behind the text.
///
/// `MetalPixelTests` proves that a frame handed to the GPU lands where it
/// should. This proves the step before it: that a frame the GPU never
/// received is never mistaken for one it did.
///
/// The shipped defect had nothing to do with planning. A burst of
/// full-screen alternate-screen updates plus native scrolling drains a
/// `CAMetalLayer`'s drawable pool; `nextDrawable()` then returns nil, the
/// planned frame is dropped on the floor, and the view -- having already
/// cleared its pending flag -- pauses its display link on the next tick. The
/// engine's text, the accessibility value and the row cache are all correct
/// and stable; the only thing that is wrong is what is on the glass, which
/// keeps the half-updated image from the last frame that did present. That is
/// exactly the reported "AX text clean, screenshot mixes old glyphs into
/// rows" signature, and no assertion over text, instance counts or "the image
/// changed" can see it.
///
/// So these tests exhaust a real drawable pool on a real device, and compare
/// the *frame that was actually presented* against a fresh clean render of
/// the authoritative terminal state, byte for byte, off the GPU.
final class MetalPresentationStalenessTests: XCTestCase {

    // MARK: - Shared fixtures

    func device() throws -> MTLDevice {
        try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
    }

    /// A private render target and its pixels, read back through a blit into
    /// a shared buffer.
    ///
    /// `MTLTexture.getBytes` needs storage the CPU can address, which the
    /// Simulator's device does not advertise -- it is why every existing
    /// pixel test skips itself there. A blit works on every device, discrete
    /// ones included, so these assertions actually run where the acceptance
    /// suite runs.
    func readBack(_ texture: MTLTexture, device: MTLDevice) throws -> [UInt8] {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        let length = bytesPerRow * height
        let buffer = try XCTUnwrap(device.makeBuffer(length: length, options: .storageModeShared))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: length)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let raw = buffer.contents().assumingMemoryBound(to: UInt8.self)
        return [UInt8](UnsafeBufferPointer(start: raw, count: length))
    }

    /// The standalone Simulator XCTest runner links no metallib, so the
    /// shader source is compiled here the same way `MetalPixelTests` does it.
    private func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakoCoreUI/Resources/TerminalShaders.metal")
        return try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
    }

    private func metrics() -> TerminalMetalCellMetrics {
        TerminalMetalCellMetrics(
            font: CTFontCreateWithName("Menlo" as CFString, 12, nil),
            cellWidth: 10,
            cellHeight: 20,
            ascent: 15,
            scale: 1
        )
    }

    /// Drain the drawable pool, and refill it.
    ///
    /// On device this is what a burst of full-screen updates does by itself:
    /// three drawables in flight and `nextDrawable()` starts refusing. A
    /// `CAMetalLayer` in a Simulator test process has no screen behind it and
    /// keeps vending forever no matter how small `maximumDrawableCount` is,
    /// so the refusal is injected instead of waited for. Everything else --
    /// the planning, the encoding, the pixels -- stays on the real path.
    private func drainPool(of renderer: MetalTerminalRenderer) {
        renderer.nextDrawableProvider = { _ in nil }
    }

    private func refillPool(of renderer: MetalTerminalRenderer) {
        renderer.nextDrawableProvider = { $0.nextDrawable() }
    }

    // MARK: - The renderer's own invariant

    /// A frame the layer had no drawable for is reported as such, and the
    /// planner's cache goes with it.
    ///
    /// The row cache means "this row was planned for the state the target
    /// already holds". After a frame that no target ever received, that claim
    /// is about pixels which do not exist, so the next frame has to replan
    /// every row rather than trust it.
    func testAFrameWithNoDrawableIsNotRecordedAsPresentedAndDropsItsCache() throws {
        let device = try device()
        let renderer = try MetalTerminalRenderer(
            device: device,
            library: try makeLibrary(device: device),
            metrics: metrics()
        )

        let cols = 8
        let rows = 4
        let layer = CAMetalLayer()
        renderer.configure(layer: layer)
        layer.contentsScale = 1
        layer.drawableSize = CGSize(width: cols * 10, height: rows * 20)
        layer.maximumDrawableCount = 2

        let first = renderer.render(frame: Self.staticFrame(cols: cols, rows: rows, fill: "a"), in: layer)
        XCTAssertEqual(first.presentation, .presented, "a layer with a free drawable must present")
        XCTAssertTrue(first.presentation.wasSubmitted)
        XCTAssertFalse(first.presentation.leavesStalePixels)

        drainPool(of: renderer)
        let dropped = renderer.render(frame: Self.staticFrame(cols: cols, rows: rows, fill: "b"), in: layer)
        XCTAssertEqual(dropped.presentation, .noDrawable)
        XCTAssertFalse(dropped.presentation.wasSubmitted)
        XCTAssertTrue(dropped.presentation.leavesStalePixels)
        XCTAssertEqual(
            renderer.statistics.presentation, .noDrawable,
            "the outcome a host reads back must be the frame's real outcome")

        // The dropped frame planned every row; because it never reached the
        // screen, the identical frame that follows must plan them all again
        // instead of reusing a cache describing pixels nobody ever saw. The
        // follow-up reports *no* damaged rows, so the only thing that can
        // make it replan is the cache having been dropped.
        let replanned = renderer.plan(
            frame: Self.staticFrame(cols: cols, rows: rows, fill: "b", damagedRows: []),
            viewport: TerminalMetalViewport(drawableWidth: Float(cols * 10), drawableHeight: Float(rows * 20))
        )
        XCTAssertEqual(replanned.replannedRows, rows, "a frame that never presented left its cache behind")
        XCTAssertEqual(replanned.presentation, .notSubmitted, "planning alone submits nothing")

        // With the pool back, the same frame presents and the layer is
        // current again.
        refillPool(of: renderer)
        let retried = renderer.render(frame: Self.staticFrame(cols: cols, rows: rows, fill: "b"), in: layer)
        XCTAssertEqual(retried.presentation, .presented)
    }

    /// The offscreen path is submitted but not presented, and must not be
    /// confused with a dropped frame -- its caller owns the texture and knows
    /// the pixels arrived.
    func testAnOffscreenRenderIsSubmittedAndKeepsItsCache() throws {
        let device = try device()
        let renderer = try MetalTerminalRenderer(
            device: device,
            library: try makeLibrary(device: device),
            metrics: metrics()
        )
        let cols = 6
        let rows = 3
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: cols * 10, height: rows * 20, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = renderer.clearColor

        let viewport = TerminalMetalViewport(
            drawableWidth: Float(cols * 10), drawableHeight: Float(rows * 20))
        let stats = renderer.render(
            frame: Self.staticFrame(cols: cols, rows: rows, fill: "x"),
            viewport: viewport,
            descriptor: pass,
            waitUntilCompleted: true)
        XCTAssertEqual(stats.presentation, .committedOffscreen)
        XCTAssertTrue(stats.presentation.wasSubmitted)
        XCTAssertFalse(stats.presentation.leavesStalePixels)

        // Proves the readback path itself, so a later comparison of two
        // buffers cannot pass by both being empty.
        let pixels = try readBack(target, device: device)
        XCTAssertEqual(pixels.count, cols * 10 * rows * 20 * 4)
        XCTAssertTrue(pixels.contains { $0 != 0 }, "the blit read back nothing at all")

        // Incremental performance is the reason the cache exists: a submitted
        // frame keeps it, so an unchanged row is not replanned.
        let again = renderer.plan(
            frame: Self.staticFrame(cols: cols, rows: rows, fill: "x", damagedRows: []),
            viewport: viewport)
        XCTAssertEqual(again.replannedRows, 0, "a submitted frame must keep its row cache")
    }

    // MARK: - Fixtures for the renderer-level tests

    static func staticFrame(
        cols: Int,
        rows: Int,
        fill: Character,
        damagedRows: [UInt32]? = nil
    ) -> FfiRenderFrame {
        let scalar = fill.unicodeScalars.first!.value
        var bytes = [UInt8]()
        bytes.reserveCapacity(cols * rows * TerminalCell.byteSize)
        for _ in 0..<(cols * rows) {
            bytes.append(UInt8(truncatingIfNeeded: scalar))
            bytes.append(UInt8(truncatingIfNeeded: scalar >> 8))
            bytes.append(UInt8(truncatingIfNeeded: scalar >> 16))
            bytes.append(UInt8(truncatingIfNeeded: scalar >> 24))
            bytes.append(contentsOf: [0xff, 0xff, 0xff])
            bytes.append(contentsOf: [0x00, 0x00, 0x00])
            while bytes.count % TerminalCell.byteSize != 0 { bytes.append(0) }
        }
        return FfiRenderFrame(
            snapshot: FfiSnapshot(
                cols: UInt32(cols),
                rows: UInt32(rows),
                cursorRow: 0,
                cursorCol: 0,
                cursorVisible: false,
                cursorStyle: FfiCursorStyle(shape: .block, blinking: false),
                title: "presentation",
                modes: FfiTerminalModes(
                    autowrap: true,
                    originMode: false,
                    cursorKeyAppMode: false,
                    mouseTracking: .off,
                    mouseUtf8: false,
                    mouseSgr: false,
                    focusEvents: false,
                    bracketedPaste: false
                ),
                viewportOffset: 0,
                scrollbackLen: 0,
                damagedRows: damagedRows ?? Array(0..<UInt32(rows)),
                selection: nil,
                graphicsPlacements: []
            ),
            packedCells: Data(bytes),
            epoch: 0
        )
    }

    // MARK: - The surface, end to end

}
