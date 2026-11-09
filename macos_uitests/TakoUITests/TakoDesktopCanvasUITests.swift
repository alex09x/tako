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
        XCTAssertEqual(toggle.value as? String, "floating")
        let before = pane(second, in: app).frame
        let drag = header(second, in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        XCUIElement.perform(withKeyModifiers: .option) {
            drag.press(forDuration: 0.1, thenDragTo: drag.withOffset(CGVector(dx: -35, dy: 20)))
        }
        let after = pane(second, in: app).frame
        XCTAssertEqual(after.minX, before.minX - 35, accuracy: 5)
        XCTAssertEqual(after.minY, before.minY + 20, accuracy: 5)
        toggle.click()
        XCTAssertEqual(toggle.value as? String, "tiled")
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
        assertRect(pane(id, in: app).frame, equals: canvas(in: app).frame)
        control("Close", pane: id, in: app).click()
        waitForPaneCount(0, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["FloatingCanvasNewTerminal"].firstMatch.waitForExistence(timeout: 5))
    }
}
