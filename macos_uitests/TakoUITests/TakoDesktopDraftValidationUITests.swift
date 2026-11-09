/*
 * tako — Theme editor rejects invalid drafts and keeps cancellation atomic
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import XCTest

final class TakoDesktopDraftValidationUITests: TakoDesktopDesignCase {
    func testInvalidThemeNameDisablesSaveAndCancelLeavesConfigUntouched() throws {
        let app = try launchDesktop()
        let before = try configText()
        _ = openSettings(in: app)
        selectSection("appearance", in: app)
        clickSetting("DesktopThemeDuplicate", in: app)
        setText("../invalid", field: settings(in: app).textFields["DesktopThemeName"].firstMatch, in: app)
        let save = settings(in: app).buttons["DesktopThemeSave"].firstMatch
        XCTAssertFalse(save.isEnabled)
        XCTAssertTrue(settings(in: app).staticTexts["DesktopThemeError"].firstMatch.exists)
        settings(in: app).buttons["DesktopThemeCancel"].firstMatch.click()
        XCTAssertEqual(try configText(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: designDirectory.appendingPathComponent("invalid").path))
    }

    func testEveryThemeEditorTabOpensAndInvalidConfigCannotBeSaved() throws {
        let app = try launchDesktop()
        _ = openSettings(in: app)
        selectSection("appearance", in: app)
        clickSetting("DesktopThemeDuplicate", in: app)
        for tab in ["colors", "ansi", "type", "cursor", "config"] {
            clickSetting("DesktopThemeEditorSection-\(tab)", in: app)
            XCTAssertTrue(settings(in: app).buttons["DesktopThemeEditorSection-\(tab)"].firstMatch.isSelected)
        }
        let before = try configText()
        setText("background = definitely-not-a-color", field: settings(in: app).textViews["DesktopThemeConfiguration"].firstMatch, in: app)
        XCTAssertFalse(settings(in: app).buttons["DesktopThemeSave"].firstMatch.isEnabled)
        XCTAssertTrue(settings(in: app).staticTexts["DesktopThemeConfigError"].firstMatch.exists)
        settings(in: app).buttons["DesktopThemeCancel"].firstMatch.click()
        XCTAssertEqual(try configText(), before)
    }
}
