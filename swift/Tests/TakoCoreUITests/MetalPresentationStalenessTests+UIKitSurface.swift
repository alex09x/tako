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
import Metal
import XCTest
@testable import TakoCoreUI

#if canImport(UIKit)
import UIKit

extension MetalPresentationStalenessTests {
    /// The whole reported defect, reproduced and then held closed.
    ///
    /// An Agy-shaped 53x53 portrait alternate screen is repainted in full,
    /// swiped four times downward through DEC 1007 and eight times back, all
    /// through the synchronous `feed` path -- while the layer's drawable pool
    /// is empty, so not one of those frames can reach the glass. The surface
    /// is then allowed to settle exactly as it does on device: no new bytes,
    /// no new damage, only display-link ticks.
    ///
    /// What settles must be the current screen. The assertion is over actual
    /// GPU pixels: the frame that was genuinely presented is re-rendered
    /// through a fresh renderer and compared byte for byte against a fresh
    /// clean render of the terminal's authoritative state.
    @MainActor
    func testAgyStyleAlternateScreenSwipesSettleOnPixelsMatchingTheAuthoritativeText() throws {
        let device = try device()
        let library = try makeLibrary(device: device)
        TakoTerminalView.metalLibraryProviderForTesting = { _ in library }
        defer { TakoTerminalView.metalLibraryProviderForTesting = nil }

        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let cellWidth = view.renderer.metrics.cellWidth
        let cellHeight = view.renderer.metrics.cellHeight
        XCTAssertGreaterThan(cellWidth, 0, "no usable cell width")
        XCTAssertGreaterThan(cellHeight, 0, "no usable cell height")

        view.frame = CGRect(x: 0, y: 0, width: cellWidth * 53, height: cellHeight * 53)
        view.layoutSubviews()
        view.flushPendingResizeForTesting()

        let renderer = try XCTUnwrap(view.metalRenderer, "the view fell back to CoreText; expected metalRenderer")
        let layer = try XCTUnwrap(view.metalLayer, "the view fell back to CoreText; expected metalLayer")
        XCTAssertEqual(view.cols, 53)
        XCTAssertEqual(view.rows, 53)

        // An Agy-style full-screen repaint: every row addressed and erased
        // explicitly, so nothing scrolls and every row of the alternate
        // screen is rewritten. The numbers and the "Line" fragments mirror
        // the artifacts the device screenshots showed mixed together.
        func repaint(generation: Int) {
            var out = ""
            for row in 1...view.rows {
                out += "\u{1b}[\(row);1H\u{1b}[2K"
                out += "\(row) \(generation)L\(row * generation) . Line \(generation)-\(row)"
            }
            view.feed(data: Data(out.utf8))
        }

        /// One display-link's worth of work, remembering the frame that
        /// genuinely reached the layer. `redrawNow` fetches the frame itself;
        /// everything here is synchronous on Main, so the state read a line
        /// earlier is the state it plans.
        var lastPresented: FfiRenderFrame?
        func tick() {
            let planned = view.core.renderFrame()
            view.redrawNow()
            if view.lastFrameStatistics?.presentation == .presented {
                lastPresented = planned
            }
        }

        // 1. Enter the alternate screen the way a full-screen agent does:
        //    cursor hidden, DEC 1007 alternate scroll on, no mouse tracking.
        view.feed(data: Data("\u{1b}[?1049h\u{1b}[?25l\u{1b}[?1007h".utf8))
        XCTAssertTrue(view.isAlternateScreen)
        XCTAssertTrue(view.isAlternateScroll)
        repaint(generation: 1)
        tick()
        XCTAssertEqual(view.lastFrameStatistics?.presentation, .presented)
        let firstPresented = try XCTUnwrap(lastPresented)

        // 2. Drain the pool. From here nothing can reach the glass, which is
        //    what a burst of full-screen updates does on device.
        drainPool(of: renderer)

        // 3. A full-screen update, then bidirectional alternate-screen
        //    swipes: four down, eight back up, each one repainting the way
        //    the agent on the far end would. Every repaint goes through the
        //    synchronous `feed` path, so the engine's text is authoritative
        //    and settled by the time the last one returns.
        var generation = 1
        func swipe(_ direction: TerminalPanDirection, lines: Int) {
            let action = TerminalTouchScrollDecision.decide(
                lines: lines,
                direction: direction,
                modes: view.core.modes(),
                touchCol: 0,
                touchRow: view.rows / 2,
                core: view.core
            )
            guard case .sendInput(let data) = action, !data.isEmpty else {
                return XCTFail("an alternate screen with DEC 1007 must send arrow keys, got \(action)")
            }
            generation += 1
            repaint(generation: generation)
        }

        generation = 2
        repaint(generation: generation)
        tick()
        for _ in 0..<4 {
            swipe(.down, lines: 3)
            tick()
        }
        for _ in 0..<8 {
            swipe(.up, lines: 3)
            tick()
        }
        XCTAssertEqual(generation, 14, "twelve swipes, twelve repaints")

        XCTAssertEqual(
            view.lastFrameStatistics?.presentation, .noDrawable,
            "with the pool drained, no frame can have presented")
        XCTAssertTrue(
            view.presentationRetryPending,
            "a frame that never reached the layer must still be owed a redraw")
        XCTAssertGreaterThan(view.unpresentedFrameCount, 0)
        XCTAssertEqual(
            lastPresented?.packedCells, firstPresented.packedCells,
            "nothing should have presented while the pool was drained")

        // 4. The pool frees up and the surface is left to settle: no bytes,
        //    no damage, nothing but display-link ticks.
        refillPool(of: renderer)
        for _ in 0..<12 {
            let planned = view.core.renderFrame()
            view.displayLinkFired()
            if view.lastFrameStatistics?.presentation == .presented {
                lastPresented = planned
            }
            if !view.redrawPending && !view.presentationRetryPending { break }
        }
        XCTAssertFalse(view.presentationRetryPending, "the surface settled still owing a frame")

        // 5. The comparison, in pixels. Both sides go through a fresh
        //    renderer built exactly like the view's, so any difference is a
        //    difference in content rather than in renderer state.
        let authoritative = view.core.renderFrame()
        let width = Int(layer.drawableSize.width)
        let height = Int(layer.drawableSize.height)
        XCTAssertGreaterThan(width, 0, "the layer has zero drawable width")
        XCTAssertGreaterThan(height, 0, "the layer has zero drawable height")

        func cleanPixels(of frame: FfiRenderFrame) throws -> [UInt8] {
            let fresh = try MetalTerminalRenderer(
                device: device,
                library: library,
                metrics: TerminalMetalCellMetrics(view.renderer.metrics, scale: view.metalContentScale),
                palette: TakoTerminalView.metalPalette(for: view.theme)
            )
            fresh.planner.isFocused = view.isFirstResponder
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: fresh.colorPixelFormat, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = fresh.clearColor

            let stats = fresh.render(
                frame: frame,
                viewport: TerminalMetalViewport(
                    drawableWidth: Float(width), drawableHeight: Float(height)),
                descriptor: pass,
                waitUntilCompleted: true)
            XCTAssertTrue(stats.isRenderable)
            return try readBack(target, device: device)
        }

        let settled = try cleanPixels(of: try XCTUnwrap(lastPresented))
        let expected = try cleanPixels(of: authoritative)
        let stalePixels = try cleanPixels(of: firstPresented)

        // Guard against a vacuous comparison: the frame that was on the glass
        // when the pool ran dry genuinely differs from the settled text, so
        // an equal result below means the retry happened rather than that
        // every render of this screen looks the same.
        XCTAssertNotEqual(
            stalePixels, expected,
            "the stale frame and the settled text render identically; the test proves nothing")

        XCTAssertEqual(
            settled.count, expected.count, "the two renders disagreed about the drawable size")
        let differing = zip(settled, expected).reduce(0) { $1.0 == $1.1 ? $0 : $0 + 1 }
        XCTAssertEqual(
            differing, 0,
            "\(differing) of \(expected.count) bytes on the glass do not match a clean render of "
            + "the settled terminal text: old glyph rows survived a settled screen")
    }

