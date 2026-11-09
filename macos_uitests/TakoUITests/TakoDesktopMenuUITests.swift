/*
 * tako — Appearance context menus on live terminal and sidebar owners
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import XCTest

final class TakoDesktopMenuUITests: TakoDesktopDesignCase {
    private func openAppearance(_ app: XCUIApplication) {
        let menu = app.menuItems["Appearance"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.hover()
    }

    func testTerminalContextMenuOpensPaneAppearance() throws {
        let app = try launchDesktop()
        let id = try XCTUnwrap(paneIDs(in: app).first)
        pane(id, in: app).textViews.firstMatch.rightClick()
        openAppearance(app)
        app.menuItems["All Themes…"].firstMatch.click()
        XCTAssertTrue(settings(in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(settings(in: app).buttons["DesktopScopeCurrent"].label.contains("terminal"))
        closeSettings(in: app)
        XCTAssertEqual(paneIDs(in: app), [id])
    }

    func testPaneHeaderContextMenuOpensCustomThemeEditor() throws {
        let app = try launchDesktop()
        let id = try XCTUnwrap(paneIDs(in: app).first)
        header(id, in: app).rightClick()
        openAppearance(app)
        app.menuItems["Customize…"].firstMatch.click()
        XCTAssertTrue(settings(in: app).textFields["DesktopThemeName"].firstMatch.waitForExistence(timeout: 5))
        settings(in: app).buttons["DesktopThemeCancel"].firstMatch.click()
        closeSettings(in: app)
        XCTAssertEqual(paneIDs(in: app), [id])
    }
}
