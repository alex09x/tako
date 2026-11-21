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

final class TakoFloatingDesignUITests: TakoFloatingTerminalCase {
    @MainActor
    func testCompactNavigationAndNewFloatingWindowProportions() throws {
        let app = try launchFloatingApp()
        let window = activeWindow(in: app)
        let sidebar = window.descendants(matching: .any)["SessionSidebar"].firstMatch
        let workspaceHeader = sidebar.descendants(matching: .any)["SessionSidebarWorkspace-Default"].firstMatch
        XCTAssertTrue(workspaceHeader.waitForExistence(timeout: 5))
        // Reference A01: 44 pt header, the always-shown filter field and the counters, then
        // the first workspace about 116 pt from the window's top (FloatingRexPolishTests asserts
        // the same band on the hosted view).
        let idleTop = workspaceHeader.frame.minY - window.frame.minY
        XCTAssertTrue((104...128).contains(idleTop), "first workspace \(idleTop) pt from the top, reference A01 is about 116")
        let search = sidebar.textFields["SessionSidebarSearchField"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "A01 always shows the filter field")
        search.click()
        app.typeText("no-session-matches-this-reference")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(search.exists, "Escape clears the query; the field stays")
        XCTAssertTrue(workspaceHeader.waitForExistence(timeout: 5))
        XCTAssertEqual(workspaceHeader.frame.minY - window.frame.minY, idleTop, accuracy: 1, "clearing does not move the list")
        XCTAssertTrue(sidebar.isHittable)
        attachCanvas(app, named: "Compact sidebar with filters collapsed")

        let first = try XCTUnwrap(paneIDs(in: app).first)
        let firstProcess = try shellPID(first, phase: "DESIGN_BACKGROUND_BEFORE", in: app)
        let backgroundFrame = pane(first, in: app).frame
        let workFrame = canvas(in: app).frame
        let gap = Self.canvasPaneGap
        XCTAssertEqual(control("Maximize", pane: first, in: app).value as? String, "maximized")
        // A sole pane is the maximized card: the grid's gap from every canvas edge.
        assertRect(backgroundFrame, equals: workFrame.insetBy(dx: gap, dy: gap))
        XCTAssertEqual(header(first, in: app).frame.height, Self.expectedPaneHeaderHeight, accuracy: 2)

        // A split tiles both (the sole maximized tile returns to the grid); a floating
        // terminal is the explicit Float control, which opens at the default proportions.
        app.typeKey("d", modifierFlags: .command)
        waitForPaneCount(2, in: app)
        let second = try XCTUnwrap(paneIDs(in: app).first { $0 != first })
        XCTAssertEqual(control("Float", pane: first, in: app).value as? String, "tiled")
        floatPane(second, in: app)
        let floatingFrame = pane(second, in: app).frame
        XCTAssertEqual(control("Maximize", pane: second, in: app).value as? String, "normal")
        XCTAssertEqual(floatingFrame.width, max(260, workFrame.width * 0.55), accuracy: 3)
        XCTAssertEqual(floatingFrame.height, max(150, workFrame.height * 0.60), accuracy: 3)
        XCTAssertGreaterThanOrEqual(floatingFrame.minX, workFrame.minX)
        XCTAssertGreaterThanOrEqual(floatingFrame.minY, workFrame.minY)
        XCTAssertLessThanOrEqual(floatingFrame.maxX, workFrame.maxX)
        XCTAssertLessThanOrEqual(floatingFrame.maxY, workFrame.maxY)
        XCTAssertEqual(header(second, in: app).frame.height, Self.expectedPaneHeaderHeight, accuracy: 2)
        XCTAssertGreaterThanOrEqual(control("Close", pane: second, in: app).frame.height, 22)
        attachCanvas(app, named: "Compact floating terminal over retained full-height background")

        let secondProcess = try shellPID(second, phase: "DESIGN_FLOAT_BEFORE", in: app)
        control("Minimize", pane: second, in: app).click()
        waitForPaneCount(1, in: app)
        let card = minimizedCard(second, in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertEqual(card.frame.height, 30, accuracy: 2)
        assertRect(pane(first, in: app).frame, equals: backgroundFrame)
        // The approved shelf overlays the field; it reserves no terminal height.
        XCTAssertEqual(card.frame.maxY, canvas(in: app).frame.maxY - 14, accuracy: 2)
        attachCanvas(app, named: "Right-hand capsule without a full-width shelf bar")
        card.click()
        waitForPaneCount(2, in: app)
        assertRect(pane(second, in: app).frame, equals: floatingFrame)
        XCTAssertEqual(try shellPID(second, phase: "DESIGN_FLOAT_AFTER", in: app, focus: false), secondProcess)
        try focusThroughSidebar(first, in: app)
        XCTAssertEqual(try shellPID(first, phase: "DESIGN_BACKGROUND_AFTER", in: app, focus: false), firstProcess)
    }
}
