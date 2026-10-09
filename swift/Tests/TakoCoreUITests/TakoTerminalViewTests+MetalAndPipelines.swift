/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

#if canImport(UIKit)
import Foundation
import Metal
import QuartzCore
import UIKit
import XCTest
@testable import TakoCoreUI

@MainActor
extension TakoTerminalViewTests {
    // MARK: - Metal rendering path

    /// Whichever path is live, one redraw pulls exactly one frame out of the
    /// engine -- never a snapshot and a packed buffer fetched separately,
    /// which is what would let the two describe different terminal states.
    func testRedrawPullsExactlyOneAtomicFrame() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.feed(data: Data("Atomic frame\r\n".utf8))

        let before = view.frameFetchCount
        view.redrawNow()

        if view.metalRenderer != nil {
            XCTAssertEqual(view.frameFetchCount, before + 1, "the Metal path draws one frame per redraw")
            XCTAssertNil(view.metalUnavailableReason)
        } else {
            XCTAssertNotNil(view.metalUnavailableReason, "no renderer means a stated reason")
            let fallbackBefore = view.frameFetchCount
            let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
                view.draw(view.bounds)
            }
            XCTAssertGreaterThan(image.size.width, 0)
            XCTAssertEqual(view.frameFetchCount, fallbackBefore + 1, "the CPU fallback draws one frame per pass")
        }
    }

    /// The one frame a redraw consumes is internally consistent: its packed
    /// payload is exactly as long as its own snapshot's grid claims.
    func testAtomicFrameCellsMatchItsOwnSnapshot() {
        let core = TakoCore(cols: 40, rows: 12)
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), core: core)
        view.feed(data: Data("One lock, one frame\r\n".utf8))

        let frame = view.core.renderFrame()
        let expected = Int(frame.snapshot.cols) * Int(frame.snapshot.rows) * TerminalCell.byteSize
        XCTAssertEqual(frame.packedCells.count, expected)
        XCTAssertEqual(
            TerminalMetalFramePlanner.validate(
                frame: frame,
                viewport: TerminalMetalViewport(drawableWidth: 800, drawableHeight: 600)
            ),
            .valid
        )
    }

    /// The layer is sized in drawable pixels, floored to whole ones and
    /// never zero: `nextDrawable()` vends nothing for an empty layer.
    func testDrawableSizeIsContentScaledPixels() {
        XCTAssertEqual(
            TakoTerminalView.drawableSize(for: CGSize(width: 100, height: 50), scale: 2),
            CGSize(width: 200, height: 100)
        )
        XCTAssertEqual(
            TakoTerminalView.drawableSize(for: CGSize(width: 100.4, height: 50.4), scale: 3),
            CGSize(width: 301, height: 151)
        )
        // Never zero, and never a scale below one point per pixel.
        XCTAssertEqual(
            TakoTerminalView.drawableSize(for: .zero, scale: 2),
            CGSize(width: 1, height: 1)
        )
        XCTAssertEqual(
            TakoTerminalView.drawableSize(for: CGSize(width: 10, height: 10), scale: 0),
            CGSize(width: 10, height: 10)
        )
    }

    /// Layout follows the bounds in points and the drawable in pixels.
    func testMetalLayerTracksBoundsOnLayout() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        view.layoutSubviews()

        guard let metal = view.metalLayer else {
            XCTAssertNotNil(view.metalUnavailableReason)
            return
        }
        XCTAssertEqual(metal.frame, view.bounds)
        XCTAssertEqual(metal.contentsScale, view.metalContentScale)
        XCTAssertEqual(
            metal.drawableSize,
            TakoTerminalView.drawableSize(for: view.bounds.size, scale: view.metalContentScale)
        )
        XCTAssertEqual(metal.pixelFormat, view.metalRenderer?.colorPixelFormat)
    }

    /// A theme or font change rebuilds every renderer-dependent object and
    /// leaves exactly one layer and one display link behind it.
    func testThemeChangeRebuildsRendererStateWithoutDuplicates() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let firstCellHeight = view.renderer.metrics.cellHeight
        let firstBuildCount = view.rendererBuildCount
        let firstLink = view.displayLink

        var theme = TerminalTheme.takoDefault
        theme.fontSize = 20
        theme.background = srgb(r: 0x10, g: 0x20, b: 0x30)
        view.theme = theme
        view.layoutSubviews()

        XCTAssertNotEqual(view.renderer.metrics.cellHeight, firstCellHeight, "a larger font means new cell metrics")
        XCTAssertEqual(view.rendererBuildCount, firstBuildCount + 1)
        XCTAssertLessThanOrEqual(metalLayerCount(in: view), 1, "a rebuild must not leave the old layer behind")
        XCTAssertTrue(firstLink === view.displayLink, "one display link outlives every rebuild")

        if let renderer = view.metalRenderer {
            XCTAssertEqual(renderer.planner.metrics.cellHeight, view.renderer.metrics.cellHeight)
            XCTAssertEqual(renderer.planner.palette.background, TakoTerminalView.metalPalette(for: theme).background)
        }
    }

    /// The iOS view hands its theme to the engine as base colors, as the
    /// macOS one does: a program resetting its colors lands on the theme,
    /// and a theme change recolors whatever the program left alone.
    func testThemeColorsBecomeTheEnginesBaseColors() throws {
        let core = TakoCore(cols: 20, rows: 2)
        var theme = TerminalTheme.takoDefault
        theme.foreground = srgb(r: 1, g: 2, b: 3)
        theme.palette[1] = srgb(r: 7, g: 8, b: 9)
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200), core: core, theme: theme)

        core.feed(bytes: Data("\u{1b}]10;#ffffff\u{07}\u{1b}]110\u{07}A\u{1b}[31mB".utf8))
        var a = try XCTUnwrap(core.getCell(row: 0, col: 0))
        let b = try XCTUnwrap(core.getCell(row: 0, col: 1))
        XCTAssertEqual([a.fgR, a.fgG, a.fgB], [1, 2, 3])
        XCTAssertEqual([b.fgR, b.fgG, b.fgB], [7, 8, 9])

        theme.foreground = srgb(r: 4, g: 5, b: 6)
        view.theme = theme
        a = try XCTUnwrap(core.getCell(row: 0, col: 0))
        XCTAssertEqual([a.fgR, a.fgG, a.fgB], [4, 5, 6])
    }

    /// Repeated layout, redraws and rebuilds never accumulate a second
    /// timer, a second display link or a second layer.
    func testNoDuplicateTimersDisplayLinksOrLayers() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let blinkTimer = view.blinkTimer
        let link = view.displayLink

        for width in [200.0, 400.0, 640.0] {
            view.frame = CGRect(x: 0, y: 0, width: width, height: 480)
            view.layoutSubviews()
            view.setNeedsDisplay()
            view.redrawNow()
        }

        XCTAssertTrue(blinkTimer === view.blinkTimer, "the blink timer is created once")
        XCTAssertTrue(link === view.displayLink, "layout must not add a second display link")
        XCTAssertLessThanOrEqual(metalLayerCount(in: view), 1)
    }

    /// Redraw requests coalesce: any number between two frames draws one.
    func testRedrawRequestsCoalesceIntoOnePendingFrame() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.redrawNow()
        XCTAssertFalse(view.redrawPending)

        view.setNeedsDisplay()
        view.setNeedsDisplay()
        view.scrollViewportUp(lines: 1)
        XCTAssertTrue(view.redrawPending)

        let before = view.frameFetchCount
        view.redrawNow()
        XCTAssertFalse(view.redrawPending)
        if view.metalRenderer != nil {
            XCTAssertEqual(view.frameFetchCount, before + 1, "three requests, one frame")
        }
        if let link = view.displayLink {
            XCTAssertFalse(link.isPaused, "a pending redraw un-pauses the link")
        }
    }

    /// With no device, no library or no pipeline, the CoreText path keeps
    /// drawing and every input behaviour is unchanged.
    func testCPUFallbackWhenMetalIsUnavailable() {
        TakoTerminalView.isMetalDisabledForTesting = true
        defer { TakoTerminalView.isMetalDisabledForTesting = false }

        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        XCTAssertNil(view.metalRenderer)
        XCTAssertNil(view.metalLayer)
        XCTAssertNil(view.displayLink, "no renderer means no display link to drive it")
        XCTAssertNotNil(view.metalUnavailableReason)
        XCTAssertEqual(metalLayerCount(in: view), 0)

        view.feed(data: Data("Fallback line\r\n".utf8))
        let before = view.frameFetchCount
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.draw(view.bounds)
        }
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertEqual(view.frameFetchCount, before + 1)

        view.insertText("a")
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "a")
        XCTAssertTrue(view.plainText(startRow: 0, maxRows: 2).contains("Fallback line"))
    }

    /// The theme's `CGColor`s reach the planner as the components the
    /// shaders expect, alpha included.
    func testMetalPaletteMirrorsTheTheme() {
        var theme = TerminalTheme.takoDefault
        theme.backgroundOpacity = 0.5
        let palette = TakoTerminalView.metalPalette(for: theme)

        XCTAssertEqual(palette.background.x, Float(0x14) / 255, accuracy: 1e-3)
        XCTAssertEqual(palette.background.y, Float(0x10) / 255, accuracy: 1e-3)
        XCTAssertEqual(palette.background.z, Float(0x0e) / 255, accuracy: 1e-3)
        XCTAssertEqual(palette.background.w, 0.5, accuracy: 1e-6)
        XCTAssertEqual(palette.foreground.x, Float(0xed) / 255, accuracy: 1e-3)
        XCTAssertEqual(palette.cursor.x, Float(0xf4) / 255, accuracy: 1e-3)
        XCTAssertEqual(palette.cursor.w, 1, accuracy: 1e-6)
    }

    /// The display link holds the view weakly, so nothing keeps it alive
    /// after its host lets go and the GPU objects go with it.
    func testViewDeallocatesReleasingRendererAndDisplayLink() {
        weak var weakView: TakoTerminalView?
        weak var weakRenderer: MetalTerminalRenderer?
        autoreleasepool {
            let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            view.feed(data: Data("Lifecycle\r\n".utf8))
            view.redrawNow()
            weakView = view
            weakRenderer = view.metalRenderer
        }
        XCTAssertNil(weakView, "a retained display link or timer would keep the view alive")
        XCTAssertNil(weakRenderer)
    }

    func metalLayerCount(in view: TakoTerminalView) -> Int {
        (view.layer.sublayers ?? []).filter { $0 is CAMetalLayer }.count
    }

    func testResponderActivationRequiredForEditMenu() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.feed(data: Data("Responder Test\r\n".utf8))

        let longPressSel = Selector(("handleLongPress:"))
        let longPress = MockLongPressGestureRecognizer()

        view.core.startSelection(row: 0, col: 0, mode: .linear)
        view.core.extendSelection(row: 0, col: 4)

        // View is not in a UIWindow, so becomeFirstResponder() returns false
        longPress.state = .ended
        _ = view.perform(longPressSel, with: longPress)

        // Unattached view cannot become first responder, so edit menu should not present
        XCTAssertFalse(view.isFirstResponder)
    }

    // MARK: - The view's own parser coordination

    /// Let whatever the parser scheduled onto Main actually run.
    @MainActor
    func drainMainQueue(for interval: TimeInterval = 0.2) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: interval))
    }

    /// `feed(data:)` keeps its synchronous contract -- the bytes have been
    /// parsed, the delegate has its reply and the redraw is scheduled before
    /// it returns -- without the engine ever running on Main.
    @MainActor
    func testFeedStaysSynchronousWhileParsingOffMain() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        view.redrawNow()

        view.feed(data: Data("Off main\r\n\u{001B}]0;Synchronous\u{0007}\u{001B}[5n".utf8))

        XCTAssertTrue(view.plainText(startRow: 0, maxRows: 2).contains("Off main"))
        XCTAssertEqual(delegate.lastTitle, "Synchronous")
        XCTAssertFalse(delegate.deviceReplyDataReceived.isEmpty, "the reply is out before any input can depend on it")
        XCTAssertTrue(view.redrawPending)
        XCTAssertGreaterThanOrEqual(view.parserCoordinator.batchCount, 1)
        XCTAssertEqual(view.parserCoordinator.mainThreadBatchCount, 0, "the engine must never be driven from Main")
    }

    /// The asynchronous path applies its batches on Main, in feed order,
    /// with one application outstanding however long the burst.
    @MainActor
    func testEnqueueAppliesBurstsOnMainInOrder() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        for i in 0..<64 {
            view.enqueue(data: Data("\u{001B}]0;title-\(i)\u{0007}".utf8))
        }
        view.parserCoordinator.waitForParserQuiescence()
        drainMainQueue()

        XCTAssertEqual(delegate.lastTitle, "title-63", "the last title applied is the last one fed")
        XCTAssertEqual(view.parserCoordinator.peakOutstandingMainApplications, 1)
        XCTAssertEqual(view.parserCoordinator.mainThreadBatchCount, 0)
        XCTAssertEqual(view.parserCoordinator.appliedOutcomeCount, view.parserCoordinator.batchCount)
    }

    /// A view released with parser work still queued tears down cleanly and
    /// nothing is applied onto what is left of it.
    @MainActor
    func testViewReleasedWithParserWorkInFlight() {
        weak var weakView: TakoTerminalView?
        autoreleasepool {
            let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            for i in 0..<128 {
                view.enqueue(data: Data("in flight \(i)\r\n".utf8))
            }
            weakView = view
        }
        drainMainQueue()
        XCTAssertNil(weakView, "queued parser work must not keep the view alive")
    }
}
#endif
