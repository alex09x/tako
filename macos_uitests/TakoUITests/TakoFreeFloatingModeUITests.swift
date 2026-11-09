/*
 * tako — Selected free mode stays undocked and above the session grid
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import XCTest

final class TakoFreeFloatingModeUITests: TakoDesktopDesignCase {
    private func makeTwo(_ app: XCUIApplication) throws -> (String, String) {
        let a = try XCTUnwrap(paneIDs(in: app).first)
        app.typeKey("d", modifierFlags: .command)
        waitForPaneCount(2, in: app)
        return (a, try XCTUnwrap(paneIDs(in: app).first { $0 != a }))
    }

    private func focusGrid(_ id: String, in app: XCUIApplication) {
        pane(id, in: app).textViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.95)).click()
    }

    private func selectPane(_ id: String, in app: XCUIApplication) {
        let row = activeWindow(in: app).descendants(matching: .any)["session-pane-\(id)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
    }

    private func orangePixels(_ image: XCUIScreenshot, borderOnly: Bool = false) throws -> Int {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: image.pngRepresentation))
        let w = bitmap.pixelsWide, h = bitmap.pixelsHigh, edge = max(1, min(bitmap.pixelsWide, bitmap.pixelsHigh) / 12)
        var found = 0
        for y in 0..<h { for x in 0..<w {
            let side = ((x < edge || x >= w - edge) && y >= h / 3 && y < 2 * h / 3)
                || ((y < edge || y >= h - edge) && x >= w / 3 && x < 2 * w / 3)
            guard !borderOnly || side, let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if color.redComponent - color.greenComponent > 0.06 && color.redComponent - color.blueComponent > 0.10 { found += 1 }
        } }
        return found
    }

    func testQuietFreeModeFollowsHeaderHoverAndRejectsEdgeAndPeerDocking() throws {
        let app = try launchDesktop()
        let (a, b) = try makeTwo(app)
        let process = try shellPID(b, phase: "FREE_DRAG_BEFORE", in: app)
        let toggle = control("Float", pane: b, in: app)
        XCTAssertFalse(toggle.isSelected)
        toggle.click()
        XCTAssertEqual(toggle.value as? String, "floating")
        XCTAssertTrue(toggle.isSelected)
        let original = pane(b, in: app).frame
        focusGrid(a, in: app)
        XCTAssertTrue(toggle.isSelected)
        XCTAssertEqual(try orangePixels(toggle.screenshot()), 0,
                       "The free toggle hides with the other controls when the header is not hovered")
        toggle.hover()
        XCTAssertGreaterThan(try orangePixels(toggle.screenshot()), 6, "Only the selected glyph gets a quiet orange tint")
        XCTAssertEqual(try orangePixels(toggle.screenshot(), borderOnly: true), 0, "No selected border or filled badge")
        focusGrid(a, in: app)
        XCTAssertEqual(try orangePixels(toggle.screenshot()), 0)
        for target in [CGVector(dx: 0.01, dy: 0.45), CGVector(dx: 0.6, dy: 0.1), CGVector(dx: 0.55, dy: 0.01)] {
            let from = header(b, in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            from.press(forDuration: 0.15, thenDragTo: canvas(in: app).coordinate(withNormalizedOffset: target))
            XCTAssertEqual(toggle.value as? String, "floating")
            XCTAssertTrue(toggle.isSelected)
            XCTAssertEqual(pane(b, in: app).frame.width, original.width, accuracy: 2)
            XCTAssertEqual(pane(b, in: app).frame.height, original.height, accuracy: 2)
            XCTAssertFalse(app.descendants(matching: .any)["CanvasDockPreview"].firstMatch.exists)
        }
        XCTAssertEqual(try shellPID(b, phase: "FREE_DRAG_AFTER", in: app), process)
        let shot = XCTAttachment(screenshot: activeWindow(in: app).screenshot())
        shot.name = "Quiet free mode with shared header hover and no docking"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testFreeWindowsStayAboveFocusedAndMaximizedGridAndRaiseWithinTheirOwnLayer() throws {
        let app = try launchDesktop()
        let (a, b) = try makeTwo(app)
        let aPID = try shellPID(a, phase: "LAYER_GRID_BEFORE", in: app)
        app.typeKey("d", modifierFlags: .command)
        waitForPaneCount(3, in: app)
        let c = try XCTUnwrap(paneIDs(in: app).first { $0 != a && $0 != b })
        let bPID = try shellPID(b, phase: "LAYER_FREE_BEFORE", in: app)
        control("Float", pane: b, in: app).click()
        control("Float", pane: c, in: app).click()
        let cPID = try shellPID(c, phase: "LAYER_SECOND_BEFORE", in: app)
        focusGrid(a, in: app)
        XCTAssertEqual(try shellPID(a, phase: "LAYER_GRID_FOCUSED", in: app, focus: false), aPID)
        pane(c, in: app).textViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertEqual(try shellPID(c, phase: "LAYER_FREE_HIT", in: app, focus: false), cPID)
        selectPane(b, in: app)
        func clickOverlap() {
            let overlap = pane(b, in: app).textViews.firstMatch.frame.intersection(pane(c, in: app).textViews.firstMatch.frame)
            XCTAssertFalse(overlap.isNull)
            let field = canvas(in: app)
            field.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: overlap.midX - field.frame.minX,
                                                                              dy: overlap.midY - field.frame.minY)).click()
        }
        clickOverlap()
        XCTAssertEqual(try shellPID(b, phase: "LAYER_FREE_RAISED", in: app, focus: false), bPID)
        control("Maximize", pane: a, in: app).click()
        focusGrid(a, in: app)
        XCTAssertEqual(try shellPID(a, phase: "LAYER_MAX_GRID", in: app, focus: false), aPID)
        clickOverlap()
        XCTAssertEqual(try shellPID(b, phase: "LAYER_ABOVE_MAX", in: app, focus: false), bPID)
        XCTAssertTrue(control("Float", pane: b, in: app).isSelected)
        XCTAssertTrue(control("Float", pane: c, in: app).isSelected)
    }

    func testMinimizeRestoreKeepsFreeRectAndTopLayerUntilExplicitReturnToGrid() throws {
        let app = try launchDesktop()
        let (a, b) = try makeTwo(app)
        let process = try shellPID(b, phase: "FREE_RESTORE_BEFORE", in: app)
        control("Float", pane: b, in: app).click()
        let original = pane(b, in: app).frame
        control("Minimize", pane: b, in: app).click()
        waitForPaneCount(1, in: app)
        minimizedCard(b, in: app).click()
        waitForPaneCount(2, in: app)
        assertRect(pane(b, in: app).frame, equals: original)
        XCTAssertTrue(control("Float", pane: b, in: app).isSelected)
        focusGrid(a, in: app)
        pane(b, in: app).textViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertEqual(try shellPID(b, phase: "FREE_RESTORE_AFTER", in: app, focus: false), process)
        control("Float", pane: b, in: app).click()
        XCTAssertEqual(control("Float", pane: b, in: app).value as? String, "tiled")
        XCTAssertFalse(control("Float", pane: b, in: app).isSelected)
    }
}
