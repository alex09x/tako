/*
 * tako — Live appearance inheritance through workspace, session and pane
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import XCTest

final class TakoDesktopScopeUITests: TakoDesktopDesignCase {
    func testColorsOverAThemeInheritAndResetAtTheChosenLevel() throws {
        let app = try launchDesktop()
        let id = try XCTUnwrap(paneIDs(in: app).first)
        _ = openSettings(in: app)
        selectSection("appearance", in: app)
        level("workspace", in: app)
        clickSetting("DesktopScopeColorsDisclosure", in: app)
        let color = settings(in: app).textFields["DesktopScopeColor-background"].firstMatch
        setText("#123456", field: color, in: app)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(color.value as? String, "#123456")
        level("pane", in: app)
        clickSetting("DesktopScopeColorsDisclosure", in: app)
        let inherited = settings(in: app).textFields["DesktopScopeColor-background"].firstMatch
        XCTAssertEqual((inherited.value as? String)?.lowercased(), "#123456")
        setText("#263749", field: inherited, in: app)
        app.typeKey(.return, modifierFlags: [])
        clickSetting("DesktopInherit-background", in: app)
        XCTAssertEqual((inherited.value as? String)?.lowercased(), "#123456")
        closeSettings(in: app)
        XCTAssertEqual(paneIDs(in: app), [id])
    }

    private func level(_ key: String, in app: XCUIApplication) {
        let chip = settings(in: app).buttons["DesktopScope-\(key)"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        chip.click()
        XCTAssertTrue(settings(in: app).buttons["DesktopScopeCurrent"].firstMatch.waitForExistence(timeout: 5))
    }

    func testWorkspaceSessionPaneFractionalInheritanceAndFieldReset() throws {
        let app = try launchDesktop()
        let ids = paneIDs(in: app)
        _ = openSettings(in: app)
        selectSection("appearance", in: app)
        level("workspace", in: app)
        enterSize("15.5", in: app)
        assertSize("15.5", in: app)
        level("session", in: app)
        assertSize("15.5", in: app)
        enterSize("17.5", in: app)
        level("pane", in: app)
        assertSize("17.5", in: app)
        enterSize("19.5", in: app)
        assertSize("19.5", in: app)
        clickSetting("DesktopInherit-font-size", in: app)
        assertSize("17.5", in: app)
        level("session", in: app)
        clickSetting("DesktopInherit-font-size", in: app)
        assertSize("15.5", in: app)
        level("global", in: app)
        assertSize("13", in: app)
        XCTAssertTrue(try configText().contains("font-size = 13"))
        // The reset for a whole level must appear after its first override
        // and remove stored fields, so descendants resume real inheritance.
        level("workspace", in: app)
        let reset = settings(in: app).buttons["DesktopScopeResetAll"].firstMatch
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        XCTAssertTrue(reset.isHittable)
        reset.click()
        assertSize("13", in: app)
        XCTAssertTrue(reset.waitForNonExistence(timeout: 5))
        level("pane", in: app)
        assertSize("13", in: app)
        closeSettings(in: app)
        XCTAssertEqual(paneIDs(in: app), ids)
    }

    func testPaneOverrideDoesNotChangeItsSibling() throws {
        let app = try launchDesktop()
        let first = try XCTUnwrap(paneIDs(in: app).first)
        app.typeKey("d", modifierFlags: .command)
        waitForPaneCount(2, in: app)
        let second = try XCTUnwrap(paneIDs(in: app).first { $0 != first })
        pane(second, in: app).textViews.firstMatch.click()
        _ = openSettings(in: app)
        selectSection("appearance", in: app)
        level("pane", in: app)
        enterSize("21.5", in: app)
        assertSize("21.5", in: app)
        closeSettings(in: app)
        pane(first, in: app).textViews.firstMatch.click()
        _ = openSettings(in: app)
        selectSection("appearance", in: app)
        level("pane", in: app)
        assertSize("13", in: app)
        closeSettings(in: app)
        pane(second, in: app).textViews.firstMatch.click()
        _ = openSettings(in: app)
        selectSection("appearance", in: app)
        level("pane", in: app)
        assertSize("21.5", in: app)
    }
}
