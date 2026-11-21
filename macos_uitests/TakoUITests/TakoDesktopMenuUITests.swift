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
    func testHeaderMenuSplitsBothDirectionsAndControlsPresentation() throws {
        let app = try launchDesktop()
        let id = try XCTUnwrap(paneIDs(in: app).first)
        let process = try shellPID(id, phase: "MENU_BEFORE", in: app)
        header(id, in: app).rightClick()
        app.menuItems["FloatingPaneMenuSplitRight"].firstMatch.click()
        waitForPaneCount(2, in: app)
        header(id, in: app).rightClick()
        app.menuItems["FloatingPaneMenuSplitDown"].firstMatch.click()
        waitForPaneCount(3, in: app)
        header(id, in: app).rightClick()
        app.menuItems["FloatingPaneMenuMaximize"].firstMatch.click()
        XCTAssertEqual(control("Maximize", pane: id, in: app).value as? String, "maximized")
        header(id, in: app).rightClick()
        app.menuItems["FloatingPaneMenuMaximize"].firstMatch.click()
        header(id, in: app).rightClick()
        app.menuItems["FloatingPaneMenuFloat"].firstMatch.click()
        XCTAssertEqual(control("Float", pane: id, in: app).value as? String, "floating")
        header(id, in: app).rightClick()
        XCTAssertFalse(app.menuItems["FloatingPaneMenuSplitRight"].firstMatch.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        control("Maximize", pane: id, in: app).click()
        header(id, in: app).rightClick()
        XCTAssertFalse(app.menuItems["FloatingPaneMenuSplitRight"].firstMatch.isEnabled)
        XCTAssertTrue(app.menuItems["Return to Grid"].firstMatch.waitForExistence(timeout: 5))
        app.menuItems["FloatingPaneMenuFloat"].firstMatch.click()
        header(id, in: app).rightClick()
        app.menuItems["FloatingPaneMenuMinimize"].firstMatch.click()
        waitForPaneCount(2, in: app)
        minimizedCard(id, in: app).click()
        waitForPaneCount(3, in: app)
        XCTAssertEqual(try shellPID(id, phase: "MENU_AFTER", in: app, focus: false), process)
    }

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
