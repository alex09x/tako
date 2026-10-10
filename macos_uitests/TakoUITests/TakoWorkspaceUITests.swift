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

        // 1. Verify initial workspace pill is Default
        let wsPill = initialWindow.buttons["workspace-pill"]
        XCTAssertTrue(wsPill.waitForExistence(timeout: 5), "Workspace pill must exist in initial window")
        XCTAssertEqual(wsPill.value as? String, "Default", "Initial workspace should be Default")

        // 2. Create second tab in Default workspace (Tab 1) and select it
        app.typeKey("t", modifierFlags: .command)
        let tab0_ws1 = initialWindow.radioButtons["tab-0"]
        let tab1_ws1 = initialWindow.radioButtons["tab-1"]
        XCTAssertTrue(tab0_ws1.waitForExistence(timeout: 5), "Tab 0 must exist")
        XCTAssertTrue(tab1_ws1.waitForExistence(timeout: 5), "Tab 1 must exist")
        tab1_ws1.click()
        XCTAssertEqual(tab1_ws1.value as? Int, 1, "Tab 1 in Default workspace must be selected")

        // 3. Open workspace menu from pill and create a new workspace
        wsPill.click()
        let newWsItem = app.menuItems["New Workspace..."]
        XCTAssertTrue(newWsItem.waitForExistence(timeout: 3), "New Workspace... menu item should appear")
        newWsItem.click()

        let createBtn = app.buttons["Create"]
        XCTAssertTrue(createBtn.waitForExistence(timeout: 3), "Create button in modal alert should appear")
        createBtn.click()

        // 4. Verify second workspace window appears with distinct workspace name
        let newWindow = app.windows.firstMatch
        XCTAssertTrue(newWindow.waitForExistence(timeout: 5), "New workspace window must appear")
        let newWsPill = newWindow.buttons["workspace-pill"]
        XCTAssertTrue(newWsPill.waitForExistence(timeout: 5), "New workspace pill must appear")
        let newWsName = newWsPill.value as? String
        XCTAssertNotNil(newWsName)
        XCTAssertNotEqual(newWsName, "Default", "New workspace must have distinct identity from Default")

        // 5. Verify window dragging in new workspace
        let dragStart = newWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.03))
        let dragEnd = newWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.12))
        dragStart.press(forDuration: 0.1, thenDragTo: dragEnd)
        XCTAssertNotEqual(newWindow.frame.origin, initialFrame.origin, "New workspace window must be draggable")

        // 6. Switch back to Default workspace via Previous Workspace shortcut (Ctrl+Option+[)
        app.typeKey("[", modifierFlags: [.control, .option])
        XCTAssertTrue(initialWindow.waitForExistence(timeout: 5), "Default workspace window should return")
        let restoredPill = initialWindow.buttons["workspace-pill"]
        XCTAssertEqual(restoredPill.value as? String, "Default", "Active workspace should return to Default")

        // 7. Verify remembered tab selection in Default workspace (Tab 1 remains selected)
        XCTAssertEqual(initialWindow.radioButtons["tab-1"].value as? Int, 1, "Tab 1 in Default workspace should still be selected")

        // 8. Switch back to new workspace via Next Workspace shortcut (Ctrl+Option+])
        app.typeKey("]", modifierFlags: [.control, .option])
        XCTAssertTrue(newWindow.waitForExistence(timeout: 5), "New workspace window should return")
        XCTAssertEqual(newWindow.buttons["workspace-pill"].value as? String, newWsName, "Should return to new workspace")
    }
}
