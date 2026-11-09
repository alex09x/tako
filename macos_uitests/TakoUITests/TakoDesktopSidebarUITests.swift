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
        let second = try XCTUnwrap(paneIDs(in: app).first { $0 != first })
        let process = try shellPID(second, phase: "SIDEBAR_HIDE_BEFORE", in: app)
        // The parent row represents the focused pane; capture it after the split.
        let row = activeWindow(in: app).descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'session-tab-' AND value == 'selected'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let originalRow = row.identifier
        app.buttons["SessionSidebarHeaderNewSession"].firstMatch.click()
        app.menuItems["New Session"].firstMatch.click()
        waitForPaneCount(1, in: app)
        XCTAssertFalse(paneIDs(in: app).contains(first))
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'session-tab-'"))
        XCTAssertGreaterThanOrEqual(rows.count, 2)
        activeWindow(in: app).descendants(matching: .any)[originalRow].firstMatch.click()
        waitForPaneCount(2, in: app)
        XCTAssertTrue(paneIDs(in: app).contains(first))
        XCTAssertEqual(try shellPID(second, phase: "SIDEBAR_SHOW_AFTER", in: app, focus: false), process)
    }

    func testActiveSessionStaysVisibleWhenReturningToAnOverflowingSidebar() throws {
        let app = try launchDesktop()
        func createSession() {
            let before = Set(paneIDs(in: app))
            app.typeKey("t", modifierFlags: .command)
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let ids = self.paneIDs(in: app)
                return ids.count == 1 && !before.contains(ids[0])
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 10), .completed)
        }
        for _ in 0..<14 { createSession() }
        let previousPane = try XCTUnwrap(paneIDs(in: app).first)
        let process = try shellPID(previousPane, phase: "SCROLL_BEFORE", in: app)
        func selectedRow() -> XCUIElement {
            activeWindow(in: app).descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH 'session-tab-' AND value == 'selected'")).firstMatch
        }
        let previousRow = selectedRow().identifier
        createSession()
        func assertSelectionVisible() {
            let row = selectedRow()
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            let list = activeWindow(in: app).descendants(matching: .any)["SessionSidebar"].firstMatch.scrollViews.firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 5))
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                list.frame.contains(row.frame.insetBy(dx: 1, dy: 1)) && row.isHittable
            }, object: row)
            XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed,
                           "The current session must remain inside the sidebar viewport after remount")
        }
        assertSelectionVisible()
        activeWindow(in: app).descendants(matching: .any)[previousRow].firstMatch.click()
        waitForPaneCount(1, in: app)
        XCTAssertEqual(paneIDs(in: app), [previousPane])
        assertSelectionVisible()
        XCTAssertEqual(try shellPID(previousPane, phase: "SCROLL_AFTER", in: app, focus: false), process)
    }
}
