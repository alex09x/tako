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
        // The drawn title/pill and New Tab control share the 38pt own row.
        // Split zoom must preserve it without a native title/ResetZoom field.
        try checkTabsGeometry(app)
    }

    @MainActor
    func testTabsGeometryInNormalWindow() throws {
        let app = try takoApplication()
        app.launch()
        app.typeKey("t", modifierFlags: .command)
        try assertTabCount(2, in: app)
        try checkTabsGeometry(app)

        // The own pill paints a close glyph, not an AX _closeButton child.
        // Hit its real 20pt close area and verify exactly one tab closes.
        let tab = try activeWindow(app).radioButtons["tab-1"]
        tab.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -13, dy: 0)).click()
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
        // Prepare the group before fullscreen reparents its titlebar. This
        // case checks geometry and selection, not tab creation mid-transition.
        try assertTabCount(2, in: app)
        XCTAssertGreaterThan(try activeWindow(app).frame.height, normalFrame.height,
                             "The geometry check must actually run in fullscreen")
        try checkTabsGeometry(app)
        app.typeKey("f", modifierFlags: [.command, .control])
        XCTAssertEqual(try activeWindow(app).frame.height, normalFrame.height, accuracy: 1,
                       "Exiting fullscreen must restore the original window geometry")
    }

    @MainActor
    func testTabsGeometryAfterMovingTabs() throws {
        let app = try takoApplication()
        app.launch()
        app.typeKey("t", modifierFlags: .command)
        app.typeKey("t", modifierFlags: .command)
        try assertTabCount(3, in: app)
        showSidebar(app)
        let originalRows = Set(sidebarRows(try activeWindow(app)))
        XCTAssertEqual(originalRows.count, 3)
        showSidebar(app)

        // Track a real pane rather than tab-N, which is an index that changes
        // when the own bar reorders its group.
        app.typeKey("d", modifierFlags: .command)
        let source = try activeWindow(app)
        let handles = source.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane-drag-handle-'"))
        XCTAssertEqual(handles.count, 2)
        let movedID = handles.element(boundBy: 1).identifier
        source.radioButtons["tab-2"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: source.radioButtons["tab-0"].coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)))
        let reordered = try activeWindow(app)
        XCTAssertEqual(reordered.radioButtons["tab-0"].value as? Int, 1)
        XCTAssertTrue(reordered.buttons[movedID].isHittable, "The dragged tab must retain its live split tree")
        try assertTabCount(3, in: app)

        // Cross-window detach is a pane-drag action. The bar supports in-group
        // reordering, not AppKit's native inter-window tab dragging.
        let outside = reordered.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: 60, dy: 0))
        reordered.buttons[movedID].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: outside)
        XCTAssertTrue(app.wait(for: \.windows.count, toEqual: 2, timeout: 1), "Detaching a pane must open a second visible window")
        try assertTabCount(1, in: app)
        let detached = try activeWindow(app)
        XCTAssertEqual(detached.textViews.count, 1)
        XCTAssertTrue(detached.textViews.firstMatch.isHittable)
        try assertStripGeometry(app, count: 1)

        showSidebar(app)
        let rows = Set(sidebarRows(try activeWindow(app)))
        XCTAssertEqual(rows.subtracting(originalRows).count, 1, "The detached pane must create exactly one new tab identity")
        XCTAssertTrue(originalRows.isSubset(of: rows))
        // A standalone destination joins the existing multi-tab source group;
        // moving it must preserve all three original tabs as one group.
        try joinTab(try XCTUnwrap(originalRows.sorted().first), in: app)
        try assertTabCount(4, in: app)
        XCTAssertEqual(app.windows.count, 1, "Rejoining must order out sibling windows")
        showSidebar(app) // hide before exercising the full-width strip
        try checkTabsGeometry(app)
    }

    @MainActor
    func testTabsGeometryAfterMergingAllWindows() throws {
        let app = try takoApplication()
        app.launch()
        showSidebar(app)
        let firstRow = try XCTUnwrap(sidebarRows(try activeWindow(app)).first)
        app.typeKey("n", modifierFlags: .command)
        let secondRow = try XCTUnwrap(sidebarRows(try activeWindow(app)).first { $0 != firstRow })
        app.typeKey("n", modifierFlags: .command)
        XCTAssertEqual(app.windows.count, 3, "Three independent groups must exist before merging")

        // Native mergeAllWindows: is unavailable with tabbingMode.disallowed.
        // Exercise the shipped sidebar action twice to merge all three groups.
        try joinTab(firstRow, in: app)
        try assertTabCount(2, in: app)
        XCTAssertEqual(app.windows.count, 2)
        try joinTab(secondRow, in: app)
        try assertTabCount(3, in: app)
        XCTAssertEqual(app.windows.count, 1)
        showSidebar(app)
        try checkTabsGeometry(app)
    }

    private func activeWindow(_ app: XCUIApplication) throws -> XCUIElement {
        // Requery after selection: each tab owns an NSWindow, and the previous
        // one is ordered out. Its descendants can still exist in AX.
        // AppKit's 33pt fullscreen titlebar window can expose a terminal AX
        // descendant without containing it. Use the physical terminal owner.
        func resolve() -> XCUIElement? {
            let owners = app.windows.matching(identifier: "TerminalWindowRestoration").allElementsBoundByIndex.filter { window in
                let terminal = window.textViews.firstMatch
                return terminal.exists && window.frame.insetBy(dx: -1, dy: -1).contains(terminal.frame)
            }
            return owners.first { $0.textViews.firstMatch.isHittable } ?? owners.first
        }
        if let window = resolve() { return window }
        // Native Space transitions briefly expose their target AX geometry
        // before AppKit accepts mouse input. Wait for physical readiness.
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

    private func assertTabCount(_ count: Int, in app: XCUIApplication) throws {
        let window = try activeWindow(app)
        let matches = window.wait(for: \.radioButtons.count, toEqual: count, timeout: 1)
        if !matches {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Unexpected tab count: expected \(count), actual \(window.radioButtons.count)"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let image = XCTAttachment(screenshot: window.screenshot())
            image.name = "Window with unexpected tab count"
            image.lifetime = .keepAlways
            add(image)
        }
        XCTAssertTrue(matches, "Expected \(count) tabs, actual \(window.radioButtons.count), frame \(window.frame)")
        XCTAssertEqual(window.radioButtons.count, count)
    }

    private func showSidebar(_ app: XCUIApplication) {
        app.menuBarItems["View"].firstMatch.click()
        app.menuItems["Session Sidebar"].firstMatch.click()
    }

    private func sidebarRows(_ window: XCUIElement) -> [String] {
        window.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'session-tab-'"))
            .allElementsBoundByIndex.filter { $0.isHittable }.map { $0.identifier }
    }

    private func joinTab(_ rowID: String, in app: XCUIApplication) throws {
        let row = try activeWindow(app).descendants(matching: .any)[rowID].firstMatch
        XCTAssertTrue(row.isHittable, "The source session row must be physically accessible")
        row.rightClick()
        let move = app.menuItems["Move to This Window"].firstMatch
        XCTAssertTrue(move.exists && move.isEnabled, "The existing custom-group action must be available")
        move.click()
    }

    func checkTabsGeometry(_ app: XCUIApplication) throws {
        let count = try activeWindow(app).radioButtons.count
        XCTAssertGreaterThan(count, 1, "Geometry requires multiple tabs")
        for index in 0..<count {
            let tab = try activeWindow(app).radioButtons["tab-\(index)"]
            XCTAssertTrue(tab.isHittable)
            // Coordinate clicks test the actual mouse hit path, not AXPress.
            tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            try assertSelection(index, count: count, in: app)

            // Shortcut badges are painted only while Command is held; there
            // are no permanent native shortcut-label AX children to align.
            // Prove numbered navigation by first selecting a different tab.
            app.typeKey("\((index + 1) % count + 1)", modifierFlags: .command)
            try assertSelection((index + 1) % count, count: count, in: app)
            app.typeKey("\(index + 1)", modifierFlags: .command)
            try assertSelection(index, count: count, in: app)

            let baseline = try activeWindow(app).textViews.count
            let frame = try assertStripGeometry(app, count: count)
            app.typeKey("d", modifierFlags: .command)
            XCTAssertEqual(try activeWindow(app).textViews.count, baseline + 1)
            XCTAssertEqual(try assertStripGeometry(app, count: count), frame)
            app.typeKey("\n", modifierFlags: [.command, .shift])
            XCTAssertEqual(try activeWindow(app).textViews.count, 1, "Zoom must show only the focused pane")
            XCTAssertEqual(try assertStripGeometry(app, count: count), frame)
            app.typeKey("\n", modifierFlags: [.command, .shift])
            XCTAssertEqual(try activeWindow(app).textViews.count, baseline + 1, "Reset zoom must restore every pane")
            XCTAssertEqual(try assertStripGeometry(app, count: count), frame)
        }
        let attachment = XCTAttachment(screenshot: try activeWindow(app).screenshot())
        attachment.name = "Custom tabs after selection, split and zoom"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertSelection(_ selected: Int, count: Int, in app: XCUIApplication) throws {
        let window = try activeWindow(app)
        XCTAssertEqual(window.radioButtons.count, count)
        for index in 0..<count {
            XCTAssertEqual(window.radioButtons["tab-\(index)"].value as? Int, index == selected ? 1 : 0)
        }
        XCTAssertTrue(window.textViews.firstMatch.isHittable)
    }

    @discardableResult
    private func assertStripGeometry(_ app: XCUIApplication, count: Int) throws -> CGRect {
        let window = try activeWindow(app)
        let strip = window.descendants(matching: .any)["tab-bar"].frame
        let plus = window.buttons["new-tab-button"].frame
        XCTAssertEqual(strip.height, 38, accuracy: 1)
        XCTAssertEqual(strip.width, window.frame.width, accuracy: 1)
        XCTAssertEqual(plus.height, 28, accuracy: 1)
        XCTAssertEqual(plus.midY, strip.midY, accuracy: 1)
        XCTAssertEqual(window.radioButtons.count, count)
        var previous: CGRect?
        for index in 0..<count {
            let tab = window.radioButtons["tab-\(index)"]
            let frame = tab.frame
            XCTAssertTrue(tab.isHittable)
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertEqual(frame.height, 28, accuracy: 1)
            XCTAssertEqual(frame.midY, plus.midY, accuracy: 1)
            XCTAssertGreaterThanOrEqual(frame.minX, strip.minX)
            XCTAssertLessThanOrEqual(frame.maxX, plus.minX)
            if let previous {
                XCTAssertGreaterThanOrEqual(frame.minX, previous.maxX, "Tab hit targets must not overlap")
                XCTAssertEqual(frame.height, previous.height, accuracy: 1)
            }
            previous = frame
        }
        for terminal in window.textViews.allElementsBoundByIndex {
            XCTAssertTrue(terminal.isHittable)
            XCTAssertGreaterThanOrEqual(terminal.frame.minY, strip.maxY - 1, "Terminal content must stay below the own strip")
        }
        return strip
    }
}
