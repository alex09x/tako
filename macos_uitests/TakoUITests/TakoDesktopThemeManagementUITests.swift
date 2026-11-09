/*
 * tako — Renaming theme references and deleting unused custom presets
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import XCTest

final class TakoDesktopThemeManagementUITests: TakoDesktopDesignCase {
    private func newTheme(_ name: String, app: XCUIApplication) {
        _ = openSettings(in: app)
        selectSection("appearance", in: app)
        clickSetting("DesktopThemeDuplicate", in: app)
        setText(name, field: settings(in: app).textFields["DesktopThemeName"].firstMatch, in: app)
        settings(in: app).buttons["DesktopThemeSave"].firstMatch.click()
    }

    private func showMenu(_ name: String, app: XCUIApplication) {
        setText(name, field: settings(in: app).textFields["DesktopThemeFilter"].firstMatch, in: app)
        let more = settings(in: app).descendants(matching: .any)["DesktopThemeMenu-\(name)"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.click()
    }

    func testRenameMovesTheSelectedThemeReferenceAndUpdatesTheSelectedCard() throws {
        let app = try launchDesktop()
        newTheme("Original User Theme", app: app)
        showMenu("Original User Theme", app: app)
        app.menuItems["Rename…"].firstMatch.click()
        setText("Renamed User Theme", field: settings(in: app).textFields["DesktopThemeRenameField"].firstMatch, in: app)
        settings(in: app).buttons["DesktopThemeRenameConfirm"].firstMatch.click()
        XCTAssertTrue(try configText().contains("Renamed User Theme"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: designDirectory.appendingPathComponent("themes/Original User Theme").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: designDirectory.appendingPathComponent("themes/Renamed User Theme").path))
        setText("Renamed User Theme", field: settings(in: app).textFields["DesktopThemeFilter"].firstMatch, in: app)
        XCTAssertTrue(settings(in: app).buttons["DesktopTheme-Renamed User Theme"].firstMatch.isSelected)
    }

    func testThemeInUseCannotBeDeletedButUnusedThemeCanBeRemoved() throws {
        let app = try launchDesktop()
        newTheme("Disposable User Theme", app: app)
        showMenu("Disposable User Theme", app: app)
        let protected = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Удалить'")).firstMatch
        XCTAssertTrue(protected.exists)
        XCTAssertFalse(protected.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        setText("Tako Night", field: settings(in: app).textFields["DesktopThemeFilter"].firstMatch, in: app)
        clickSetting("DesktopTheme-Tako Night", in: app)
        showMenu("Disposable User Theme", app: app)
        app.menuItems["Delete…"].firstMatch.click()
        let file = designDirectory.appendingPathComponent("themes/Disposable User Theme")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(try configText().contains("Tako Night"))
    }
}
