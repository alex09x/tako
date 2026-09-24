import XCTest
@testable import TakoCoreUI

/// What a consumer measuring display cadence is entitled to assume.
final class PresentationClockTests: XCTestCase {
    func testNothingPresentedReadsAsNothing() {
        XCTAssertEqual(TerminalPresentationClock().cadence, .none)
    }

    func testAPresentAdvancesSequenceAndTimeTogether() {
        let clock = TerminalPresentationClock()
        clock.record(presentedAt: 100)
        let first = clock.cadence
        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(first.presentedTime, 100)
        XCTAssertEqual(first.interval, 0, "there is no interval before a second frame")

        clock.record(presentedAt: 100.5)
        let second = clock.cadence
        XCTAssertEqual(second.sequence, 2)
        XCTAssertEqual(second.presentedTime, 100.5)
        XCTAssertEqual(second.interval, 0.5, accuracy: 1e-9)
    }

    /// A drawable that was never shown reports zero. Counting it would invent
    /// a frame that did not reach the display, which is exactly the mistake
    /// this signal exists to prevent.
    func testAZeroPresentationAdvancesNothing() {
        let clock = TerminalPresentationClock()
        clock.record(presentedAt: 0)
        XCTAssertEqual(clock.cadence, .none)

        clock.record(presentedAt: 10)
        clock.record(presentedAt: 0)
        XCTAssertEqual(clock.cadence.sequence, 1)
        XCTAssertEqual(clock.cadence.presentedTime, 10)
    }

    /// A handler that fires twice for one frame must not count it twice.
    func testADuplicateTimestampAdvancesNothing() {
        let clock = TerminalPresentationClock()
        clock.record(presentedAt: 10)
        clock.record(presentedAt: 10)
        XCTAssertEqual(clock.cadence.sequence, 1)
        XCTAssertEqual(clock.cadence.interval, 0)
    }

    /// An infinity would sit above every real presentation forever, so the
    /// ordering rule that protects the reading would then reject all of them.
    func testANonFiniteTimestampAdvancesNothingAndCannotPoisonTheClock() {
        let clock = TerminalPresentationClock()
        clock.record(presentedAt: .infinity)
        XCTAssertEqual(clock.cadence, .none)
        clock.record(presentedAt: .nan)
        XCTAssertEqual(clock.cadence, .none)

        // Real presentations still land afterwards.
        clock.record(presentedAt: 10)
        clock.record(presentedAt: 10.008)
        XCTAssertEqual(clock.cadence.sequence, 2)

        // And a later infinity does not lock the clock either.
        clock.record(presentedAt: .infinity)
        clock.record(presentedAt: 10.016)
        XCTAssertEqual(clock.cadence.sequence, 3)
        XCTAssertEqual(clock.cadence.presentedTime, 10.016)
    }

    /// Handlers that land out of order must not produce a negative interval.
    func testAnOlderTimestampAdvancesNothing() {
        let clock = TerminalPresentationClock()
        clock.record(presentedAt: 10)
        clock.record(presentedAt: 11)
        clock.record(presentedAt: 9)
        let cadence = clock.cadence
        XCTAssertEqual(cadence.sequence, 2)
        XCTAssertEqual(cadence.presentedTime, 11)
        XCTAssertGreaterThan(cadence.interval, 0, "an out-of-order handler produced a negative interval")
    }

    /// present -> a stretch with nothing presented -> present. The gap is
    /// visible in the interval and the sequence never goes backwards, which
    /// is what tells a consumer the display stalled rather than the counter.
    func testAStallIsVisibleAsAGapNotAsAReset() {
        let clock = TerminalPresentationClock()
        clock.record(presentedAt: 1.0)
        clock.record(presentedAt: 1.008)
        let before = clock.cadence

        // Resized, hidden, or no drawable available: nothing is presented.
        for _ in 0..<10 { clock.record(presentedAt: 0) }
        XCTAssertEqual(clock.cadence, before, "an unpresented frame changed the reading")

        clock.record(presentedAt: 1.508)
        let after = clock.cadence
        XCTAssertEqual(after.sequence, before.sequence + 1)
        XCTAssertEqual(after.interval, 0.5, accuracy: 1e-9, "the stall is not visible in the interval")
    }

    /// The reading is always internally consistent: the three fields come
    /// from one frame, so a sequence can never be paired with another frame's
    /// timestamp.
    func testConcurrentPresentsAndReadsStayCoherent() {
        let clock = TerminalPresentationClock()
        let presents = 2_000
        let done = expectation(description: "readers finished")
        done.expectedFulfillmentCount = 2

        DispatchQueue.global().async {
            for i in 1...presents {
                clock.record(presentedAt: CFTimeInterval(i) / 120.0)
            }
            done.fulfill()
        }
        DispatchQueue.global().async {
            var previous = TerminalPresentationCadence.none
            for _ in 0..<20_000 {
                let now = clock.cadence
                // Monotonic in both fields, together, always.
                XCTAssertGreaterThanOrEqual(now.sequence, previous.sequence)
                XCTAssertGreaterThanOrEqual(now.presentedTime, previous.presentedTime)
                if now.sequence > 0 {
                    // The pair must describe the same frame: frame n was
                    // presented at n/120.
                    XCTAssertEqual(now.presentedTime, CFTimeInterval(now.sequence) / 120.0, accuracy: 1e-12,
                                   "sequence and timestamp came from different frames")
                }
                previous = now
            }
            done.fulfill()
        }

        wait(for: [done], timeout: 30)
        XCTAssertEqual(clock.cadence.sequence, UInt64(presents))
    }
}

