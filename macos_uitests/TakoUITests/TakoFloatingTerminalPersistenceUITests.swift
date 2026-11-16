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

final class TakoFloatingTerminalPersistenceUITests: TakoFloatingTerminalCase {
    @MainActor
    func testRestartPreservesFloatingPresentationAndBothRunningProcesses() throws {
        let app = try launchFloatingApp(persistent: true)
        let first = try XCTUnwrap(paneIDs(in: app).first)
        let firstProcess = try shellPID(first, phase: "PERSIST_A_BEFORE", in: app)
        app.typeKey("d", modifierFlags: .command)
        waitForPaneCount(2, in: app)
        let second = try XCTUnwrap(paneIDs(in: app).first { $0 != first })
        let secondProcess = try shellPID(second, phase: "PERSIST_B_BEFORE", in: app)
        try focusThroughSidebar(first, in: app)
        restorePaneToNormal(first, in: app)
        floatPane(first, in: app) // the resize and drag below are a floating pane's

        let resize = canvas(in: app).descendants(matching: .any)["FloatingPaneResize-bottomTrailing-\(first)"].firstMatch
        XCTAssertTrue(resize.exists)
        XCTAssertTrue(resize.isHittable)
        let corner = resize.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: -70, dy: -110)))
        let drag = header(first, in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        drag.press(forDuration: 0.1, thenDragTo: drag.withOffset(CGVector(dx: 35, dy: 25)))
        let normal = pane(first, in: app).frame

        control("Minimize", pane: second, in: app).click()
        waitForPaneCount(1, in: app)
        control("Maximize", pane: first, in: app).click()
        _ = try shellPID(first, phase: "PERSIST_QUIT", in: app)
        attachCanvas(app, named: "Floating presentation before normal quit")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "Normal quit must finish saving the fixture")
        app.launch()
        XCTAssertTrue(canvas(in: app).waitForExistence(timeout: 10))
        waitForPaneCount(1, in: app)
        XCTAssertEqual(paneIDs(in: app), [first])
        XCTAssertTrue(minimizedCard(second, in: app).waitForExistence(timeout: 10))
        let restored = pane(first, in: app).frame
        let area = canvas(in: app).frame
        let gap = Self.canvasPaneGap // the maximized card keeps the grid gap
        XCTAssertEqual(restored.minX, area.minX + gap, accuracy: 3)
        XCTAssertEqual(restored.minY, area.minY + gap, accuracy: 3)
        XCTAssertEqual(restored.width, area.width - 2 * gap, accuracy: 3)
        XCTAssertLessThanOrEqual(restored.maxY, minimizedCard(second, in: app).frame.minY - 4)
        XCTAssertEqual(try shellPID(first, phase: "PERSIST_A_AFTER", in: app, focus: false), firstProcess)

        minimizedCard(second, in: app).click()
        waitForPaneCount(2, in: app)
        XCTAssertEqual(try shellPID(second, phase: "PERSIST_B_AFTER", in: app, focus: false), secondProcess)
        try focusThroughSidebar(first, in: app)
        control("Maximize", pane: first, in: app).click()
        assertRect(pane(first, in: app).frame, equals: normal)
        XCTAssertEqual(Set(paneIDs(in: app)), [first, second])
        attachCanvas(app, named: "Restart restores UUIDs processes and normal rectangle")
    }
}
