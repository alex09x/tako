/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//
//  TakoTitlebarTabsUITests.swift
//  Tako
//
//  Created by luca on 16.10.2025.
//

import AppKit
import XCTest

final class TakoTitlebarTabsUITests: TakoCustomConfigCase {
    override func setUp() async throws {
        try await super.setUp()

        try updateConfig(
            """
            macos-titlebar-style = tabs
            tab-style = pill
            title = "TakoTitlebarTabsUITests"
            confirm-close-surface = false
            """
        )
    }

    @MainActor
    func testCustomTitlebar() throws {
        let app = try takoApplication()
        app.launch()
        app.typeKey("t", modifierFlags: .command)
        try checkTabsGeometry(app, expectDragRegion: true)
    }

    @MainActor
    func testTabsGeometryInNormalWindow() throws {
        let app = try takoApplication()
        app.launch()
        try activeWindow(app).buttons["SessionSidebarNewSession"].click()
        try assertTabCount(2, in: app)
        try checkTabsGeometry(app, expectDragRegion: true)

        // Close the second session via its sidebar row context menu and verify one session remains.
        let secondRowId = try XCTUnwrap(sidebarRows(try activeWindow(app)).last)
        let secondRow = try sidebarRowElement(secondRowId, in: try activeWindow(app))
        secondRow.rightClick()
        let closeItem = app.menuItems["Close Session"].firstMatch
        XCTAssertTrue(closeItem.waitForExistence(timeout: 3))
        closeItem.click()
        try assertTabCount(1, in: app)
        XCTAssertTrue(try activeWindow(app).textViews.firstMatch.isHittable)
    }

    @MainActor
    func testTabsGeometryInFullscreen() throws {
        let app = try takoApplication()
        app.launch()
        app.typeKey("t", modifierFlags: .command)
        try assertTabCount(2, in: app)
        let normalFrame = try activeWindow(app).frame
        app.typeKey("f", modifierFlags: [.command, .control])
        try assertTabCount(2, in: app)
        XCTAssertGreaterThan(try activeWindow(app).frame.height, normalFrame.height,
                             "The geometry check must actually run in fullscreen")
        try checkTabsGeometry(app, expectDragRegion: false)
        app.typeKey("f", modifierFlags: [.command, .control])
        XCTAssertEqual(try activeWindow(app).frame.height, normalFrame.height, accuracy: 1,
                       "Exiting fullscreen must restore the original window geometry")
        try assertSidebarAndTerminalGeometry(app, count: 2, expectDragRegion: true)
    }

