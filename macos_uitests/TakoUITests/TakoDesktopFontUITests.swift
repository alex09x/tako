/*
 * tako — Physical font controls, fractional input and validation
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import XCTest

final class TakoDesktopFontUITests: TakoDesktopDesignCase {
    func testHalfPointButtonsAndDecimalCommaCommitWithoutRounding() throws {
        let app = try launchDesktop()
        _ = openSettings(in: app)
        selectSection("appearance", in: app)
        enterSize("13.5", in: app)
        assertSize("13.5", in: app)
        XCTAssertTrue(try configText().contains("font-size = 13.5"))
        clickSetting("DesktopFontSize-increase", in: app)
        assertSize("14", in: app)
        clickSetting("DesktopFontSize-decrease", in: app)
        assertSize("13.5", in: app)
        enterSize("14,5", in: app)
        assertSize("14.5", in: app)
        XCTAssertTrue(try configText().contains("font-size = 14.5"))
        closeSettings(in: app)
        _ = openSettings(in: app)
        selectSection("appearance", in: app)
        assertSize("14.5", in: app)
    }

    func testInvalidAndOutOfRangeSizeCannotOverwriteSavedConfiguration() throws {
        let app = try launchDesktop()
        _ = openSettings(in: app)
        selectSection("appearance", in: app)
        let before = try configText()
        enterSize("nonsense", in: app)
        assertSize("13", in: app)
        XCTAssertEqual(try configText(), before)
        // Correct the value through the same field editor after each rejection.
        replaceFocusedSize("73", in: app)
        XCTAssertTrue(settings(in: app).staticTexts["DesktopSettingsError"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(try configText(), before)
        replaceFocusedSize("13.5", in: app)
        assertSize("13.5", in: app)
        XCTAssertTrue(try configText().contains("font-size = 13.5"))
    }

    func testFontInventorySearchSelectAndReopenKeepsInstalledFont() throws {
        let app = try launchDesktop()
        _ = openSettings(in: app)
        selectSection("appearance", in: app)
        clickSetting("DesktopFontPicker", in: app)
        let filter = settings(in: app).textFields["DesktopFontFilter"].firstMatch
        setText("Menlo", field: filter, in: app)
        clickSetting("DesktopFont-Menlo", in: app)
        XCTAssertTrue(try configText().contains("font-family = Menlo"))
        setText("no-such-installed-font-8675309", field: filter, in: app)
        XCTAssertFalse(settings(in: app).buttons["DesktopFont-Menlo"].exists)
        setText("Menlo", field: filter, in: app)
        XCTAssertTrue(settings(in: app).buttons["DesktopFont-Menlo"].firstMatch.isSelected)
        closeSettings(in: app)
        _ = openSettings(in: app)
        selectSection("appearance", in: app)
        clickSetting("DesktopFontPicker", in: app)
        setText("Menlo", field: settings(in: app).textFields["DesktopFontFilter"].firstMatch, in: app)
        XCTAssertTrue(settings(in: app).buttons["DesktopFont-Menlo"].firstMatch.isSelected)
    }
}
