/*
 * tako — Native shortcut recording and conflict acceptance
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import XCTest

final class TakoDesktopShortcutsUITests: TakoDesktopDesignCase {
    func testRecordingConflictCanCancelReassignAndResetWithoutExecutingShortcut() throws {
        let app = try launchDesktop()
        let paneID = try XCTUnwrap(paneIDs(in: app).first)
        let process = try shellPID(paneID, phase: "DESIGN_KEYS_BEFORE", in: app)
        _ = openSettings(in: app)
        selectSection("keys", in: app)
        let search = settings(in: app).textFields["DesktopSettingsSearch"].firstMatch
        setText("cmd+d", field: search, in: app)
        let action = settings(in: app).descendants(matching: .any)["DesktopShortcut-new_split:right"].firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.click()
        let record = settings(in: app).buttons["DesktopShortcutRecord"].firstMatch
        XCTAssertTrue(record.isHittable)
        record.click()
        app.typeKey("d", modifierFlags: [.command, .shift])
        let conflict = app.descendants(matching: .any)["DesktopShortcutConflict"].firstMatch
        XCTAssertTrue(conflict.waitForExistence(timeout: 5))
        XCTAssertEqual(paneIDs(in: app), [paneID], "A recorded key must not create a terminal")
        captureSettings(app, name: "Shortcut conflict names the existing owner")
        app.buttons["DesktopShortcutConflictCancel"].firstMatch.click()
        XCTAssertTrue(conflict.waitForNonExistence(timeout: 5))
        let before = try String(contentsOf: designConfig, encoding: .utf8)
        XCTAssertFalse(before.contains("keybind ="), "Cancelling must preserve the default bindings")

        record.click()
        app.typeKey("d", modifierFlags: [.command, .shift])
        XCTAssertTrue(conflict.waitForExistence(timeout: 5))
        app.buttons["DesktopShortcutConflictConfirm"].firstMatch.click()
        XCTAssertTrue(conflict.waitForNonExistence(timeout: 5))
        let assigned = try String(contentsOf: designConfig, encoding: .utf8)
        XCTAssertTrue(assigned.contains("new_split:right"))
        let reset = settings(in: app).buttons["DesktopShortcutReset"].firstMatch
        XCTAssertTrue(reset.isHittable)
        reset.click()
        let restored = try String(contentsOf: designConfig, encoding: .utf8)
        XCTAssertFalse(restored.contains("=new_split:right"))
        closeSettings(in: app)
        XCTAssertEqual(try shellPID(paneID, phase: "DESIGN_KEYS_AFTER", in: app, focus: false), process)
        app.typeKey("d", modifierFlags: .command)
        waitForPaneCount(2, in: app)
    }
}