    @MainActor
    func testTabsGeometryAfterMovingTabs() throws {
        let app = try takoApplication()
        app.launch()
        app.typeKey("t", modifierFlags: .command)
        app.typeKey("t", modifierFlags: .command)
        try assertTabCount(3, in: app)
        let originalRows = Set(sidebarRows(try activeWindow(app)))
        XCTAssertEqual(originalRows.count, 3)

        app.typeKey("d", modifierFlags: .command)
        let source = try activeWindow(app)
        let handles = source.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane-drag-handle-'"))
        XCTAssertEqual(handles.count, 2)
        let movedID = handles.element(boundBy: 1).identifier

        // Cross-window detach drags the split pane outside the window into a new window with its own permanent sidebar.
        let outside = source.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: 60, dy: 0))
        source.buttons[movedID].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: outside)
        XCTAssertTrue(app.wait(for: \.windows.count, toEqual: 2, timeout: 2), "Detaching a pane must open a second visible window")
        let detached = try activeWindow(app)
        XCTAssertEqual(detached.textViews.count, 1)
        XCTAssertTrue(detached.textViews.firstMatch.isHittable)
        try assertSidebarAndTerminalGeometry(app, count: 4, expectDragRegion: true)

        let rows = Set(sidebarRows(try activeWindow(app)))
        XCTAssertEqual(rows.subtracting(originalRows).count, 1, "The detached pane must create exactly one new tab identity")
        XCTAssertTrue(originalRows.isSubset(of: rows))

        try joinTab(try XCTUnwrap(originalRows.sorted().first), in: app)
        try assertTabCount(4, in: app)
        XCTAssertEqual(app.windows.count, 1, "Rejoining must order out sibling windows")
        try checkTabsGeometry(app, expectDragRegion: true)
    }

    @MainActor
    func testTabsGeometryAfterMergingAllWindows() throws {
        let app = try takoApplication()
        app.launch()
        let firstRow = try XCTUnwrap(sidebarRows(try activeWindow(app)).first)
        app.typeKey("n", modifierFlags: .command)
        let secondRow = try XCTUnwrap(sidebarRows(try activeWindow(app)).first { $0 != firstRow })
        app.typeKey("n", modifierFlags: .command)
        XCTAssertEqual(app.windows.count, 3, "Three independent groups must exist before merging")

        try joinTab(firstRow, in: app)
        XCTAssertEqual(app.windows.count, 2)
        try joinTab(secondRow, in: app)
        try assertTabCount(3, in: app)
        XCTAssertEqual(app.windows.count, 1)
        try checkTabsGeometry(app, expectDragRegion: true)
    }

    private func activeWindow(_ app: XCUIApplication) throws -> XCUIElement {
        func resolve() -> XCUIElement? {
            let owners = app.windows.matching(identifier: "TerminalWindowRestoration").allElementsBoundByIndex.filter { window in
                let terminal = window.textViews.firstMatch
                return terminal.exists && window.frame.insetBy(dx: -1, dy: -1).contains(terminal.frame)
            }
            return owners.first { $0.textViews.firstMatch.isHittable } ?? owners.first
        }
        if let window = resolve() { return window }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in resolve() != nil }, object: app)
        let result = XCTWaiter.wait(for: [ready], timeout: 5)
        var screenshotPath = ""
        if result != .completed,
           let window = app.windows.allElementsBoundByIndex.max(by: { $0.frame.height < $1.frame.height }),
           let tiff = window.screenshot().image.tiffRepresentation,
           let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("tako-fullscreen-owner.png")
            try data.write(to: file)
            screenshotPath = file.path
        }
        let windows = app.debugDescription.components(separatedBy: "    MenuBar,").first ?? ""
        XCTAssertEqual(result, .completed, "No hittable terminal owner after the transition. Image: \(screenshotPath). \(windows)")
        return try XCTUnwrap(resolve())
    }

    private func sidebarRows(_ window: XCUIElement) -> [String] {
        var seen: Set<String> = []
        return window.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'session-tab-'"))
            .allElementsBoundByIndex
            .filter { $0.isHittable && seen.insert($0.identifier).inserted }
            .map(\.identifier)
    }

    private func sidebarRowElement(_ rowID: String, in window: XCUIElement) throws -> XCUIElement {
        let matches = window.descendants(matching: .any).matching(identifier: rowID).allElementsBoundByIndex.filter(\.isHittable)
        return try XCTUnwrap(matches.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }))
    }

    private func assertTabCount(_ count: Int, in app: XCUIApplication) throws {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let window = try? self.activeWindow(app) else { return false }
            return self.sidebarRows(window).count == count
        }, object: app)
        let matches = XCTWaiter.wait(for: [ready], timeout: 3) == .completed
        let window = try activeWindow(app)
        let actual = sidebarRows(window).count
        if !matches {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Unexpected session count: expected \(count), actual \(actual)"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let image = XCTAttachment(screenshot: window.screenshot())
            image.name = "Window with unexpected session count"
            image.lifetime = .keepAlways
            add(image)
        }
        XCTAssertTrue(matches, "Expected \(count) sessions in permanent sidebar, actual \(actual), frame \(window.frame)")
        XCTAssertEqual(actual, count)
    }

    private func joinTab(_ rowID: String, in app: XCUIApplication) throws {
        let row = try sidebarRowElement(rowID, in: try activeWindow(app))
        XCTAssertTrue(row.isHittable, "The source session row must be physically accessible")
        row.rightClick()
        let move = app.menuItems["Move to This Window"].firstMatch
        XCTAssertTrue(move.exists && move.isEnabled, "The existing custom-group action must be available")
        move.click()
    }

    func checkTabsGeometry(_ app: XCUIApplication, expectDragRegion: Bool) throws {
        let rowIDs = sidebarRows(try activeWindow(app))
        let count = rowIDs.count
        XCTAssertGreaterThan(count, 1, "Geometry requires multiple sessions")
        for index in 0..<count {
            let rowID = rowIDs[index]
            let row = try sidebarRowElement(rowID, in: try activeWindow(app))
            XCTAssertTrue(row.isHittable)
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            try assertSelection(rowID, count: count, in: app)

            let otherIndex = (index + 1) % count
            app.typeKey("\(otherIndex + 1)", modifierFlags: .command)
            try assertSelection(rowIDs[otherIndex], count: count, in: app)
            app.typeKey("\(index + 1)", modifierFlags: .command)
            try assertSelection(rowID, count: count, in: app)

            let baseline = try activeWindow(app).textViews.count
            let sidebarFrame = try assertSidebarAndTerminalGeometry(app, count: count, expectDragRegion: expectDragRegion)
            app.typeKey("d", modifierFlags: .command)
            XCTAssertEqual(try activeWindow(app).textViews.count, baseline + 1)
            XCTAssertEqual(try assertSidebarAndTerminalGeometry(app, count: count, expectDragRegion: expectDragRegion), sidebarFrame)
            app.typeKey("\n", modifierFlags: [.command, .shift])
            XCTAssertEqual(try activeWindow(app).textViews.count, 1, "Zoom must show only the focused pane")
            XCTAssertEqual(try assertSidebarAndTerminalGeometry(app, count: count, expectDragRegion: expectDragRegion), sidebarFrame)
            app.typeKey("\n", modifierFlags: [.command, .shift])
            XCTAssertEqual(try activeWindow(app).textViews.count, baseline + 1, "Reset zoom must restore every pane")
            XCTAssertEqual(try assertSidebarAndTerminalGeometry(app, count: count, expectDragRegion: expectDragRegion), sidebarFrame)
        }
        let attachment = XCTAttachment(screenshot: try activeWindow(app).screenshot())
        attachment.name = "Permanent sidebar and edge-to-edge terminal after selection, split and zoom"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertSelection(_ selectedRowID: String, count: Int, in app: XCUIApplication) throws {
        let window = try activeWindow(app)
        let rowIDs = sidebarRows(window)
        XCTAssertEqual(rowIDs.count, count)
        for rowID in rowIDs {
            let row = try sidebarRowElement(rowID, in: window)
            XCTAssertEqual(row.value as? String, rowID == selectedRowID ? "selected" : "unselected")
        }
        XCTAssertTrue(window.textViews.firstMatch.isHittable)
    }

    @discardableResult
    private func assertSidebarAndTerminalGeometry(
        _ app: XCUIApplication,
        count: Int,
        expectDragRegion: Bool
    ) throws -> CGRect {
        let window = try activeWindow(app)
        XCTAssertFalse(window.descendants(matching: .any)["tab-bar"].exists, "Visual top tab bar must not exist")
        XCTAssertFalse(window.buttons["new-tab-button"].exists, "Top new-tab-button must not exist")
        XCTAssertEqual(window.radioButtons.count, 0, "Top pill radioButtons must not exist")

        let sidebar = window.descendants(matching: .any)["SessionSidebar"].firstMatch
        let newSession = window.buttons["SessionSidebarNewSession"]
        let resizeHandle = window.descendants(matching: .any)["SessionSidebarResizeHandle"].firstMatch
        let dragRegion = window.descendants(matching: .any)["SidebarWindowDragRegion"].firstMatch
        XCTAssertTrue(sidebar.exists, "Permanent SessionSidebar container must exist")
        XCTAssertTrue(newSession.exists, "Mouse-accessible SessionSidebarNewSession button must exist")
        XCTAssertTrue(resizeHandle.exists, "SessionSidebarResizeHandle must exist")
        XCTAssertEqual(dragRegion.exists, expectDragRegion, "SidebarWindowDragRegion visibility must match fullscreen state")

        let sidebarFrame = sidebar.frame
        XCTAssertGreaterThanOrEqual(sidebarFrame.width, 260 - 1, "Sidebar width must respect non-zero minimum")
        XCTAssertEqual(sidebarFrame.minX, window.frame.minX, accuracy: 2)
        XCTAssertEqual(sidebarFrame.minY, window.frame.minY, accuracy: 2)
        XCTAssertEqual(sidebarFrame.maxY, window.frame.maxY, accuracy: 2)
        XCTAssertEqual(sidebarRows(window).count, count)

        let terminals = window.textViews.allElementsBoundByIndex.filter(\.isHittable)
        XCTAssertFalse(terminals.isEmpty, "At least one hittable terminal view must exist")
        for terminal in terminals {
            XCTAssertGreaterThanOrEqual(terminal.frame.minX, sidebarFrame.maxX - 2, "Terminal must sit to the right of SessionSidebar")
            XCTAssertGreaterThanOrEqual(terminal.frame.minY, window.frame.minY - 2, "Terminal must stay within window top edge")
            XCTAssertLessThanOrEqual(terminal.frame.maxY, window.frame.maxY + 2, "Terminal must stay within window bottom edge")
        }
        XCTAssertEqual(try XCTUnwrap(terminals.map(\.frame.minY).min()), window.frame.minY, accuracy: 2,
                       "Right terminal pane must extend all the way to the top edge of the window")
        XCTAssertEqual(try XCTUnwrap(terminals.map(\.frame.maxY).max()), window.frame.maxY, accuracy: 2,
                       "Right terminal pane must extend to the bottom edge of the window")
        return sidebarFrame
    }
}
