/*
 * tako — Sidebar workspace creation, rename, collapse and safe deletion
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import XCTest

final class TakoDesktopWorkspaceUITests: TakoDesktopDesignCase {
    private func createWorkspace(_ name: String, in app: XCUIApplication) {
        app.buttons["SessionSidebarHeaderNewSession"].firstMatch.click()
        let create = app.menuItems["SessionSidebarNewWorkspace"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.click()
        fillDialog(name, in: app)
    }

    private func fillDialog(_ name: String, in app: XCUIApplication) {
        let field = app.textFields["tako_dialog_text_field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText(name)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
    }

    private func workspace(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["SessionSidebarWorkspace-\(name)"].firstMatch
    }

    private func openMenu(_ name: String, in app: XCUIApplication) {
        let row = workspace(name, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        XCTAssertTrue(app.menuItems["SidebarWorkspaceNewSession"].firstMatch.waitForExistence(timeout: 5))
    }

    func testPlusMenuCreatesWorkspaceAndBusyWorkspaceCannotBeDeleted() throws {
        let app = try launchDesktop()
        let name = "Native Workspace"
        createWorkspace(name, in: app)
        XCTAssertTrue(workspace(name, in: app).waitForExistence(timeout: 5))
        openMenu(name, in: app)
        XCTAssertFalse(app.menuItems["SidebarWorkspaceDelete"].firstMatch.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(workspace(name, in: app).exists)
    }

    func testWorkspaceRenameCollapseAndNewSessionUseTheSelectedWorkspace() throws {
        let app = try launchDesktop()
        createWorkspace("Rename Me", in: app)
        openMenu("Rename Me", in: app)
        app.menuItems["SidebarWorkspaceRename"].firstMatch.click()
        fillDialog("Renamed Workspace", in: app)
        XCTAssertTrue(workspace("Rename Me", in: app).waitForNonExistence(timeout: 5))
        XCTAssertTrue(workspace("Renamed Workspace", in: app).waitForExistence(timeout: 5))
        openMenu("Renamed Workspace", in: app)
        app.menuItems["SidebarWorkspaceCollapse"].firstMatch.click()
        openMenu("Renamed Workspace", in: app)
        XCTAssertTrue(app.menuItems["Expand"].firstMatch.waitForExistence(timeout: 5))
        app.menuItems["SidebarWorkspaceCollapse"].firstMatch.click()
        openMenu("Renamed Workspace", in: app)
        app.menuItems["SidebarWorkspaceNewSession"].firstMatch.click()
        waitForPaneCount(1, in: app)
        XCTAssertEqual(workspace("Renamed Workspace", in: app).value as? String, "active")
    }
}