import Metal

/// Whatever builds a renderer decides whose clock it writes into. That is the
/// mechanism the surface relies on to outlive its renderers, so it is proven
/// here without needing a surface at all.
final class PresentationClockInjectionTests: XCTestCase {
    func testARendererWritesIntoTheClockItWasGiven() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakoCoreUI/Resources/TerminalShaders.metal")
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        let metrics = TerminalMetalCellMetrics(
            font: CTFontCreateWithName("Menlo" as CFString, 12, nil),
            cellWidth: 8, cellHeight: 16, ascent: 15, scale: 1)

        let shared = TerminalPresentationClock()
        shared.record(presentedAt: 5.0)

        // A replacement renderer, handed the clock that already has history.
        let renderer = try MetalTerminalRenderer(
            device: device, library: library, metrics: metrics, presentationClock: shared)

        XCTAssertEqual(renderer.presentationCadence.sequence, 1,
                       "the new renderer did not inherit the count it was given")
        renderer.presentationClock.record(presentedAt: 5.008)
        XCTAssertEqual(shared.cadence.sequence, 2)
        XCTAssertEqual(shared.cadence.interval, 0.008, accuracy: 1e-9)
    }

    /// A renderer built without one still works; it simply keeps its own.
    func testARendererWithoutAClockKeepsItsOwn() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakoCoreUI/Resources/TerminalShaders.metal")
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        let renderer = try MetalTerminalRenderer(
            device: device, library: library,
            metrics: TerminalMetalCellMetrics(
                font: CTFontCreateWithName("Menlo" as CFString, 12, nil),
                cellWidth: 8, cellHeight: 16, ascent: 15, scale: 1))
        XCTAssertEqual(renderer.presentationCadence, .none)
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Metal

/// The cadence a consumer subscribes to belongs to the surface, not to
/// whichever renderer the surface happens to be using at the time.
@MainActor
final class PresentationClockLifetimeTests: XCTestCase {
    /// A library compiled from the shipped shader source, the way the other
    /// Metal tests do it. The bundle-resolved default library is not findable
    /// from the SPM test bundle, so without this the view builds no renderer
    /// and any test of the renderer path would quietly skip.
    private func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakoCoreUI/Resources/TerminalShaders.metal")
        return try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
    }

    /// A view that really has a Metal renderer, so nothing here can skip.
    private func makeViewWithRenderer() throws -> TakoTerminalNSView {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let library = try makeLibrary(device: device)
        // Must be installed before the view is built: the renderer is made
        // during initialisation.
        TakoTerminalNSView.metalLibraryProviderForTesting = { _ in library }
        addTeardownBlock { TakoTerminalNSView.metalLibraryProviderForTesting = nil }

        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// A theme change tears the renderer down and builds another. A sequence
    /// that restarted there would read to a consumer watching for stalls
    /// exactly like the display having stopped.
    func testTheSequenceSurvivesARendererRebuild() throws {
        let view = try makeViewWithRenderer()
        let renderer = try XCTUnwrap(view.metalRendererForTesting)
        // Through the renderer that is actually drawing this surface.
        renderer.presentationClock.record(presentedAt: 1.0)
        renderer.presentationClock.record(presentedAt: 1.008)
        let before = view.presentationCadence
        XCTAssertEqual(before.sequence, 2)

        // Any of theme, font or backing scale does this; the theme is the
        // cheapest to drive from a test.
        var theme = view.theme
        theme.cellHeight = (theme.cellHeight ?? 16) + 1
        view.theme = theme

        let after = view.presentationCadence
        XCTAssertEqual(after.sequence, before.sequence,
                       "rebuilding the renderer reset the surface's frame count")
        XCTAssertEqual(after.presentedTime, before.presentedTime)

        // The replacement is a different renderer, and it keeps counting from
        // where the previous one left off.
        let replacement = try XCTUnwrap(view.metalRendererForTesting)
        XCTAssertFalse(replacement === renderer, "the renderer was not actually replaced")
        replacement.presentationClock.record(presentedAt: 1.016)
        XCTAssertEqual(view.presentationCadence.sequence, 3)
        XCTAssertEqual(view.presentationCadence.interval, 0.008, accuracy: 1e-9)
    }

    /// The production surface hands its own clock to the renderer it builds.
    ///
    /// Advanced through the renderer that is actually drawing the view, read
    /// back through the public snapshot -- the two ends of the wiring a
    /// consumer depends on. Cannot skip: the renderer is built deterministically.
    func testTheSurfaceRendererSharesTheSurfaceClock() throws {
        let view = try makeViewWithRenderer()
        let renderer = try XCTUnwrap(
            view.metalRendererForTesting,
            "the view built no renderer even with a library provided")

        renderer.presentationClock.record(presentedAt: 2.0)

        XCTAssertEqual(view.presentationCadence.sequence, 1,
                       "the renderer is writing somewhere the surface cannot read")
        XCTAssertEqual(view.presentationCadence.presentedTime, 2.0)
        XCTAssertTrue(renderer.presentationClock === view.presentationClock,
                      "the renderer was given a different clock than the surface publishes")
    }
}
#endif
