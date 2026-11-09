/*
 * tako — Native status toasts restore their terminal without granting OS permissions
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import XCTest

final class TakoDesktopToastUITests: TakoDesktopDesignCase {
    func testCompletionToastRestoresItsMinimizedTerminalAndKeyboardFocus() throws {
        let app = try launchDesktop()
        let first = try XCTUnwrap(paneIDs(in: app).first)
        app.typeKey("d", modifierFlags: .command)
        waitForPaneCount(2, in: app)
        let second = try XCTUnwrap(paneIDs(in: app).first { $0 != first })
        let pid = try shellPID(second, phase: "TOAST_BEFORE", in: app)
        let complete = try emitStatusUntilSignalled(second, in: app)
        control("Minimize", pane: second, in: app).click()
        waitForPaneCount(1, in: app)
        try Data().write(to: complete)
        let toast = app.descendants(matching: .any)["PaneToast-\(second)"].firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 5))
        toast.click()
        waitForPaneCount(2, in: app)
        XCTAssertTrue(toast.waitForNonExistence(timeout: 5))
        XCTAssertEqual(try shellPID(second, phase: "TOAST_AFTER", in: app, focus: false), pid)
    }

    func testExpiredToastDoesNotRestoreOrAcknowledgeTheMinimizedTerminal() throws {
        let app = try launchDesktop()
        let first = try XCTUnwrap(paneIDs(in: app).first)
        app.typeKey("d", modifierFlags: .command)
        waitForPaneCount(2, in: app)
        let second = try XCTUnwrap(paneIDs(in: app).first { $0 != first })
        let complete = try emitStatusUntilSignalled(second, in: app)
        control("Minimize", pane: second, in: app).click()
        waitForPaneCount(1, in: app)
        try Data().write(to: complete)
        let toast = app.descendants(matching: .any)["PaneToast-\(second)"].firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 5))
        XCTAssertTrue(toast.waitForNonExistence(timeout: 8))
        XCTAssertEqual(paneIDs(in: app), [first])
        XCTAssertTrue(minimizedCard(second, in: app).exists)
    }
}
