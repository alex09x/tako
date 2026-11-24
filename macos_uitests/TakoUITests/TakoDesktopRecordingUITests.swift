/*
 * tako — Shortcut cancellation, invalid input and backspace reset
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import XCTest

final class TakoDesktopRecordingUITests: TakoDesktopDesignCase {
    private func startRecord(_ app: XCUIApplication) {
        selectSection("keys", in: app)
        setText("cmd+d", field: settings(in: app).textFields["DesktopSettingsSearch"].firstMatch, in: app)
        let row = settings(in: app).descendants(matching: .any)["DesktopShortcut-new_split:right"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        settings(in: app).buttons["DesktopShortcutRecord"].firstMatch.click()
    }

    func testEscapeCancelsRecordingThenClosesPanelWithoutExecutingKeys() throws {
        let app = try launchDesktop()
        let before = try configText()
        _ = openSettings(in: app)
        startRecord(app)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(settings(in: app).exists)
        XCTAssertEqual(try configText(), before)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(settings(in: app).waitForNonExistence(timeout: 5))
        app.typeKey("d", modifierFlags: .command)
        waitForPaneCount(2, in: app)
    }

    func testUnmodifiedLetterIsRejectedWithoutEnteringTerminal() throws {
        let app = try launchDesktop()
        let before = try configText()
        _ = openSettings(in: app)
        startRecord(app)
        app.typeKey("z", modifierFlags: [])
        XCTAssertTrue(settings(in: app).staticTexts["DesktopSettingsError"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(try configText(), before)
        XCTAssertEqual(paneIDs(in: app).count, 1)
        app.typeKey(.escape, modifierFlags: [])
        closeSettings(in: app)
    }

    func testBackspaceRestoresDefaultAfterAssigningAnUnusedChord() throws {
        let app = try launchDesktop()
        _ = openSettings(in: app)
        startRecord(app)
        app.typeKey("9", modifierFlags: [.command, .control, .option, .shift])
        XCTAssertFalse(settings(in: app).descendants(matching: .any)["DesktopShortcutConflict"].exists)
        XCTAssertTrue(try configText().contains("new_split:right"))
        settings(in: app).buttons["DesktopShortcutRecord"].firstMatch.click()
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertFalse(try configText().contains("=new_split:right"))
        closeSettings(in: app)
        app.typeKey("d", modifierFlags: .command)
        waitForPaneCount(2, in: app)
    }
}
