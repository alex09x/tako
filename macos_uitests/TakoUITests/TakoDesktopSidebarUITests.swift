/*
 * tako — Sidebar icons, keyboard search and plus-menu creation
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import XCTest

final class TakoDesktopSidebarUITests: TakoDesktopDesignCase {
    func testSettingsAndKeyboardIconsOpenTheirActualPages() throws {
        let app = try launchDesktop()
        app.buttons["SessionSidebarSettings"].firstMatch.click()
        XCTAssertTrue(settings(in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(settings(in: app).buttons["DesktopSettingsSection-general"].firstMatch.isSelected)
        closeSettings(in: app)
        app.buttons["SessionSidebarKeys"].firstMatch.click()
        XCTAssertTrue(settings(in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(settings(in: app).buttons["DesktopSettingsSection-keys"].firstMatch.isSelected)
        closeSettings(in: app)
    }

    func testCommandKFiltersAndEscapeRestoresSidebarWithoutClosingIt() throws {
        let app = try launchDesktop()
        let id = try XCTUnwrap(paneIDs(in: app).first)
        pane(id, in: app).textViews.firstMatch.click()
        app.typeKey("k", modifierFlags: .command)
        app.typeText("no-such-session-8675309")
        let search = app.textFields["SessionSidebarSearchField"].firstMatch
        XCTAssertEqual(search.value as? String, "no-such-session-8675309")
        XCTAssertTrue(app.buttons["SessionSidebarSearchClear"].firstMatch.exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(search.value as? String, "")
        XCTAssertTrue(search.isHittable)
        XCTAssertEqual(paneIDs(in: app), [id])
        XCTAssertFalse(app.buttons["SessionSidebarNewSession"].exists, "The retired footer is absent")
    }

    func testPlusMenuCreatesSplitAndSessionWithoutClosingExistingPane() throws {
        let app = try launchDesktop()
        let first = try XCTUnwrap(paneIDs(in: app).first)
        app.buttons["SessionSidebarHeaderNewSession"].firstMatch.click()
        let split = app.menuItems["New Terminal to the Right"].firstMatch
        XCTAssertTrue(split.waitForExistence(timeout: 5))
        split.click()
        waitForPaneCount(2, in: app)
        XCTAssertTrue(paneIDs(in: app).contains(first))
        app.buttons["SessionSidebarHeaderNewSession"].firstMatch.click()
        app.menuItems["New Session"].firstMatch.click()
        waitForPaneCount(1, in: app)
        XCTAssertFalse(paneIDs(in: app).contains(first))
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'session-tab-'"))
        XCTAssertGreaterThanOrEqual(rows.count, 2)
    }
}
