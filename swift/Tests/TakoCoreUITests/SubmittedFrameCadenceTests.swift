import Metal
import QuartzCore
import XCTest
@testable import TakoCoreUI

/// The half of the cadence that says what this side did, paired with the half
/// that says what the display did.
///
/// Alone, a stalled presented sequence cannot tell a renderer that stopped
/// producing from a display that stopped showing. Together the pair does:
/// both advancing is healthy, submitted advancing alone puts the fault below
/// this surface, neither advancing puts it above.
final class SubmittedFrameCadenceTests: XCTestCase {

    // MARK: - The counter itself

    func testSubmittedAdvancesWithoutTouchingThePresentedHalf() {
        let clock = TerminalPresentationClock()
        clock.recordSubmitted()
        clock.recordSubmitted()
        clock.recordSubmitted()

        let cadence = clock.cadence
        XCTAssertEqual(cadence.submitted, 3)
        XCTAssertEqual(cadence.sequence, 0, "frames drawn were counted as frames shown")
        XCTAssertEqual(cadence.presentedTime, 0)
        XCTAssertEqual(cadence.interval, 0)
    }

    /// The shape that says the fault is below this surface.
    func testDrawnButNeverShownIsReadableAsSuch() {
        let clock = TerminalPresentationClock()
        clock.record(presentedAt: 1.0)
        clock.recordSubmitted()

        for _ in 0..<20 { clock.recordSubmitted() }

        let cadence = clock.cadence
        XCTAssertEqual(cadence.submitted, 21)
        XCTAssertEqual(cadence.sequence, 1, "nothing reached the display after the first frame")
        XCTAssertEqual(cadence.presentedTime, 1.0, "the last present is still the last present")
    }

    /// The healthy shape: both halves move together.
    func testBothHalvesAdvanceTogetherWhenFramesAreShown() {
        let clock = TerminalPresentationClock()
        for i in 1...5 {
            clock.recordSubmitted()
            clock.record(presentedAt: CFTimeInterval(i) / 120.0)
        }
        let cadence = clock.cadence
        XCTAssertEqual(cadence.submitted, 5)
        XCTAssertEqual(cadence.sequence, 5)
        XCTAssertEqual(cadence.interval, 1.0 / 120.0, accuracy: 1e-12)
    }

    /// Both halves are read from one snapshot, so they cannot be sampled from
    /// different moments.
    func testTheTwoHalvesAreReadCoherently() {
        let clock = TerminalPresentationClock()
        let done = expectation(description: "finished")
        done.expectedFulfillmentCount = 2

        DispatchQueue.global().async {
            for i in 1...2_000 {
                clock.recordSubmitted()
                clock.record(presentedAt: CFTimeInterval(i) / 120.0)
            }
            done.fulfill()
        }
        DispatchQueue.global().async {
            var previous = TerminalPresentationCadence.none
            for _ in 0..<20_000 {
                let now = clock.cadence
                XCTAssertGreaterThanOrEqual(now.submitted, previous.submitted)
                XCTAssertGreaterThanOrEqual(now.sequence, previous.sequence)
                // Submitted is written first, so a frame can be drawn and not
                // yet shown, but never shown without having been drawn.
                XCTAssertGreaterThanOrEqual(
                    now.submitted, now.sequence,
                    "a frame was counted as shown that was never counted as drawn")
                previous = now
            }
            done.fulfill()
        }

        wait(for: [done], timeout: 30)
        XCTAssertEqual(clock.cadence.submitted, 2_000)
        XCTAssertEqual(clock.cadence.sequence, 2_000)
    }

    // MARK: - What the render path actually counts

    private func device() throws -> MTLDevice {
        try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
    }

