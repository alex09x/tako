/*
 * tako — Settings pages, persisted controls, search and optional access
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import XCTest

final class TakoDesktopControlsUITests: TakoDesktopDesignCase {
    func testEverySectionIsReachableAndKeepsTheSameCenteredPanel() throws {
        let app = try launchDesktop()
        _ = openSettings(in: app)
        let frame = settings(in: app).frame
        for key in ["general", "interface", "appearance", "input", "windows", "quickTerminal",
                    "activity", "keys", "agents", "notifications", "advanced"] {
            selectSection(key, in: app)
            XCTAssertTrue(settings(in: app).buttons["DesktopSettingsSection-\(key)"].firstMatch.isSelected)
            assertRect(settings(in: app).frame, equals: frame)
            if ["general", "input", "quickTerminal"].contains(key) {
                captureSettings(app, name: "Native settings \(key): complete option labels")
            }
        }
        closeSettings(in: app)
    }

    func testStatusVisibilityAnimationAndCountsPersistAndResetIndependently() throws {
        let app = try launchDesktop()
        let ids = paneIDs(in: app)
        _ = openSettings(in: app)
        selectSection("activity", in: app)
        for key in ["status-show", "status-animate", "sidebar-count-waiting", "sidebar-count-error", "sidebar-count-done"] {
            clickSetting("DesktopSetting-\(key)", in: app)
            let changed = try configText()
            XCTAssertTrue(changed.contains("\(key) ="))
            clickSetting("DesktopSettingReset-\(key)", in: app)
            XCTAssertFalse(try configText().contains("\(key) ="), "Reset removes just this override")
        }
        closeSettings(in: app)
        XCTAssertEqual(paneIDs(in: app), ids)
    }

    func testSearchRoutesToKeyboardActionAndEscapeClosesSettings() throws {
        let app = try launchDesktop()
        _ = openSettings(in: app)
        setText("cmd+d", field: settings(in: app).textFields["DesktopSettingsSearch"].firstMatch, in: app)
        let hit = settings(in: app).descendants(matching: .any)["DesktopShortcut-new_split:right"].firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 5))
        hit.click()
        XCTAssertTrue(settings(in: app).buttons["DesktopSettingsSection-keys"].firstMatch.isSelected)
        XCTAssertTrue(settings(in: app).buttons["DesktopShortcutRecord"].firstMatch.isHittable)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(settings(in: app).waitForNonExistence(timeout: 5))
        XCTAssertEqual(paneIDs(in: app).count, 1)
    }

    func testPermissionExtrasCanExpandWithoutRequestingAccess() throws {
        let app = try launchDesktop()
        _ = openSettings(in: app)
        selectSection("notifications", in: app)
        let before = try configText()
        clickSetting("SetupPermissionExtras", in: app)
        XCTAssertTrue(settings(in: app).descendants(matching: .any)["SetupPermission-screenCapture"].firstMatch.exists)
        clickSetting("SetupPermissionExtras", in: app)
        XCTAssertEqual(try configText(), before)
        closeSettings(in: app)
        XCTAssertEqual(paneIDs(in: app).count, 1)
    }
}
