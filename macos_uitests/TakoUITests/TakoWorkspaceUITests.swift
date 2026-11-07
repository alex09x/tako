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
    func testQuickTerminalKeepsItsContentBelowTheStrip() throws {
        try updateConfig("confirm-close-surface = false\n")
        let app = try takoApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.waitForNonExistence(timeout: 5), "Close the ordinary window before inspecting Quick Terminal")
        app.menuBarItems["View"].firstMatch.click()
        app.menuItems["Quick Terminal"].firstMatch.click()
        let quick = app.windows.firstMatch
        XCTAssertTrue(quick.waitForExistence(timeout: 5), "Quick Terminal must open")
        let terminal = quick.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        XCTAssertFalse(quick.descendants(matching: .any)["tab-bar"].exists, "Quick Terminal must not mount a top tab strip")
        XCTAssertFalse(quick.descendants(matching: .any)["SessionSidebar"].exists, "Quick Terminal must stay separate without the permanent desktop sidebar")
        XCTAssertTrue(terminal.isHittable)
        XCTAssertGreaterThan(terminal.frame.height, 0)
        XCTAssertEqual(terminal.frame.minY, quick.frame.minY, accuracy: 2, "Quick Terminal content must start right at the top edge")
        XCTAssertEqual(terminal.frame.maxY, quick.frame.maxY, accuracy: 2, "Quick Terminal content must reach the bottom edge")
    }

    @MainActor
    func testWorkspaceWindowDragging() throws {
        let app = try takoApplication()
        app.launch()

        let window = try activeTerminalWindow(app)
        let initialFrame = window.frame
        let dragRegion = window.descendants(matching: .any)["SidebarWindowDragRegion"].firstMatch
        XCTAssertTrue(dragRegion.waitForExistence(timeout: 5), "Permanent sidebar header drag region must exist")

        let dragStart = dragRegion.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
        let dragEnd = dragStart.withOffset(CGVector(dx: 140, dy: 50))
        dragStart.press(forDuration: 0.1, thenDragTo: dragEnd)

        let newFrame = window.frame
        XCTAssertNotEqual(initialFrame.origin, newFrame.origin, "Window origin should change after dragging sidebar header")
    }

    @MainActor
    func testTabCreationAndClickSwitching() throws {
        let app = try takoApplication()
        app.launch()

        let initialWindow = try activeTerminalWindow(app)
        let newSessionBtn = initialWindow.buttons["SessionSidebarNewSession"]
        XCTAssertTrue(newSessionBtn.waitForExistence(timeout: 5), "SessionSidebarNewSession button must exist")
        newSessionBtn.click()

        let rows = try waitForSessionRows(count: 2, in: app)
        let row0Id = try XCTUnwrap(rows.first?.identifier, "Expected first session row")
        let row1Id = try XCTUnwrap(rows.dropFirst().first?.identifier, "Expected second session row")
        XCTAssertNotEqual(row0Id, row1Id)

        try sessionRow(row0Id, in: app).click()
        XCTAssertEqual(try sessionRow(row0Id, in: app).value as? String, "selected", "First session must be selected after clicking it")
        XCTAssertEqual(try sessionRow(row1Id, in: app).value as? String, "unselected", "Second session must be unselected")

        try sessionRow(row1Id, in: app).click()
        XCTAssertEqual(try sessionRow(row1Id, in: app).value as? String, "selected", "Second session must be selected after clicking it")
        XCTAssertEqual(try sessionRow(row0Id, in: app).value as? String, "unselected", "First session must be unselected")
    }

    @MainActor
    func testNewWorkspaceWindowAndIsolation() async throws {
        continueAfterFailure = false
        let app = try takoApplication()
        app.launch()

        let defaultWindow = try activeTerminalWindow(app)
        XCTAssertFalse(defaultWindow.buttons["workspace-pill"].exists, "Top workspace-pill is replaced by permanent sidebar workspace tree")
        let defaultWsHeader = defaultWindow.descendants(matching: .any)["SessionSidebarWorkspace-Default"].firstMatch
        XCTAssertTrue(defaultWsHeader.waitForExistence(timeout: 5), "Default workspace header must exist in permanent sidebar")
        let defaultWsValue = defaultWsHeader.value as? String
        XCTAssertEqual(defaultWsValue, "active")
        guard defaultWsValue == "active" else { return }

        // Create second session in Default workspace and select it.
        app.typeKey("t", modifierFlags: .command)
        let defaultRows = try waitForSessionRows(count: 2, in: app)
        let rememberedTabId = try XCTUnwrap(
            defaultRows.dropFirst().first?.identifier,
            "Expected second session row in Default workspace"
        )
        try sessionRow(rememberedTabId, in: app).click()
        XCTAssertEqual(try sessionRow(rememberedTabId, in: app).value as? String, "selected")

        // Create a new workspace via the top-level Workspace menu.
        app.menuBarItems["Workspace"].firstMatch.click()
        let newWsItem = app.menuItems["New Workspace…"].firstMatch
        XCTAssertTrue(newWsItem.waitForExistence(timeout: 3), "New Workspace… menu item should appear")
        newWsItem.click()

        let createBtn = app.buttons["Create"].firstMatch
        XCTAssertTrue(createBtn.waitForExistence(timeout: 3), "Create button in workspace prompt should appear")
        createBtn.click()

        let newWsHeaderId = try await waitForActiveWorkspaceHeader(in: app, excluding: "SessionSidebarWorkspace-Default")
        let newWindow = try activeTerminalWindow(app)

        // Drag the new workspace window via its permanent sidebar header drag region.
        let preDragFrame = newWindow.frame
        let dragRegion = newWindow.descendants(matching: .any)["SidebarWindowDragRegion"].firstMatch
        XCTAssertTrue(dragRegion.waitForExistence(timeout: 5))
        let dragStart = dragRegion.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
        let dragEnd = dragStart.withOffset(CGVector(dx: 120, dy: 40))
        dragStart.press(forDuration: 0.1, thenDragTo: dragEnd)
        let postDragFrame = newWindow.frame
        XCTAssertNotEqual(postDragFrame.origin, preDragFrame.origin, "New workspace window must be draggable")
        XCTAssertGreaterThan(postDragFrame.origin.x, preDragFrame.origin.x + 10, "Window origin X should move right after drag")
        XCTAssertEqual(postDragFrame.size.width, preDragFrame.size.width, accuracy: 2.0)
        XCTAssertEqual(postDragFrame.size.height, preDragFrame.size.height, accuracy: 2.0)

        // Switch back to Default workspace via Previous Workspace shortcut (Ctrl+Option+[).
        app.typeKey("[", modifierFlags: [.control, .option])
        _ = try await waitForActiveWorkspaceHeader(in: app, matching: "SessionSidebarWorkspace-Default")
        let restoredTab = try sessionRow(rememberedTabId, in: app)
        XCTAssertEqual(restoredTab.value as? String, "selected", "Remembered session in Default workspace should stay selected")

        // Switch forward to new workspace via Next Workspace shortcut (Ctrl+Option+]).
        app.typeKey("]", modifierFlags: [.control, .option])
        _ = try await waitForActiveWorkspaceHeader(in: app, matching: newWsHeaderId)
    }

    private func activeTerminalWindow(_ app: XCUIApplication) throws -> XCUIElement {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.windows.allElementsBoundByIndex.contains { $0.textViews.firstMatch.isHittable }
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed, "Expected a hittable terminal window")
        return try XCTUnwrap(app.windows.allElementsBoundByIndex.first { $0.textViews.firstMatch.isHittable })
    }

    private func sessionRows(in window: XCUIElement) -> [XCUIElement] {
        var seen: Set<String> = []
        return window.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'session-tab-'"))
            .allElementsBoundByIndex
            .filter { $0.isHittable && seen.insert($0.identifier).inserted }
    }

    private func waitForSessionRows(count: Int, in app: XCUIApplication) throws -> [XCUIElement] {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let win = try? self.activeTerminalWindow(app) else { return false }
            return self.sessionRows(in: win).count == count
        }, object: app)
        let waitResult = XCTWaiter.wait(for: [ready], timeout: 5)
        XCTAssertEqual(waitResult, .completed, "Expected \(count) visible session rows")
        let rows = sessionRows(in: try activeTerminalWindow(app))
        guard waitResult == .completed, rows.count >= count else {
            throw NSError(domain: "TakoWorkspaceUITests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Expected \(count) visible session rows, got \(rows.count)"
            ])
        }
        return rows
    }

    private func sessionRow(_ identifier: String, in app: XCUIApplication) throws -> XCUIElement {
        let win = try activeTerminalWindow(app)
        let matches = win.descendants(matching: .any).matching(identifier: identifier).allElementsBoundByIndex.filter(\.isHittable)
        return try XCTUnwrap(matches.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }))
    }

    private func waitForActiveWorkspaceHeader(
        in app: XCUIApplication,
        matching exactId: String? = nil,
        excluding excludedId: String? = nil
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let win = try? activeTerminalWindow(app) {
                let headers = win.descendants(matching: .any)
                    .matching(NSPredicate(format: "identifier BEGINSWITH 'SessionSidebarWorkspace-'"))
                    .allElementsBoundByIndex
                if let active = headers.first(where: { el in
                    guard (el.value as? String) == "active" else { return false }
                    if let exactId, el.identifier != exactId { return false }
                    if let excludedId, el.identifier == excludedId { return false }
                    return true
                }) {
                    return active.identifier
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting for active workspace header (matching=\(String(describing: exactId)), excluding=\(String(describing: excludedId)))")
        throw NSError(domain: "TakoWorkspaceUITests", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Timed out waiting for active workspace header"
        ])
    }
}
