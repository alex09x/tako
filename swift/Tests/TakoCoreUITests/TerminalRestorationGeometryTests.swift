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
import XCTest
@testable import TakoCoreUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// XCTest suite verifying terminal view initial geometry and layout dispatch:
/// - Custom initialCols/initialRows setup without defaulting to 80x24
/// - Immediate initial layout without the 50ms settle debounce delay
/// - Immediate forced grid resize without race conditions against PTY
@MainActor
final class TerminalRestorationGeometryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            TakoTerminalNSView.isMetalDisabledForTesting = true
        }
    }

    func testCustomInitialGeometryInitializesCoreAndProperties() {
        let view = TakoTerminalNSView(
            frame: .zero,
            initialCols: 169,
            initialRows: 41
        )
        XCTAssertEqual(view.cols, 169)
        XCTAssertEqual(view.rows, 41)
        XCTAssertEqual(Int(view.core.cols()), 169)
        XCTAssertEqual(Int(view.core.rows()), 41)
        XCTAssertFalse(view.hasCompletedInitialLayout)
    }

    func testDefaultInitialGeometryRemains80x24() {
        let view = TakoTerminalNSView(frame: .zero)
        XCTAssertEqual(view.cols, 80)
        XCTAssertEqual(view.rows, 24)
        XCTAssertEqual(Int(view.core.cols()), 80)
        XCTAssertEqual(Int(view.core.rows()), 24)
        XCTAssertFalse(view.hasCompletedInitialLayout)
    }

    func testInitialLayoutAppliesGeometryImmediatelyWithoutSettleDelay() {
        let view = TakoTerminalNSView(
            frame: .zero,
            initialCols: 80,
            initialRows: 24
        )
        XCTAssertFalse(view.hasCompletedInitialLayout)

        // Give the view a concrete bounds size (e.g. 1000 x 600)
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        view.layout()

        XCTAssertTrue(view.hasCompletedInitialLayout, "initial layout flag must be set")
        XCTAssertNil(view.pendingResizeWorkItem, "initial layout must not leave a pending work item")
        XCTAssertNil(view.pendingGridSize, "initial layout must not leave pending grid size")

        // Fitted size must be greater than zero and applied directly
        XCTAssertGreaterThan(view.cols, 0)
        XCTAssertGreaterThan(view.rows, 0)
        XCTAssertNotEqual(view.cols, 80, "geometry must be updated immediately to fit bounds")
        XCTAssertNotEqual(view.rows, 24)
    }

    func testImmediateGridResizeSynchronouslyUpdatesDimensions() {
        let view = TakoTerminalNSView(
            frame: .zero,
            initialCols: 80,
            initialRows: 24
        )
        XCTAssertEqual(view.cols, 80)
        XCTAssertEqual(view.rows, 24)

        view.scheduleGridResize(cols: 169, rows: 41, immediate: true)

        XCTAssertEqual(view.cols, 169, "immediate resize must apply columns synchronously")
        XCTAssertEqual(view.rows, 41, "immediate resize must apply rows synchronously")
        XCTAssertNil(view.pendingResizeWorkItem)
        XCTAssertNil(view.pendingGridSize)
    }

    func testNormalGridResizeDebouncesWithWorkItem() {
        let view = TakoTerminalNSView(
            frame: .zero,
            initialCols: 80,
            initialRows: 24
        )
        view.hasCompletedInitialLayout = true

        view.scheduleGridResize(cols: 120, rows: 35, immediate: false)

        XCTAssertEqual(view.cols, 80, "debounced resize must not change cols immediately")
        XCTAssertEqual(view.rows, 24, "debounced resize must not change rows immediately")
        XCTAssertNotNil(view.pendingResizeWorkItem, "debounced resize must schedule work item")
        XCTAssertEqual(view.pendingGridSize?.cols, 120)
        XCTAssertEqual(view.pendingGridSize?.rows, 35)

        view.flushPendingResizeForTesting()
        XCTAssertEqual(view.cols, 120)
        XCTAssertEqual(view.rows, 35)
    }
}
#endif
