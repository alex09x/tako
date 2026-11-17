/*
 * tako — Native desktop settings geometry, navigation and focus acceptance
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import XCTest

final class TakoDesktopSettingsUITests: TakoDesktopDesignCase {
    func testCenteredSettingsKeepTheirPositionAcrossSectionsAndRestoreTerminalFocus() throws {
        let app = try launchDesktop()
        let paneID = try XCTUnwrap(paneIDs(in: app).first)
        let process = try shellPID(paneID, phase: "DESIGN_SETTINGS_BEFORE", in: app)
        _ = openSettings(in: app)
        assertSettingsCentered(app)
        let initial = settings(in: app).frame
        for section in ["interface", "appearance", "keys", "activity", "general"] {
            selectSection(section, in: app)
            assertSettingsCentered(app)
            assertRect(settings(in: app).frame, equals: initial)
        }
        captureSettings(app, name: "Native settings centered on their terminal host")
        closeSettings(in: app)
        XCTAssertEqual(try shellPID(paneID, phase: "DESIGN_SETTINGS_AFTER", in: app, focus: false), process)
        XCTAssertEqual(paneIDs(in: app), [paneID])
    }

    func testApplicationAppearanceAndFractionalTerminalSizePersistIndependently() throws {
        let app = try launchDesktop()
        let paneID = try XCTUnwrap(paneIDs(in: app).first)
        let process = try shellPID(paneID, phase: "DESIGN_STYLE_BEFORE", in: app)
        _ = openSettings(in: app)
        selectSection("appearance", in: app)
        let size = settings(in: app).textFields["DesktopFontSize"].firstMatch
        setText("13.5", field: size, in: app)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(size.value as? String, "13.5")
        selectSection("interface", in: app)
        let light = settings(in: app).buttons["DesktopAppAppearance-light"].firstMatch
        reveal(light, in: app)
        XCTAssertTrue(light.isHittable)
        light.click()
        captureSettings(app, name: "Light application interface with independent terminal typography")
        selectSection("appearance", in: app)
        XCTAssertEqual(settings(in: app).textFields["DesktopFontSize"].firstMatch.value as? String, "13.5")
        closeSettings(in: app)
        XCTAssertEqual(try shellPID(paneID, phase: "DESIGN_STYLE_AFTER", in: app, focus: false), process)
        let config = try String(contentsOf: designConfig, encoding: .utf8)
        XCTAssertTrue(config.contains("app-appearance = light"))
        XCTAssertTrue(config.contains("font-size = 13.5"))
        app.terminate()
        app.launch()
        _ = openSettings(in: app)
        selectSection("appearance", in: app)
        XCTAssertEqual(settings(in: app).textFields["DesktopFontSize"].firstMatch.value as? String, "13.5")
    }
}