    /// The other half of the same invariant, kept small and fast: a dropped
    /// frame leaves the view owing a redraw, and a display-link tick with no
    /// new damage at all is enough to pay it.
    @MainActor
    func testADroppedFrameIsRetriedByTheDisplayLinkWithoutNewDamage() throws {
        let device = try device()
        let library = try makeLibrary(device: device)
        TakoTerminalView.metalLibraryProviderForTesting = { _ in library }
        defer { TakoTerminalView.metalLibraryProviderForTesting = nil }

        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let _ = try XCTUnwrap(view.metalLayer, "the view fell back to CoreText; expected metalLayer")
        let renderer = try XCTUnwrap(view.metalRenderer, "the view fell back to CoreText; expected metalRenderer")

        view.feed(data: Data("before\r\n".utf8))
        view.redrawNow()
        XCTAssertEqual(view.lastFrameStatistics?.presentation, .presented)
        XCTAssertFalse(view.presentationRetryPending)

        drainPool(of: renderer)
        view.feed(data: Data("after\r\n".utf8))
        view.redrawNow()
        XCTAssertEqual(view.lastFrameStatistics?.presentation, .noDrawable)
        XCTAssertFalse(view.redrawPending, "the frame was consumed")
        XCTAssertTrue(view.presentationRetryPending, "but it never reached the layer")

        // Nothing new arrives; the link tick alone has to finish the job.
        refillPool(of: renderer)
        var presented = false
        for _ in 0..<12 {
            view.displayLinkFired()
            if view.lastFrameStatistics?.presentation == .presented { presented = true; break }
        }
        XCTAssertTrue(presented, "a dropped frame was never retried")
        XCTAssertFalse(view.presentationRetryPending)
        XCTAssertEqual(view.unpresentedFrameCount, 0)

        // A settled surface with nothing owed pauses its link again, so the
        // retry cannot become a permanent vsync tax.
        view.displayLinkFired()
        XCTAssertEqual(view.displayLink?.isPaused, true)
    }

    /// A surface with no area has no stale pixels to correct, and a retry
    /// armed against one would tick the display link every vsync for as long
    /// as the bounds stay degenerate. Collapsing to zero size clears it.
    @MainActor
    func testAZeroSizedSurfaceDoesNotHoldAPresentationRetryOpen() throws {
        let device = try device()
        let library = try makeLibrary(device: device)
        TakoTerminalView.metalLibraryProviderForTesting = { _ in library }
        defer { TakoTerminalView.metalLibraryProviderForTesting = nil }

        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let renderer = try XCTUnwrap(view.metalRenderer, "the view fell back to CoreText; expected metalRenderer")

        drainPool(of: renderer)
        view.feed(data: Data("dropped\r\n".utf8))
        view.redrawNow()
        XCTAssertTrue(view.presentationRetryPending)

        view.frame = .zero
        view.redrawNow()
        XCTAssertFalse(view.presentationRetryPending, "a zero-sized surface kept a retry armed")
        XCTAssertEqual(view.unpresentedFrameCount, 0)
        view.displayLinkFired()
        XCTAssertEqual(view.displayLink?.isPaused, true)
    }


}
#endif
