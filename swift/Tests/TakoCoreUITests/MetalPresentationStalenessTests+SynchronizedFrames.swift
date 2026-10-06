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
    // MARK: - A synchronized frame is a delay, not a cancellation

    /// One line of the fixture screen. Letters, digits, spaces and
    /// punctuation, so a comparison of the drawn rows is a comparison of real
    /// glyph runs rather than of a solid block of one character.
    ///
    /// The scrollback lines this test scrolls through use the very same
    /// alphabet, only different numbers: a renderer that has drawn the tail
    /// has therefore already rasterized every glyph the history needs, and a
    /// second renderer that draws the tail alone builds a byte-identical
    /// atlas. Without that, two correct renders of the same text could still
    /// differ in atlas layout and the comparison below would be about
    /// packing rather than about pixels.
    static func fixtureLine(_ number: Int) -> String {
        "R\(number): tail, row \(number) . ok"
    }

    /// Pixels for a frame, rendered by a renderer built exactly like the
    /// view's -- a fresh, authoritative reference for what the glass ought to
    /// be showing. Never the assertion's subject: only its expectation.
    @MainActor
    func authoritativePixels(
        of frame: FfiRenderFrame,
        matching view: TakoTerminalView,
        device: MTLDevice,
        library: MTLLibrary,
        width: Int,
        height: Int
    ) throws -> [UInt8] {
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
            viewport: TerminalMetalViewport(drawableWidth: Float(width), drawableHeight: Float(height)),
            descriptor: pass,
            waitUntilCompleted: true)
        XCTAssertTrue(stats.isRenderable)
        return try readBack(target, device: device)
    }

    /// The tail comes back, on the glass, after a synchronized frame held its
    /// redraw.
    ///
    /// The shape on device: a screen is drawn, the user flicks back through
    /// scrollback, the app snaps the viewport home again -- and that frame is
    /// the one an exhausted drawable pool eats. It was pulled out of the
    /// engine, so it took the engine's damage with it; the layer never got
    /// it, so the glass still shows history. Then the app opens DEC private
    /// mode 2026. The next display-link tick refuses to draw a half-written
    /// frame, which is right, and pauses the link, which is also right --
    /// but it drops the frame that was still owed. When mode 2026 closes,
    /// the closing feed reports the only damage the engine still has, which
    /// is none, so nothing restarts the link. The terminal's text, its
    /// accessibility value and its viewport offset are all the restored tail;
    /// only the pixels are a screen the user scrolled away from.
    ///
    /// So the subject of the assertion is not a render, it is the frame the
    /// view's own `CAMetalLayer` path committed, blitted out of the drawable
    /// inside the very command buffer that presented it. It is compared byte
    /// for byte against a fresh authoritative render of the restored tail.
    @MainActor
    func testATailRestoredWhileMode2026HeldTheRedrawIsTheFrameThatEndsUpOnTheLayer() throws {
        let device = try device()
        let library = try makeLibrary(device: device)
        TakoTerminalView.metalLibraryProviderForTesting = { _ in library }
        defer { TakoTerminalView.metalLibraryProviderForTesting = nil }
        let previousOffscreenKinetic = TakoTerminalView.allowOffscreenKineticStepForTesting
        TakoTerminalView.allowOffscreenKineticStepForTesting = true
        defer { TakoTerminalView.allowOffscreenKineticStepForTesting = previousOffscreenKinetic }

        let cols = 40
        let rows = 24
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let cellWidth = view.renderer.metrics.cellWidth
        let cellHeight = view.renderer.metrics.cellHeight
        XCTAssertGreaterThan(cellWidth, 0, "no usable cell width")
        XCTAssertGreaterThan(cellHeight, 0, "no usable cell height")
        view.frame = CGRect(x: 0, y: 0, width: cellWidth * CGFloat(cols), height: cellHeight * CGFloat(rows))
        view.layoutSubviews()
        view.flushPendingResizeForTesting()

        let renderer = try XCTUnwrap(view.metalRenderer, "the view fell back to CoreText; expected metalRenderer")
        let layer = try XCTUnwrap(view.metalLayer, "the view fell back to CoreText; expected metalLayer")
        XCTAssertEqual(view.cols, cols)
        XCTAssertEqual(view.rows, rows)

        // The drawable is blit-readable only for this test; production leaves
        // `framebufferOnly` exactly as `configure(layer:)` set it.
        layer.framebufferOnly = false
        var committed: (frame: FfiRenderFrame, pixels: [UInt8])?
        var commitCount = 0
        renderer.committedFrameCaptureForTesting = { frame, pixels in
            committed = (frame, pixels)
            commitCount += 1
        }
        defer { renderer.committedFrameCaptureForTesting = nil }

        // 1. Scrollback to travel through, then the original tail painted row
        //    by row so the visible screen is exact and nothing scrolls.
        view.feed(data: Data("\u{1b}[?25l".utf8))
        var seed = ""
        for number in 101...180 { seed += Self.fixtureLine(number) + "\r\n" }
        view.feed(data: Data(seed.utf8))
        var tail = ""
        for row in 1...rows { tail += "\u{1b}[\(row);1H\u{1b}[2K" + Self.fixtureLine(row) }
        view.feed(data: Data(tail.utf8))
        XCTAssertGreaterThan(view.scrollbackLength, rows, "no history to travel through")
        XCTAssertEqual(view.viewportOffset, 0)

        view.displayLinkFired()
        XCTAssertEqual(view.lastFrameStatistics?.presentation, .presented, "the original tail never reached the layer")
        let originalTail = try XCTUnwrap(committed, "the presentation path committed nothing")
        XCTAssertEqual(commitCount, 1)
        let restoredRowsExpected = (11...rows).map(Self.fixtureLine)
        XCTAssertEqual(
            view.plainText(startRow: 10, maxRows: 14).components(separatedBy: "\n"),
            restoredRowsExpected,
            "the fixture's own rows 10-23 are not what the test claims to restore")

        // 2. Travel back through history: a direct scroll, then a kinetic
        //    flick carrying it further, both presented, so the glass really
        //    holds intermediate content and not the tail.
        view.scrollViewportUp(lines: 10)
        view.displayLinkFired()
        XCTAssertEqual(view.lastFrameStatistics?.presentation, .presented)

        view.startKineticScroll(initialVelocityY: 1500, location: CGPoint(x: 0, y: cellHeight * 2))
        XCTAssertTrue(view.isKineticScrolling, "the flick never engaged; the history leg proves nothing")
        for _ in 0..<6 {
            view.stepKineticScroll(deltaTime: 1.0 / 60.0)
            view.displayLinkFired()
        }
        XCTAssertGreaterThan(view.viewportOffset, 10, "the kinetic flick moved nothing")
        XCTAssertEqual(view.lastFrameStatistics?.presentation, .presented)
        let historyFrame = try XCTUnwrap(committed)
        let historyRows = view.plainText(startRow: 10, maxRows: 14).components(separatedBy: "\n")
        XCTAssertNotEqual(historyRows, restoredRowsExpected, "history and tail read the same; nothing was traversed")

        // 3. Restore the exact original tail into a pool that has nothing to
        //    hand out. The frame is pulled from the engine -- taking the
        //    engine's damage with it -- and then dropped, so the glass still
        //    shows history and the engine has nothing left to report.
        drainPool(of: renderer)
        view.scrollViewportToBottom()
        XCTAssertEqual(view.viewportOffset, 0, "the tail was not restored")
        XCTAssertFalse(view.isKineticScrolling, "snapping home must cancel kinetic momentum")
        let committedBeforeTheDrop = commitCount
        view.displayLinkFired()
        XCTAssertEqual(view.lastFrameStatistics?.presentation, .noDrawable)
        XCTAssertTrue(view.presentationRetryPending, "a frame that never reached the layer must still be owed")
        XCTAssertEqual(commitCount, committedBeforeTheDrop, "a dropped frame must commit nothing")

        // 4. A flick is live again when the app opens mode 2026, which has to
        //    cancel it: momentum must not scroll a screen mid-frame.
        view.startKineticScroll(initialVelocityY: 1500, location: CGPoint(x: 0, y: cellHeight * 2))
        XCTAssertTrue(view.isKineticScrolling)
        view.feed(data: Data("\u{1b}[?2026h".utf8))
        XCTAssertTrue(view.core.isSynchronizedOutputActive(), "mode 2026 never opened")
        XCTAssertFalse(view.isKineticScrolling, "an open synchronized frame must cancel kinetic momentum")
        XCTAssertEqual(view.viewportOffset, 0, "the cancelled flick moved the restored tail")

        // The tick inside the synchronized frame draws nothing and parks the
        // link. Correct -- and the moment the debt it is holding is forgotten.
        view.displayLinkFired()
        XCTAssertEqual(view.displayLink?.isPaused, true, "a synchronized frame must not spin the display link")
        XCTAssertTrue(view.presentationRetryPending)

        // 5. The pool recovers and the app closes its frame, carrying no
        //    damage of its own: everything it would have reported was already
        //    drained by the frame that was dropped in step 3.
        refillPool(of: renderer)
        view.feed(data: Data("\u{1b}[?2026l".utf8))
        XCTAssertFalse(view.core.isSynchronizedOutputActive())

        // 6. Settle the way a real surface settles: a paused CADisplayLink
        //    does not call its target, so ticking one here would paper over
        //    exactly the defect under test.
        var settleTicks = 0
        while view.displayLink?.isPaused == false && settleTicks < 32 {
            view.displayLinkFired()
            settleTicks += 1
        }
        XCTAssertGreaterThan(
            settleTicks, 0,
            "the display link settled paused while a frame was still owed: the closed synchronized "
            + "frame dropped the redraw it was holding and the layer keeps the history pixels")
        XCTAssertFalse(view.presentationRetryPending, "the surface settled still owing a frame")
        XCTAssertEqual(view.lastFrameStatistics?.presentation, .presented)
        XCTAssertGreaterThan(commitCount, committedBeforeTheDrop, "nothing new ever reached the layer")

        // 7. The comparison. The subject is what the view committed; the
        //    expectation is a fresh render of the terminal's own state.
        let settled = try XCTUnwrap(committed)
        let authoritative = view.core.renderFrame()
        let width = Int(layer.drawableSize.width)
        let height = Int(layer.drawableSize.height)
        XCTAssertGreaterThan(width, 0, "the layer has zero drawable width")
        XCTAssertGreaterThan(height, 0, "the layer has zero drawable height")

        XCTAssertEqual(
            view.plainText(startRow: 10, maxRows: 14).components(separatedBy: "\n"),
            restoredRowsExpected,
            "the engine's own rows 10-23 are not the restored tail")
        XCTAssertEqual(
            settled.frame.packedCells, authoritative.packedCells,
            "the committed frame is not the restored tail's cells")

        let expected = try authoritativePixels(
            of: authoritative, matching: view, device: device, library: library,
            width: width, height: height)
        let historyPixels = try authoritativePixels(
            of: historyFrame.frame, matching: view, device: device, library: library,
            width: width, height: height)

        // Guard against a vacuous comparison: history and tail genuinely
        // render to different pixels, so equality below means the frame was
        // redrawn rather than that every screen here looks alike.
        XCTAssertNotEqual(
            historyPixels, expected,
            "history and the restored tail render identically; the test proves nothing")

        XCTAssertEqual(settled.pixels.count, expected.count, "the committed frame is not the layer's size")
        let differing = zip(settled.pixels, expected).reduce(0) { $1.0 == $1.1 ? $0 : $0 + 1 }
        XCTAssertEqual(
            differing, 0,
            "\(differing) of \(expected.count) bytes the layer actually committed do not match a fresh "
            + "render of the restored tail: the screen the user scrolled away from is still on the glass")
        XCTAssertEqual(
            settled.pixels, originalTail.pixels,
            "the restored tail did not commit the same pixels the original tail did")
    }

    #endif

}
#endif
