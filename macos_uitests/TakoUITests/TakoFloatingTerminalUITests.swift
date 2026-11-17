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

final class TakoFloatingTerminalUITests: TakoFloatingTerminalCase {
    @MainActor
    func testDraggingResizingAndMaximizeRestoreKeepTheSameTerminal() throws {
        let app = try launchFloatingApp()
        let first = try XCTUnwrap(paneIDs(in: app).first)
        let firstFrame = pane(first, in: app).frame
        let firstBody = pane(first, in: app).textViews.firstMatch.frame
        XCTAssertEqual(header(first, in: app).frame.minY, firstFrame.minY, accuracy: 2,
                       "Pane chrome must start at the workspace top without another titlebar inset")
        XCTAssertEqual(firstBody.minY, firstFrame.minY + Self.expectedPaneHeaderHeight, accuracy: 2)
        // The terminal keeps its card margin (bodyInsets) above the card's bottom edge.
        XCTAssertEqual(firstBody.maxY, firstFrame.maxY - Self.paneBodyBottomInset, accuracy: 2)
        app.typeKey("d", modifierFlags: .command)
        waitForPaneCount(2, in: app)
        let second = try XCTUnwrap(paneIDs(in: app).first { $0 != first })
        let process = try shellPID(second, phase: "DRAG_BEFORE", in: app)
        // Resizing, free dragging and overlap are a floating pane's: a new split tiles.
        floatPane(second, in: app)
        let outerFrame = activeWindow(in: app).frame
        let initial = pane(second, in: app).frame
        let resize = canvas(in: app).descendants(matching: .any)["FloatingPaneResize-bottomTrailing-\(second)"].firstMatch
        XCTAssertTrue(resize.waitForExistence(timeout: 5))
        XCTAssertTrue(resize.isHittable)
        let corner = resize.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: -70, dy: -50)))
        let resized = pane(second, in: app).frame
        XCTAssertLessThan(resized.width, initial.width - 20)
        XCTAssertLessThan(resized.height, initial.height - 20)

        let drag = header(second, in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        drag.press(forDuration: 0.1, thenDragTo: drag.withOffset(CGVector(dx: -60, dy: 25)))
        let moved = pane(second, in: app).frame
        XCTAssertEqual(moved.minX, resized.minX - 60, accuracy: 5)
        XCTAssertEqual(moved.minY, resized.minY + 25, accuracy: 5)
        XCTAssertTrue(moved.intersects(pane(first, in: app).frame), "Internal windows must support overlap")
        assertRect(activeWindow(in: app).frame, equals: outerFrame)
        attachCanvas(app, named: "Floating terminals overlap after drag and resize")

        control("Maximize", pane: second, in: app).click()
        let gap = Self.canvasPaneGap
        assertRect(pane(second, in: app).frame, equals: canvas(in: app).frame.insetBy(dx: gap, dy: gap))
        header(second, in: app).doubleClick()
        assertRect(pane(second, in: app).frame, equals: moved)
        XCTAssertEqual(try shellPID(second, phase: "DRAG_AFTER", in: app, focus: false), process)

        let beforeSelection = pane(second, in: app).frame
        let text = pane(second, in: app).textViews.firstMatch
        let select = text.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.25))
        select.press(forDuration: 0.1, thenDragTo: select.withOffset(CGVector(dx: 35, dy: 0)))
        assertRect(pane(second, in: app).frame, equals: beforeSelection)
        assertRect(activeWindow(in: app).frame, equals: outerFrame)
        XCTAssertEqual(Set(paneIDs(in: app)), [first, second])

        app.typeKey("f", modifierFlags: [.command, .control])
        waitForFullscreen(true, normalFrame: outerFrame, in: app)
        try focusThroughSidebar(second, in: app)
        control("Maximize", pane: second, in: app).click()
        control("Minimize", pane: second, in: app).click()
        waitForPaneCount(1, in: app)
        minimizedCard(second, in: app).click()
        waitForPaneCount(2, in: app)
        attachCanvas(app, named: "Pane controls remain usable in native fullscreen")
        app.typeKey("f", modifierFlags: [.command, .control])
        waitForFullscreen(false, normalFrame: outerFrame, in: app)
        XCTAssertEqual(try shellPID(second, phase: "FULLSCREEN_AFTER", in: app, focus: false), process)
    }

    @MainActor
    func testMinimizedShelfReceivesStatusAndRestoresProcessesFocusAndModes() throws {
        let app = try launchFloatingApp()
        let first = try XCTUnwrap(paneIDs(in: app).first)
        let firstProcess = try shellPID(first, phase: "SHELF_A_BEFORE", in: app)
        restorePaneToNormal(first, in: app)
        app.typeKey("d", modifierFlags: .command)
        waitForPaneCount(2, in: app)
        let second = try XCTUnwrap(paneIDs(in: app).first { $0 != first })
        let secondProcess = try shellPID(second, phase: "SHELF_B_BEFORE", in: app)
        let firstNormal = pane(first, in: app).frame

        try focusThroughSidebar(first, in: app)
        control("Maximize", pane: first, in: app).click()
        let gap = Self.canvasPaneGap
        assertRect(pane(first, in: app).frame, equals: canvas(in: app).frame.insetBy(dx: gap, dy: gap))
        control("Minimize", pane: first, in: app).click()
        waitForPaneCount(1, in: app)
        XCTAssertTrue(minimizedCard(first, in: app).waitForExistence(timeout: 5))

        let complete = try emitStatusUntilSignalled(second, in: app)
        control("Minimize", pane: second, in: app).click()
        waitForPaneCount(0, in: app)
        let firstCard = minimizedCard(first, in: app)
        let secondCard = minimizedCard(second, in: app)
        XCTAssertTrue(firstCard.waitForExistence(timeout: 5))
        XCTAssertTrue(secondCard.waitForExistence(timeout: 5))
        XCTAssertTrue(canvas(in: app).isHittable)
        XCTAssertTrue(activeWindow(in: app).descendants(matching: .any)["SessionSidebar"].firstMatch.isHittable)
        let workspace = canvas(in: app).frame
        XCTAssertLessThanOrEqual(secondCard.frame.maxX, workspace.maxX)
        XCTAssertGreaterThan(secondCard.frame.maxX, workspace.maxX - 40)
        XCTAssertLessThanOrEqual(secondCard.frame.maxY, workspace.maxY)
        XCTAssertGreaterThan(secondCard.frame.maxY, workspace.maxY - 40)
        attachCanvas(app, named: "All terminals minimized to lower-right shelf")

        // The hidden terminal is still reading PTY events after its view was unmounted.
        try Data("done".utf8).write(to: complete, options: .atomic)
        waitForStatus("done", on: secondCard)
        attachCanvas(app, named: "Minimized terminal reports completion")

        firstCard.click()
        waitForPaneCount(1, in: app)
        let restoredMaximum = pane(first, in: app).frame
        XCTAssertEqual(restoredMaximum.minX, workspace.minX + gap, accuracy: 3)
        XCTAssertEqual(restoredMaximum.minY, workspace.minY + gap, accuracy: 3)
        XCTAssertEqual(restoredMaximum.width, workspace.width - 2 * gap, accuracy: 3)
        XCTAssertEqual(restoredMaximum.maxY, workspace.maxY - gap, accuracy: 3,
                       "The overlay shelf reserves no terminal height")
        XCTAssertEqual(try shellPID(first, phase: "SHELF_A_AFTER", in: app, focus: false), firstProcess)

        minimizedCard(second, in: app).click()
        waitForPaneCount(2, in: app)
        XCTAssertFalse(canvas(in: app).descendants(matching: .any)["FloatingMinimizeShelf"].firstMatch.exists)
        XCTAssertEqual(try shellPID(second, phase: "SHELF_B_AFTER", in: app, focus: false), secondProcess)
        try focusThroughSidebar(first, in: app)
        control("Maximize", pane: first, in: app).click()
        assertRect(pane(first, in: app).frame, equals: firstNormal)
        attachCanvas(app, named: "Restored terminals preserve their normal rectangles")
    }

    @MainActor
    func testCancellingBusyPaneClosePreservesProcessAndReturnsInputFocus() throws {
        let app = try launchFloatingApp(confirmClose: true)
        let id = try XCTUnwrap(paneIDs(in: app).first)
        let process = try shellPID(id, phase: "CANCEL_BEFORE", in: app)
        let terminal = pane(id, in: app).textViews.firstMatch
        app.typeText(#"/bin/sh -c 'printf "FLOAT""-BUSY\n"; sleep 20'"# + "\n")
        let busy = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS 'FLOAT-BUSY'"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [busy], timeout: 5), .completed)
        control("Close", pane: id, in: app).click()
        let window = activeWindow(in: app)
        let dialog = window.staticTexts["terminal-dialog-body"].firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5), "Closing a busy terminal must retain the existing confirmation")
        XCTAssertEqual(dialog.label, "Close Terminal?")
        let cancel = window.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.isHittable)
        cancel.click()
        XCTAssertTrue(dialog.waitForNonExistence(timeout: 5))
        XCTAssertEqual(paneIDs(in: app), [id])
        app.typeKey("c", modifierFlags: .control)
        XCTAssertEqual(try shellPID(id, phase: "CANCEL_AFTER", in: app, focus: false), process)
        attachCanvas(app, named: "Cancel busy close retains process and keyboard focus")
    }

    @MainActor
    func testCloseTargetsOnlyOnePaneAndLastCloseLeavesUsableCanvas() throws {
        let app = try launchFloatingApp()
        let first = try XCTUnwrap(paneIDs(in: app).first)
        let firstProcess = try shellPID(first, phase: "CLOSE_BEFORE", in: app, focus: false)
        app.typeKey("d", modifierFlags: .command)
        waitForPaneCount(2, in: app)
        let second = try XCTUnwrap(paneIDs(in: app).first { $0 != first })
        try focusThroughSidebar(first, in: app)
        restorePaneToNormal(first, in: app)
        floatPane(first, in: app) // moving it off its tile is a floating pane's
        let moveFirst = header(first, in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        moveFirst.press(forDuration: 0.1, thenDragTo: moveFirst.withOffset(CGVector(dx: -100, dy: 0)))
        let backgroundClose = control("Close", pane: second, in: app)
        XCTAssertTrue(backgroundClose.isHittable)
        backgroundClose.click()
        waitForPaneCount(1, in: app)
        XCTAssertEqual(paneIDs(in: app), [first])
        XCTAssertEqual(try shellPID(first, phase: "CLOSE_AFTER", in: app, focus: false), firstProcess)

        control("Close", pane: first, in: app).click()
        waitForPaneCount(0, in: app)
        let window = activeWindow(in: app)
        XCTAssertTrue(window.exists, "Closing an internal terminal must retain its host window")
        XCTAssertTrue(window.descendants(matching: .any)["SessionSidebar"].firstMatch.isHittable)
        let emptyMessage = canvas(in: app).staticTexts["No open terminals in this session"].firstMatch
        XCTAssertTrue(emptyMessage.waitForExistence(timeout: 5))
        let create = canvas(in: app).buttons["FloatingCanvasNewTerminal"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertTrue(create.isHittable)
        attachCanvas(app, named: "Empty canvas retains sidebar and new terminal action")
        create.click()
        waitForPaneCount(1, in: app)
        let fresh = try XCTUnwrap(paneIDs(in: app).first)
        XCTAssertFalse([first, second].contains(fresh))
        XCTAssertGreaterThan(try shellPID(fresh, phase: "EMPTY_NEW", in: app, focus: false), 0)
        control("Close", pane: fresh, in: app).click()
        waitForPaneCount(0, in: app)
        XCTAssertTrue(window.exists)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(window.waitForNonExistence(timeout: 5), "Cmd-W on an empty canvas explicitly closes its session")
    }
}
