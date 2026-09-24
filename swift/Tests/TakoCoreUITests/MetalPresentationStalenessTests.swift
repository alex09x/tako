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

    private func device() throws -> MTLDevice {
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
    private func readBack(_ texture: MTLTexture, device: MTLDevice) throws -> [UInt8] {
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

    private static func staticFrame(
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

    #if canImport(UIKit)

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
    private static func fixtureLine(_ number: Int) -> String {
        "R\(number): tail, row \(number) . ok"
    }

    /// Pixels for a frame, rendered by a renderer built exactly like the
    /// view's -- a fresh, authoritative reference for what the glass ought to
    /// be showing. Never the assertion's subject: only its expectation.
    @MainActor
    private func authoritativePixels(
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
