/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import XCTest

final class TakoPermanentSidebarUITests: TakoCustomConfigCase {
    override func setUp() async throws {
        try await super.setUp()
        try updateConfig("""
        macos-titlebar-style = tabs
        tab-style = pill
        confirm-close-surface = false
        auto-update = off
        """)
    }

    @MainActor
    func testSidebarCannotBeHiddenAndCanvasReachesWindowEdges() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.defaultsSuiteName))
        defaults.set(false, forKey: "tako.session_sidebar_is_showing")
        XCTAssertTrue(defaults.synchronize())
        let app = try takoApplication()
        app.launch()
        let window = activeWindow(in: app)
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let sidebar = sidebar(in: app)
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        let terminal = window.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        let canvas = window.descendants(matching: .any)["FloatingTerminalCanvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        assertEdgeToEdgeCanvas(canvas, sidebar: sidebar, window: window)
        XCTAssertFalse(window.descendants(matching: .any)["tab-bar"].exists)
        XCTAssertFalse(window.buttons["workspace-pill"].exists)

        app.typeKey("s", modifierFlags: [.command, .option])
        XCTAssertTrue(sidebar.isHittable, "The former sidebar toggle must not hide navigation")
        let search = sidebar.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(sidebar.isHittable, "Escape must preserve permanent navigation")

        // Inside a floating pane, terminal rows must accept input and selection rather than drag chrome.
        search.click()
        let topRow = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.01))
        topRow.click()
        app.typeText("printf 'TOP''-EDGE-INPUT\\n'\n")
        waitForText("TOP-EDGE-INPUT", in: terminal)
        let beforeTerminalDrag = window.frame.origin
        topRow.press(forDuration: 0.1, thenDragTo: topRow.withOffset(CGVector(dx: 30, dy: 0)))
        XCTAssertEqual(window.frame.origin, beforeTerminalDrag, "Dragging inside terminal rows must not drag the window")

        app.menuBarItems["View"].firstMatch.click()
        XCTAssertFalse(app.menuItems["Hide Session Sidebar"].exists)
        XCTAssertFalse(app.menuItems["Show Session Sidebar"].exists)
        XCTAssertFalse(app.menuItems["Hide Sidebar"].exists)
        XCTAssertFalse(app.menuItems["Show Sidebar"].exists)
        app.typeKey(.escape, modifierFlags: [])
        attach(window, named: "Permanent sidebar and terminal at top edge")

        app.terminate()
        app.launch()
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "Navigation must also be visible after relaunch")
        XCTAssertTrue(sidebar.isHittable)
        XCTAssertFalse(activeWindow(in: app).descendants(matching: .any)["tab-bar"].exists)
    }

    @MainActor
    func testNewSessionAndPhysicalRowClicksReplaceTopTabNavigation() throws {
        let app = try takoApplication()
        app.launch()
        XCTAssertTrue(activeWindow(in: app).waitForExistence(timeout: 10))
        let firstTerminal = activeWindow(in: app).textViews.firstMatch
        XCTAssertTrue(firstTerminal.waitForExistence(timeout: 5))
        firstTerminal.click()
        app.typeText("printf 'SIDEBAR''-FIRST\\n'\n")
        waitForText("SIDEBAR-FIRST", in: firstTerminal)

        let firstRowID = try XCTUnwrap(sessionRows(in: app).first?.identifier)
        let newSession = sidebar(in: app).buttons["SessionSidebarNewSession"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 5))
        XCTAssertTrue(newSession.isHittable)
        newSession.click()
        waitForSessionCount(2, in: app)
        let secondRowID = try XCTUnwrap(sessionRows(in: app).first { $0.identifier != firstRowID }?.identifier)
        let secondTerminal = activeWindow(in: app).textViews.firstMatch
        XCTAssertTrue(secondTerminal.waitForExistence(timeout: 5))
        secondTerminal.click()
        app.typeText("printf 'SIDEBAR''-SECOND\\n'\n")
        waitForText("SIDEBAR-SECOND", in: secondTerminal)

        row(firstRowID, in: app).click()
        waitForText("SIDEBAR-FIRST", in: activeWindow(in: app).textViews.firstMatch)
        XCTAssertFalse((activeWindow(in: app).textViews.firstMatch.value as? String ?? "").contains("SIDEBAR-SECOND"))
        row(secondRowID, in: app).click()
        waitForText("SIDEBAR-SECOND", in: activeWindow(in: app).textViews.firstMatch)
        attach(activeWindow(in: app), named: "Session switched by sidebar click")

        app.typeKey("t", modifierFlags: .command)
        waitForSessionCount(3, in: app)
        XCTAssertTrue(sidebar(in: app).isHittable)
        row(firstRowID, in: app).click()
        waitForText("SIDEBAR-FIRST", in: activeWindow(in: app).textViews.firstMatch)
        let backgroundRow = row(secondRowID, in: app)
        backgroundRow.hover()
        let closeButton = backgroundRow.buttons["SessionSidebarCloseButton"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
        closeButton.click()
        waitForSessionCount(2, in: app)
        waitForText("SIDEBAR-FIRST", in: activeWindow(in: app).textViews.firstMatch)
        app.typeKey("w", modifierFlags: [.command, .option])
        waitForSessionCount(1, in: app)
        XCTAssertTrue(sidebar(in: app).isHittable)
    }

    @MainActor
    func testSidebarResizesWithoutCollapsingAndHeaderDragsWindow() throws {
        let app = try takoApplication()
        app.launch()
        let window = activeWindow(in: app)
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let sidebar = sidebar(in: app)
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        let handle = window.descendants(matching: .any)["SessionSidebarResizeHandle"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        let initialWidth = sidebar.frame.width
        let handleCenter = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        handleCenter.press(forDuration: 0.1, thenDragTo: handleCenter.withOffset(CGVector(dx: 70, dy: 0)))
        XCTAssertGreaterThan(sidebar.frame.width, initialWidth + 20)

        let resizedHandle = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        resizedHandle.press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)))
        XCTAssertGreaterThan(sidebar.frame.width, 100, "Dragging to the edge must retain a usable sidebar")
        XCTAssertTrue(sidebar.isHittable)

        let dragRegion = window.descendants(matching: .any)["SidebarWindowDragRegion"]
        XCTAssertTrue(dragRegion.waitForExistence(timeout: 5))
        let original = window.frame.origin
        let dragStart = dragRegion.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        dragStart.press(forDuration: 0.1, thenDragTo: dragStart.withOffset(CGVector(dx: 80, dy: 80)))
        XCTAssertGreaterThan(hypot(window.frame.minX - original.x, window.frame.minY - original.y), 25)
        assertEdgeToEdgeCanvas(window.descendants(matching: .any)["FloatingTerminalCanvas"].firstMatch,
                              sidebar: sidebar, window: window)
        attach(window, named: "Sidebar minimum width and window dragging")
    }

    @MainActor
    private func sidebar(in app: XCUIApplication) -> XCUIElement {
        activeWindow(in: app).descendants(matching: .any)["SessionSidebar"].firstMatch
    }

    @MainActor
    private func activeWindow(in app: XCUIApplication) -> XCUIElement {
        let owners = app.windows.matching(identifier: "TerminalWindowRestoration").allElementsBoundByIndex
        let candidates = owners.isEmpty ? app.windows.allElementsBoundByIndex : owners
        return candidates.first {
            $0.frame.height > 100 && $0.descendants(matching: .any)["SessionSidebar"].firstMatch.isHittable
        } ?? app.windows.firstMatch
    }

    @MainActor
    private func sessionRows(in app: XCUIApplication) -> [XCUIElement] {
        var seen: Set<String> = []
        return sidebar(in: app).descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "session-tab-"))
            .allElementsBoundByIndex.filter { $0.isHittable && seen.insert($0.identifier).inserted }
    }

    @MainActor
    private func row(_ id: String, in app: XCUIApplication) -> XCUIElement {
        let matches = sidebar(in: app).descendants(matching: .any).matching(identifier: id)
            .allElementsBoundByIndex.filter(\.isHittable)
        return matches.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            ?? sidebar(in: app).descendants(matching: .any)[id].firstMatch
    }

    @MainActor
    private func waitForSessionCount(_ count: Int, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate { [self] _, _ in sessionRows(in: app).count == count }
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: app)], timeout: 5), .completed,
                       "Expected \(count) visible session rows", file: file, line: line)
    }

    @MainActor
    private func waitForText(_ text: String, in terminal: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "value CONTAINS %@", text)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: terminal)], timeout: 5), .completed,
                       "Expected terminal output \(text)", file: file, line: line)
    }

    @MainActor
    private func assertEdgeToEdgeCanvas(_ canvas: XCUIElement, sidebar: XCUIElement, window: XCUIElement,
                                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(canvas.frame.minY, window.frame.minY, accuracy: 2, "No strip or titlebar gap above workspace", file: file, line: line)
        XCTAssertEqual(canvas.frame.maxY, window.frame.maxY, accuracy: 2, "Workspace reaches bottom edge", file: file, line: line)
        XCTAssertEqual(canvas.frame.maxX, window.frame.maxX, accuracy: 2, "No right margin", file: file, line: line)
        XCTAssertGreaterThanOrEqual(canvas.frame.minX, sidebar.frame.maxX - 2, file: file, line: line)
        XCTAssertTrue(canvas.exists, file: file, line: line)
    }

    @MainActor
    private func attach(_ window: XCUIElement, named name: String) {
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
