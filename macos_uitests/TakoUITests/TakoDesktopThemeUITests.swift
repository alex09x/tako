/*
 * tako — Native custom theme draft and renderer acceptance
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import XCTest

final class TakoDesktopThemeUITests: TakoDesktopDesignCase {
    private typealias Visuals = TakoScopedAppearanceHelpers

    func testCustomThemePreviewCancelAndSaveReachTheRealTerminal() throws {
        let app = try launchDesktop()
        let paneID = try XCTUnwrap(paneIDs(in: app).first)
        let process = try shellPID(paneID, phase: "DESIGN_THEME_BEFORE", in: app)
        _ = openSettings(in: app)
        selectSection("appearance", in: app)
        let selected = settings(in: app).buttons["DesktopTheme-Tako Night"].firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        selected.click()
        let original = try Data(contentsOf: designConfig)
        let terminal = pane(paneID, in: app).textViews.firstMatch
        let before = try XCTUnwrap(Visuals.samplePixelColor(from: terminal))
        let name = "Design Copy \(UUID().uuidString.prefix(8))"
        let saved = designDirectory.appendingPathComponent("themes").appendingPathComponent(name)

        try openDraft(name, app: app)
        XCTAssertTrue(Visuals.wait {
            guard let color = Visuals.samplePixelColor(from: terminal) else { return false }
            return Visuals.colorDifference(before, color) > 0.05
        }, "Draft edits must change the actual terminal renderer")
        XCTAssertEqual(try Data(contentsOf: designConfig), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path))
        settings(in: app).buttons["DesktopThemeCancel"].firstMatch.click()
        XCTAssertTrue(Visuals.wait {
            guard let color = Visuals.samplePixelColor(from: terminal) else { return false }
            return Visuals.colorDifference(before, color) < 0.03
        }, "Cancel must restore the terminal appearance")
        XCTAssertEqual(try Data(contentsOf: designConfig), original)

        try openDraft(name, app: app)
        captureSettings(app, name: "Native editable custom theme with live preview")
        settings(in: app).buttons["DesktopThemeSave"].firstMatch.click()
        XCTAssertTrue(Visuals.wait { FileManager.default.fileExists(atPath: saved.path) })
        let text = try String(contentsOf: saved, encoding: .utf8)
        XCTAssertTrue(text.contains("# tako-preset-version: 1"))
        XCTAssertTrue(text.contains("font-size = 21"))
        XCTAssertTrue(text.contains("background = #123456"))
        XCTAssertTrue(try String(contentsOf: designConfig, encoding: .utf8).contains(name))
        closeSettings(in: app)
        XCTAssertEqual(try shellPID(paneID, phase: "DESIGN_THEME_AFTER", in: app, focus: false), process)
        app.terminate()
        app.launch()
        _ = openSettings(in: app)
        selectSection("appearance", in: app)
        XCTAssertTrue(settings(in: app).buttons["DesktopTheme-\(name)"].firstMatch.waitForExistence(timeout: 5))
    }

    private func openDraft(_ name: String, app: XCUIApplication) throws {
        let duplicate = settings(in: app).buttons["DesktopThemeDuplicate"].firstMatch
        XCTAssertTrue(duplicate.isHittable)
        duplicate.click()
        setText(name, field: settings(in: app).textFields["DesktopThemeName"].firstMatch, in: app)
        let configTab = settings(in: app).buttons["DesktopThemeEditorSection-config"].firstMatch
        XCTAssertTrue(configTab.isHittable)
        configTab.click()
        let field = settings(in: app).textViews["DesktopThemeConfiguration"].firstMatch
        setText("""
        # tako-preset-version: 1
        background = #123456
        foreground = #eeeeee
        font-family = Menlo
        font-size = 21
        cursor-color = #f4581c
        selection-background = #352b23
        """, field: field, in: app)
        app.typeKey(.tab, modifierFlags: [])
    }
}
