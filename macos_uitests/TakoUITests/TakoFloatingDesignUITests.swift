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
        XCTAssertLessThanOrEqual(workspaceHeader.frame.minY - sidebar.frame.minY, 72,
                                 "Idle navigation should not spend a tall stack on empty filters")
        XCTAssertFalse(sidebar.textFields.firstMatch.exists)

        let searchToggle = sidebar.buttons["SessionSidebarSearchButton"]
        XCTAssertTrue(searchToggle.isHittable)
        searchToggle.click()
        let search = sidebar.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        app.typeText("no-session-matches-this-reference")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        XCTAssertTrue(workspaceHeader.waitForExistence(timeout: 5))
        XCTAssertTrue(sidebar.isHittable)
        attachCanvas(app, named: "Compact sidebar with filters collapsed")

        let first = try XCTUnwrap(paneIDs(in: app).first)
        let firstProcess = try shellPID(first, phase: "DESIGN_BACKGROUND_BEFORE", in: app)
        let backgroundFrame = pane(first, in: app).frame
        let workFrame = canvas(in: app).frame
        XCTAssertEqual(control("Maximize", pane: first, in: app).value as? String, "maximized")
        assertRect(backgroundFrame, equals: workFrame)
        XCTAssertEqual(header(first, in: app).frame.height, Self.expectedPaneHeaderHeight, accuracy: 2)

        app.typeKey("d", modifierFlags: .command)
        waitForPaneCount(2, in: app)
        let second = try XCTUnwrap(paneIDs(in: app).first { $0 != first })
        let floatingFrame = pane(second, in: app).frame
        XCTAssertEqual(control("Maximize", pane: first, in: app).value as? String, "maximized",
                       "Opening a floating terminal must preserve the background presentation")
        assertRect(pane(first, in: app).frame, equals: backgroundFrame)
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
        XCTAssertLessThanOrEqual(pane(first, in: app).frame.maxY, card.frame.minY - 4,
                                 "The capsule must not cover background terminal rows")
        attachCanvas(app, named: "Right-hand capsule without a full-width shelf bar")
        card.click()
        waitForPaneCount(2, in: app)
        assertRect(pane(second, in: app).frame, equals: floatingFrame)
        XCTAssertEqual(try shellPID(second, phase: "DESIGN_FLOAT_AFTER", in: app, focus: false), secondProcess)
        try focusThroughSidebar(first, in: app)
        XCTAssertEqual(try shellPID(first, phase: "DESIGN_BACKGROUND_AFTER", in: app, focus: false), firstProcess)
    }
}
