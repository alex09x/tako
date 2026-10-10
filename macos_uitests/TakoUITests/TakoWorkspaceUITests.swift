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
        XCTAssertTrue(window.tabs.element(boundBy: 1).waitForExistence(timeout: 3) || app.tabs.count >= 2, "Second tab should exist")

        // Click first tab
        let tab0 = app.tabs.element(boundBy: 0)
        if tab0.exists {
            tab0.click()
        }

        // Click second tab
        let tab1 = app.tabs.element(boundBy: 1)
        if tab1.exists {
            tab1.click()
        }
    }
}
