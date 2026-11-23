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
        let second = try XCTUnwrap(paneIDs(in: app).first)
        let secondProcess = try shellPID(second, phase: "SHELF_B_BEFORE", in: app)
        restorePaneToNormal(second, in: app)
        app.typeKey("d", modifierFlags: .command)
        waitForPaneCount(2, in: app)
        // Maximize the right tile so its controls stay clear of the left tile's header.
        let first = try XCTUnwrap(paneIDs(in: app).first { $0 != second })
        let firstProcess = try shellPID(first, phase: "SHELF_A_BEFORE", in: app)
        let firstNormal = pane(first, in: app).frame

        try focusThroughSidebar(first, in: app)
        control("Maximize", pane: first, in: app).click()
        let gap = Self.canvasPaneGap
        assertRect(pane(first, in: app).frame, equals: canvas(in: app).frame.insetBy(dx: gap, dy: gap))
        let minimize = control("Minimize", pane: first, in: app)
        let backgroundMinimize = control("Minimize", pane: second, in: app)
        XCTAssertFalse(minimize.frame.intersects(backgroundMinimize.frame),
                       "The shelf fixture needs separate click targets for both panes")
        minimize.click()
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
        let shelfRightEdge = max(firstCard.frame.maxX, secondCard.frame.maxX)
        XCTAssertLessThanOrEqual(shelfRightEdge, workspace.maxX)
        XCTAssertGreaterThan(shelfRightEdge, workspace.maxX - 40)
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

    // MARK: - Ported from the retired split-tree drag handle (TakoWindowPositionUITests)

    /// Was testRejectedSplitDropInsideItsWindowKeepsBothPanes: a pane dragged by its
    /// header onto its sibling inside the same window is not detached.
    @MainActor
    func testHeaderDropOnSiblingInsideItsWindowKeepsBothPanes() throws {
        let app = try launchFloatingApp()
        let (first, second) = try splitInTwo(app)
        let processes = [try shellPID(first, phase: "DROP_A_BEFORE", in: app),
                         try shellPID(second, phase: "DROP_B_BEFORE", in: app)]
        let from = header(second, in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        from.press(forDuration: 0.2, thenDragTo: pane(first, in: app).textViews.firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        XCTAssertEqual(app.windows.count, 1, "A rejected drop inside the source window must not detach")
        XCTAssertEqual(Set(paneIDs(in: app)), [first, second])
        XCTAssertEqual(paneIDs(in: app).count, 2)
        for id in [first, second] {
            XCTAssertTrue(pane(id, in: app).textViews.firstMatch.isHittable)
        }
        XCTAssertEqual([try shellPID(first, phase: "DROP_A_AFTER", in: app),
                        try shellPID(second, phase: "DROP_B_AFTER", in: app)], processes)
    }

    /// Was testDragSplitWindowPosition. Superseded: its drop-at-cursor placement
    /// (`minX == rightFrame.maxX + 100`, `minY == rightFrame.minY`). A header drag now
    /// stays clamped in the canvas (TakoTitlebarTabsUITests.testTabsGeometryAfterMovingTabs)
    /// and detaching is the header's Move Pane to New Window command, which has no cursor.
    /// Kept: a second window appears, holds the same pane and process, and keeps its
    /// terminal content size.
    @MainActor
    func testMovePaneToNewWindowKeepsItsTerminalSizeAndProcess() throws {
        let app = try launchFloatingApp()
        // Without a fixed window size, as the original after its reload.
        try updateConfig("""
        macos-titlebar-style = tabs
        confirm-close-surface = false
        auto-update = off
        """)
        app.typeKey(",", modifierFlags: [.command, .shift])
        let (first, second) = try splitInTwo(app)
        let process = try shellPID(second, phase: "MOVE_BEFORE", in: app)
        let terminalFrame = pane(second, in: app).textViews.firstMatch.frame
        let detached = try moveToNewWindow(second, keeping: first, in: app)
        let detachedTerminal = detached.descendants(matching: .any)["FloatingPane-\(second)"].firstMatch
            .textViews.firstMatch.frame
        XCTAssertEqual(detachedTerminal.width, terminalFrame.width, accuracy: 5, "Detach must preserve terminal content width")
        XCTAssertEqual(detachedTerminal.height, terminalFrame.height, accuracy: 5, "Detach must preserve terminal content height")
        XCTAssertEqual(try shellPID(second, phase: "MOVE_AFTER", in: app), process)
    }

    /// Was testDragSplitWindowPositionWithFixedSize. Superseded: the same drop-at-cursor
    /// placement as above. Kept: with a fixed window size in the config, the new window
    /// uses that size.
    @MainActor
    func testMovePaneToNewWindowUsesTheConfiguredWindowSize() throws {
        let app = try launchFloatingApp() // window-width = 110, window-height = 32
        let sourceFrame = activeWindow(in: app).frame
        let (first, second) = try splitInTwo(app)
        let detached = try moveToNewWindow(second, keeping: first, in: app)
        XCTAssertEqual(detached.frame.width, sourceFrame.width, accuracy: 5, "New window should use size from config")
        XCTAssertEqual(detached.frame.height, sourceFrame.height, accuracy: 5, "New window should use size from config")
    }

    @MainActor
    private func splitInTwo(_ app: XCUIApplication) throws -> (String, String) {
        let first = try XCTUnwrap(paneIDs(in: app).first)
        app.typeKey("d", modifierFlags: .command)
        waitForPaneCount(2, in: app)
        return (first, try XCTUnwrap(paneIDs(in: app).first { $0 != first }))
    }

    /// Moves `id` out through its header menu and returns the new window, after checking
    /// that it holds only that pane and the source window keeps only `kept`.
    @MainActor
    private func moveToNewWindow(_ id: String, keeping kept: String, in app: XCUIApplication) throws -> XCUIElement {
        header(id, in: app).rightClick()
        let item = app.menuItems["Move Pane to New Window"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3) && item.isEnabled,
                      "A split pane's header must offer an enabled Move Pane to New Window")
        item.click()
        XCTAssertTrue(app.wait(for: \.windows.count, toEqual: 2, timeout: 5), "Moving a pane out must open a second window")
        func holder(of pane: String) -> XCUIElement? {
            app.windows.allElementsBoundByIndex.first { $0.descendants(matching: .any)["FloatingPane-\(pane)"].exists }
        }
        let detached = try XCTUnwrap(holder(of: id), "The moved pane must be in a window")
        let source = try XCTUnwrap(holder(of: kept), "The kept pane must stay in a window")
        // Each pane is in exactly one of the two windows.
        XCTAssertFalse(source.descendants(matching: .any)["FloatingPane-\(id)"].exists)
        XCTAssertFalse(detached.descendants(matching: .any)["FloatingPane-\(kept)"].exists)
        return detached
    }
}
