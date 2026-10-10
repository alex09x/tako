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

final class TakoWorkspaceUITests: TakoCustomConfigCase {
    override func setUp() async throws {
        try await super.setUp()
        try updateConfig(
            """
            macos-titlebar-style = tabs
            tab-style = pill
            title = "TakoWorkspaceUITests"
            """
        )
    }

    @MainActor
    func testWorkspaceWindowDragging() throws {
        let app = try takoApplication()
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "Terminal window should exist")
        let window = app.windows.firstMatch
        let initialFrame = window.frame

        // Drag window by clicking and dragging on the top titlebar row
        let dragStart = window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.03))
        let dragEnd = window.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.15))
        dragStart.press(forDuration: 0.1, thenDragTo: dragEnd)

        let newFrame = window.frame
        XCTAssertNotEqual(initialFrame.origin, newFrame.origin, "Window origin should change after dragging titlebar")
    }

    @MainActor
    func testTabCreationAndClickSwitching() throws {
        let app = try takoApplication()
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "Terminal window should exist")
        let window = app.windows.firstMatch

        // Create second tab with Cmd+T
        app.typeKey("t", modifierFlags: .command)

        let tab0 = window.radioButtons["tab-0"]
        let tab1 = window.radioButtons["tab-1"]
        XCTAssertTrue(tab0.waitForExistence(timeout: 5), "First tab element tab-0 must exist")
        XCTAssertTrue(tab1.waitForExistence(timeout: 5), "Second tab element tab-1 must exist")

        // Click first tab and assert selection postconditions
        tab0.click()
        XCTAssertEqual(tab0.value as? Int, 1, "Tab 0 must be selected after clicking it")
        XCTAssertEqual(tab1.value as? Int, 0, "Tab 1 must be unselected")

        // Click second tab and assert selection postconditions
        tab1.click()
        XCTAssertEqual(tab1.value as? Int, 1, "Tab 1 must be selected after clicking it")
        XCTAssertEqual(tab0.value as? Int, 0, "Tab 0 must be unselected")
    }

    @MainActor
    func testNewWorkspaceWindowAndIsolation() throws {
        let app = try takoApplication()
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "Terminal window should exist")
        let initialWindow = app.windows.firstMatch
        let initialFrame = initialWindow.frame

        // Switch to Next Workspace via menu shortcut Ctrl+Opt+]
        app.typeKey("]", modifierFlags: [.control, .option])

        // An active window for the new workspace should exist
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        let newWindow = app.windows.firstMatch

        // Drag the new workspace window by its titlebar
        let dragStart = newWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.03))
        let dragEnd = newWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.12))
        dragStart.press(forDuration: 0.1, thenDragTo: dragEnd)
        XCTAssertNotEqual(newWindow.frame.origin, initialFrame.origin, "New workspace window must be draggable")

        // Switch back to original workspace via Ctrl+Opt+[
        app.typeKey("[", modifierFlags: [.control, .option])
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
    }
}
