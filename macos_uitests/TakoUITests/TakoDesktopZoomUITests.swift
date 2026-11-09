/*
 * tako — Transient pane zoom stays separate from saved fractional font size
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import XCTest

final class TakoDesktopZoomUITests: TakoDesktopDesignCase {
    private func openPaneSettings(_ app: XCUIApplication) {
        _ = openSettings(in: app)
        selectSection("appearance", in: app)
        let pane = settings(in: app).buttons["DesktopScope-pane"].firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
        pane.click()
    }

    func testZoomButtonsDoNotWriteTheBaseAndResetAfterChangingIt() throws {
        let app = try launchDesktop()
        openPaneSettings(app)
        let original = try configText()
        clickSetting("DesktopZoomIn", in: app)
        clickSetting("DesktopZoomIn", in: app)
        let reset = settings(in: app).buttons["DesktopZoomReset"].firstMatch
        XCTAssertTrue(reset.isEnabled)
        assertSize("13", in: app)
        XCTAssertEqual(try configText(), original)
        let description = settings(in: app).staticTexts.matching(NSPredicate(format: "label CONTAINS '+2 pt' OR value CONTAINS '+2 pt'")).firstMatch
        XCTAssertTrue(description.exists)
        clickSetting("DesktopZoomOut", in: app)
        clickSetting("DesktopZoomReset", in: app)
        XCTAssertFalse(reset.isEnabled)
        enterSize("17.5", in: app)
        assertSize("17.5", in: app)
        clickSetting("DesktopZoomIn", in: app)
        enterSize("18.5", in: app)
        assertSize("18.5", in: app)
        let zoomReset = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false"), object: reset)
        XCTAssertEqual(XCTWaiter.wait(for: [zoomReset], timeout: 5), .completed,
                       "Changing the saved base must refresh the temporary zoom controls immediately")
        closeSettings(in: app)
        app.typeKey("0", modifierFlags: .command)
        openPaneSettings(app)
        assertSize("18.5", in: app)
        reveal(settings(in: app).buttons["DesktopZoomReset"].firstMatch, in: app)
        XCTAssertFalse(settings(in: app).buttons["DesktopZoomReset"].firstMatch.isEnabled)
    }

    func testTerminalContextZoomAndResetPreserveConfigurationAndPaneIdentity() throws {
        let app = try launchDesktop()
        let id = try XCTUnwrap(paneIDs(in: app).first)
        let original = try configText()
        pane(id, in: app).textViews.firstMatch.rightClick()
        let increase = app.menuItems["TerminalZoomIn"].firstMatch
        XCTAssertTrue(increase.waitForExistence(timeout: 5))
        increase.click()
        pane(id, in: app).textViews.firstMatch.rightClick()
        let reset = app.menuItems["TerminalZoomReset"].firstMatch
        XCTAssertTrue(reset.isEnabled)
        reset.click()
        pane(id, in: app).textViews.firstMatch.rightClick()
        XCTAssertFalse(app.menuItems["TerminalZoomReset"].firstMatch.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(try configText(), original)
        XCTAssertEqual(paneIDs(in: app), [id])
    }
}
