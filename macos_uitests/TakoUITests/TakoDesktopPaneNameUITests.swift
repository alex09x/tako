/*
 * tako — User pane names survive restore without replacing program titles
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import XCTest

final class TakoDesktopPaneNameUITests: TakoDesktopDesignCase {
    private func rename(_ id: String, to name: String, in app: XCUIApplication) {
        header(id, in: app).rightClick()
        let rename = app.menuItems["FloatingPaneMenuRename"].firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.click()
        let field = app.textFields["tako_dialog_text_field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        app.typeKey("a", modifierFlags: .command)
        if name.isEmpty { app.typeKey(.delete, modifierFlags: []) } else { app.typeText(name) }
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
    }

    func testPaneNameSurvivesProgramTitleShelfAndPersistentRendererRelaunch() throws {
        let app = try launchFloatingApp(persistent: true)
        let id = try XCTUnwrap(paneIDs(in: app).first)
        let pid = try shellPID(id, phase: "PANE_NAME_BEFORE", in: app)
        rename(id, to: "My named terminal", in: app)
        XCTAssertTrue(header(id, in: app).label.contains("My named terminal"))
        pane(id, in: app).textViews.firstMatch.click()
        app.typeText("printf '\\033]0;Changed program title\\007'\n")
        XCTAssertTrue(header(id, in: app).label.contains("My named terminal"))
        control("Minimize", pane: id, in: app).click()
        waitForPaneCount(0, in: app)
        XCTAssertTrue(minimizedCard(id, in: app).label.contains("My named terminal"))
        minimizedCard(id, in: app).click()
        waitForPaneCount(1, in: app)
        app.terminate()
        app.launch()
        waitForPaneCount(1, in: app)
        XCTAssertEqual(paneIDs(in: app), [id])
        XCTAssertTrue(header(id, in: app).label.contains("My named terminal"))
        XCTAssertEqual(try shellPID(id, phase: "PANE_NAME_RESTORED", in: app), pid)
        rename(id, to: "", in: app)
        XCTAssertFalse(header(id, in: app).label.contains("My named terminal"))
    }
}
