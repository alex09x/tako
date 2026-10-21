/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import XCTest
@testable import TakoCoreUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Metal

/// A window dragged to a new size settles before the grid follows: the
/// Mac's terminal takes the last size 50 ms after the drag stops, once.
final class ResizeSettleTests: XCTestCase {
    @MainActor
    func testTheGridTakesTheLastSizeOnceTheResizeSettles() {
        let view = TakoTerminalNSView(frame: .zero, initialCols: 80, initialRows: 24)
        view.hasCompletedInitialLayout = true
        view.scheduleGridResize(cols: 100, rows: 30, immediate: false)
        view.scheduleGridResize(cols: 120, rows: 35, immediate: false)
        XCTAssertEqual(view.cols, 80, "the grid followed before the size settled")
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + TakoTerminalNSView.resizeSettleDelay + 0.1) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(view.cols, 120)
        XCTAssertEqual(view.rows, 35)
        XCTAssertNil(view.pendingResizeWorkItem)
        XCTAssertEqual(TakoTerminalNSView.resizeSettleDelay, 0.05)
    }

    /// The terminal's frames on the Mac: a view put in a window gets its
    /// display link asleep, a redraw wakes it, and a view leaving its window
    /// parks it.
    @MainActor
    func testTheTerminalsDisplayLinkSleepsWakesAndIsParkedOffWindow() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let shaders = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TakoCoreUI/Resources/TerminalShaders.metal")
        let library = try device.makeLibrary(source: String(contentsOf: shaders, encoding: .utf8), options: nil)
        TakoTerminalNSView.metalLibraryProviderForTesting = { _ in library }
        defer { TakoTerminalNSView.metalLibraryProviderForTesting = nil }
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        XCTAssertNil(view.displayLink, "a view with no window has no frames to take")
        window.contentView = view
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        let link = try XCTUnwrap(view.displayLink, "a view in a window got no display link")
        XCTAssertNotNil(view.metalRenderer, "no Metal renderer: the link has nothing to drive")
        view.scheduleRedraw()
        XCTAssertFalse(link.isPaused, "a redraw did not wake the link")
        view.removeFromSuperview()
        XCTAssertTrue(link.isPaused, "the link kept running off its window")
    }

    /// A capped surface waits out its throttle on the main queue, then
    /// presents: the throttle does not hold a frame back for good.
    @MainActor
    func testAPresentationThrottleLetsTheNextFrameThroughAfterItsDelay() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = view
        view.armPresentationThrottle(after: 0.05)
        XCTAssertNotNil(view.pendingPresentationThrottle, "nothing waits for the throttle")
        let done = expectation(description: "throttle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertNil(view.pendingPresentationThrottle, "the throttle never let the frame through")
    }
}
#endif

#if canImport(UIKit)
import UIKit

/// The phone's grid follows a new size 100 ms after it settles, once.
final class IOSResizeSettleTests: XCTestCase {
    @MainActor
    func testThePhonesGridTakesTheLastSizeOnceTheResizeSettles() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let start = (view.cols, view.rows)
        view.scheduleGridResize(cols: start.0 + 10, rows: start.1 + 4)
        view.scheduleGridResize(cols: start.0 + 20, rows: start.1 + 8)
        XCTAssertEqual(view.cols, start.0, "the grid followed before the size settled")
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + TakoTerminalView.resizeSettleDelay + 0.15) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(view.cols, start.0 + 20)
        XCTAssertEqual(view.rows, start.1 + 8)
        XCTAssertNil(view.pendingResizeWorkItem)
    }
}
#endif
