/*
 * tako — Current tile/float controls and minimize shelf retain terminal processes
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import XCTest

final class TakoDesktopCanvasUITests: TakoDesktopDesignCase {
    func testShelfOverlaysTheCanvasWithoutReservingHeightOrBlockingTerminalInput() throws {
        let app = try launchDesktop()
        let first = try XCTUnwrap(paneIDs(in: app).first)
        let firstPID = try shellPID(first, phase: "OVERLAY_FIRST_BEFORE", in: app)
        app.typeKey("d", modifierFlags: .command)
        waitForPaneCount(2, in: app)
        let second = try XCTUnwrap(paneIDs(in: app).first { $0 != first })
        let secondPID = try shellPID(second, phase: "OVERLAY_SECOND_BEFORE", in: app)
        let firstTile = pane(first, in: app).frame
        let secondTile = pane(second, in: app).frame
        control("Minimize", pane: second, in: app).click()
        waitForPaneCount(1, in: app)
        let expanded = pane(first, in: app).frame
        XCTAssertEqual(expanded.height, firstTile.height, accuracy: 1)
        XCTAssertEqual(expanded.minY, firstTile.minY, accuracy: 1)
        XCTAssertGreaterThan(expanded.width, firstTile.width)
        let card = minimizedCard(second, in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertEqual(canvas(in: app).frame.maxY - card.frame.maxY, 14, accuracy: 2)
        XCTAssertEqual(canvas(in: app).frame.maxX - card.frame.maxX, 14, accuracy: 2)
        app.typeKey("k", modifierFlags: .command)
        pane(first, in: app).textViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.97)).click()
        XCTAssertEqual(try shellPID(first, phase: "OVERLAY_BOTTOM_INPUT", in: app, focus: false), firstPID)
        card.click()
        waitForPaneCount(2, in: app)
        assertRect(pane(first, in: app).frame, equals: firstTile)
        assertRect(pane(second, in: app).frame, equals: secondTile)
        control("Maximize", pane: first, in: app).click()
        let maximized = pane(first, in: app).frame
        // The maximized card keeps the grid's gap from every canvas edge, as tiles do.
        let gap = Self.canvasPaneGap
        assertRect(maximized, equals: canvas(in: app).frame.insetBy(dx: gap, dy: gap))
        activeWindow(in: app).descendants(matching: .any)["session-pane-\(second)"].firstMatch.click()
        control("Minimize", pane: second, in: app).click()
        waitForPaneCount(1, in: app)
        assertRect(pane(first, in: app).frame, equals: maximized)
        minimizedCard(second, in: app).click()
        waitForPaneCount(2, in: app)
        XCTAssertEqual(try shellPID(second, phase: "OVERLAY_SECOND_AFTER", in: app), secondPID)
        captureSettingsIfPresent(app)
    }

    private func captureSettingsIfPresent(_ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: activeWindow(in: app).screenshot())
        attachment.name = "Minimize shelf overlays full canvas without a reserved strip"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDraggingAPaneToAnotherTileDocksItWithoutRestartingEitherTerminal() throws {
        let app = try launchDesktop()
        let first = try XCTUnwrap(paneIDs(in: app).first)
        let firstPID = try shellPID(first, phase: "DOCK_FIRST_BEFORE", in: app)
        app.typeKey("d", modifierFlags: .command)
        waitForPaneCount(2, in: app)
        let second = try XCTUnwrap(paneIDs(in: app).first { $0 != first })
        let secondPID = try shellPID(second, phase: "DOCK_SECOND_BEFORE", in: app)
        let from = header(second, in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        let to = canvas(in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: 0.5))
        from.press(forDuration: 0.2, thenDragTo: to)
        let toggle = control("Float", pane: second, in: app)
        let docked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'tiled'"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [docked], timeout: 5), .completed)
        XCTAssertLessThan(pane(second, in: app).frame.minX, pane(first, in: app).frame.minX)
        XCTAssertFalse(pane(first, in: app).frame.intersects(pane(second, in: app).frame))
        XCTAssertEqual(try shellPID(second, phase: "DOCK_SECOND_AFTER", in: app, focus: false), secondPID)
        XCTAssertEqual(try shellPID(first, phase: "DOCK_FIRST_AFTER", in: app), firstPID)
    }

    func testFloatDragReturnToGridPreservesPaneAndProcess() throws {
        let app = try launchDesktop()
        let first = try XCTUnwrap(paneIDs(in: app).first)
        app.typeKey("d", modifierFlags: .command)
        waitForPaneCount(2, in: app)
        let second = try XCTUnwrap(paneIDs(in: app).first { $0 != first })
        let process = try shellPID(second, phase: "NATIVE_FLOAT_BEFORE", in: app)
        let toggle = control("Float", pane: second, in: app)
        XCTAssertEqual(toggle.value as? String, "tiled")
        toggle.click()
        let floated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'floating'"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [floated], timeout: 5), .completed, "The pane should float after the click")
        let before = pane(second, in: app).frame
        let drag = header(second, in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        drag.press(forDuration: 0.1, thenDragTo: drag.withOffset(CGVector(dx: -35, dy: 20)))
        let after = pane(second, in: app).frame
        XCTAssertEqual(after.minX, before.minX - 35, accuracy: 5)
        XCTAssertEqual(after.minY, before.minY + 20, accuracy: 5)
        XCTAssertEqual(toggle.value as? String, "floating")
        toggle.click()
        let tiled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'tiled'"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [tiled], timeout: 5), .completed, "The pane should return to the grid after the click")
        XCTAssertFalse(pane(first, in: app).frame.intersects(pane(second, in: app).frame))
        XCTAssertEqual(try shellPID(second, phase: "NATIVE_FLOAT_AFTER", in: app, focus: false), process)
    }

    func testMinimizeRestoreMaximizeAndCloseLeaveTheSameLiveTerminalUntilClose() throws {
        let app = try launchDesktop()
        let id = try XCTUnwrap(paneIDs(in: app).first)
        let process = try shellPID(id, phase: "NATIVE_SHELF_BEFORE", in: app)
        control("Minimize", pane: id, in: app).click()
        waitForPaneCount(0, in: app)
        let card = minimizedCard(id, in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.click()
        waitForPaneCount(1, in: app)
        XCTAssertEqual(try shellPID(id, phase: "NATIVE_SHELF_AFTER", in: app, focus: false), process)
        let maximize = control("Maximize", pane: id, in: app)
        if maximize.value as? String != "maximized" { maximize.click() }
        let gap = Self.canvasPaneGap
        assertRect(pane(id, in: app).frame, equals: canvas(in: app).frame.insetBy(dx: gap, dy: gap))
        control("Close", pane: id, in: app).click()
        waitForPaneCount(0, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["FloatingCanvasNewTerminal"].firstMatch.waitForExistence(timeout: 5))
    }
}