    private func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakoCoreUI/Resources/TerminalShaders.metal")
        return try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
    }

    private func makeRenderer(_ device: MTLDevice) throws -> MetalTerminalRenderer {
        try MetalTerminalRenderer(
            device: device,
            library: try makeLibrary(device: device),
            metrics: TerminalMetalCellMetrics(
                font: CTFontCreateWithName("Menlo" as CFString, 12, nil),
                cellWidth: 10, cellHeight: 20, ascent: 15, scale: 1))
    }

    private func makeLayer(_ renderer: MetalTerminalRenderer, cols: Int, rows: Int) -> CAMetalLayer {
        let layer = CAMetalLayer()
        renderer.configure(layer: layer)
        layer.drawableSize = CGSize(width: cols * 10, height: rows * 20)
        return layer
    }

    private func frame(cols: Int, rows: Int, packedRows: Int? = nil) -> FfiRenderFrame {
        var bytes = [UInt8]()
        for _ in 0..<((packedRows ?? rows) * cols) {
            bytes.append(contentsOf: [32, 0, 0, 0])
            bytes.append(contentsOf: [255, 255, 255])
            bytes.append(contentsOf: [0, 0, 0])
            bytes.append(contentsOf: [0, 0])
            bytes.append(0)
            bytes.append(contentsOf: [255, 255, 255])
        }
        return FfiRenderFrame(
            snapshot: FfiSnapshot(
                cols: UInt32(cols),
                rows: UInt32(rows),
                cursorRow: 0, cursorCol: 0, cursorVisible: false,
                cursorStyle: FfiCursorStyle(shape: .block, blinking: false),
                title: "submitted",
                modes: FfiTerminalModes(
                    autowrap: true, originMode: false, cursorKeyAppMode: false,
                    mouseTracking: .off, mouseUtf8: false, mouseSgr: false,
                    focusEvents: false, bracketedPaste: false),
                viewportOffset: 0, scrollbackLen: 0,
                damagedRows: Array(0..<UInt32(rows)),
                selection: nil, graphicsPlacements: []),
            packedCells: Data(bytes),
            epoch: 0)
    }

    /// A frame that reached a real drawable and was committed counts.
    func testADrawableBackedCommitCounts() throws {
        let device = try device()
        let renderer = try makeRenderer(device)
        let layer = makeLayer(renderer, cols: 8, rows: 4)
        XCTAssertEqual(renderer.presentationCadence.submitted, 0)

        let stats = renderer.render(frame: frame(cols: 8, rows: 4), in: layer)

        XCTAssertEqual(stats.presentation, .presented)
        XCTAssertEqual(renderer.presentationCadence.submitted, 1,
                       "a frame that was handed to the display was not counted")
    }

    /// An offscreen capture is not on its way to any display.
    func testAnOffscreenRenderIsNotCounted() throws {
        let device = try device()
        let renderer = try makeRenderer(device)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 80, height: 80, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store

        let stats = renderer.render(
            frame: frame(cols: 8, rows: 4),
            viewport: TerminalMetalViewport(drawableWidth: 80, drawableHeight: 80),
            descriptor: pass,
            waitUntilCompleted: true)

        XCTAssertEqual(stats.presentation, .committedOffscreen)
        XCTAssertEqual(renderer.presentationCadence.submitted, 0,
                       "an offscreen capture was counted as handed to a display")
        XCTAssertEqual(renderer.presentationCadence.sequence, 0)
    }

    /// No drawable means nothing was drawn into anything.
    func testAFrameWithNoDrawableIsNotCounted() throws {
        let device = try device()
        let renderer = try makeRenderer(device)
        let layer = makeLayer(renderer, cols: 8, rows: 4)
        renderer.nextDrawableProvider = { _ in nil }

        let stats = renderer.render(frame: frame(cols: 8, rows: 4), in: layer)

        XCTAssertEqual(stats.presentation, .noDrawable)
        XCTAssertEqual(renderer.presentationCadence.submitted, 0,
                       "a frame with nowhere to draw was counted as submitted")
    }

    /// A frame rejected before drawing never reached the render path.
    func testAnUnrenderableFrameIsNotCounted() throws {
        let device = try device()
        let renderer = try makeRenderer(device)
        let layer = makeLayer(renderer, cols: 8, rows: 4)

        // Says four rows, carries one: truncated, and refused before drawing.
        let stats = renderer.render(frame: frame(cols: 8, rows: 4, packedRows: 1), in: layer)

        XCTAssertEqual(stats.presentation, .notSubmitted)
        XCTAssertFalse(stats.isRenderable)
        XCTAssertEqual(renderer.presentationCadence.submitted, 0,
                       "a frame that was never drawn was counted as submitted")
    }

    /// Counting is per surface, not per renderer.
    func testTheCountSurvivesARendererRebuild() throws {
        let device = try device()
        let clock = TerminalPresentationClock()

        let first = try MetalTerminalRenderer(
            device: device,
            library: try makeLibrary(device: device),
            metrics: TerminalMetalCellMetrics(
                font: CTFontCreateWithName("Menlo" as CFString, 12, nil),
                cellWidth: 10, cellHeight: 20, ascent: 15, scale: 1),
            presentationClock: clock)
        let layer = makeLayer(first, cols: 8, rows: 4)
        _ = first.render(frame: frame(cols: 8, rows: 4), in: layer)
        XCTAssertEqual(clock.cadence.submitted, 1)

        // What a theme, font or scale change does: a different renderer, the
        // same surface, the same clock.
        let second = try MetalTerminalRenderer(
            device: device,
            library: try makeLibrary(device: device),
            metrics: TerminalMetalCellMetrics(
                font: CTFontCreateWithName("Menlo" as CFString, 12, nil),
                cellWidth: 10, cellHeight: 21, ascent: 15, scale: 1),
            presentationClock: clock)
        XCTAssertEqual(second.presentationCadence.submitted, 1,
                       "the replacement renderer restarted the count")

        let layer2 = makeLayer(second, cols: 8, rows: 4)
        _ = second.render(frame: frame(cols: 8, rows: 4), in: layer2)
        XCTAssertEqual(clock.cadence.submitted, 2,
                       "the count did not continue on the replacement renderer")
    }
}
