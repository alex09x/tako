/*
 * tako — Full named themes through real macOS UI
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import XCTest

final class TakoThemePresetUITests: TakoCustomConfigCase {
    private typealias H = TakoScopedAppearanceHelpers
    private let presetName = "XCUI Full Theme"
    private let config = "font-family = Monaco\nfont-size = 21\nbackground = #123456\nforeground = #c0ffee\npalette = 1=#fa1234\ncursor-style-blink = false\n"

    @MainActor private func openThemes(_ app: XCUIApplication) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let dialog = app.groups["TerminalSettingsDialog"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        dialog.typeKey("3", modifierFlags: .command)
        H.assertValue(dialog, contains: "Themes:")
        return dialog
    }

    @MainActor private func createDraft(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["ThemePresetNewButton"].click()
        let editor = app.groups["ThemePresetEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let field = app.textFields["ThemePresetName"]
        field.click(); field.typeKey("a", modifierFlags: .command); field.typeText(presetName)
        setConfig(config, editor: editor, app: app)
        return editor
    }

    @MainActor private func setConfig(_ text: String, editor: XCUIElement, app: XCUIApplication) {
        editor.typeKey("6", modifierFlags: .command)
        let field = app.textViews["ThemePresetConfiguration"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.click()
        field.typeKey("a", modifierFlags: .command); field.typeText(text)
    }

    @MainActor private func editSaved(_ app: XCUIApplication, dialog: XCUIElement) -> XCUIElement {
        H.search(presetName, in: dialog)
        dialog.typeKey("e", modifierFlags: .command)
        let editor = app.groups["ThemePresetEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["ThemePresetName"].value as? String, presetName)
        return editor
    }

    @MainActor func testPreviewCancelRestoresRendererWithoutPersisting() throws {
        let env = try H(); defer { env.cleanup() }
        let app = try env.launchIsolatedApp()
        let originalConfig = try Data(contentsOf: env.configFile)
        let pane = app.groups["Terminal pane"].firstMatch
        let original = try XCTUnwrap(H.samplePixelColor(from: pane))
        let parent = openThemes(app)
        let editor = createDraft(app)
        let dimmedOriginal = try XCTUnwrap(H.samplePixelColor(from: pane))
        app.buttons["ThemePresetPreviewButton"].click()
        H.assertValue(editor, contains: "theme_preview_success")
        XCTAssertTrue(H.wait { guard let color = H.samplePixelColor(from: pane) else { return false }; return H.colorDifference(dimmedOriginal, color) > 0.04 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.testRoot.appendingPathComponent("themes/\(presetName)").path))
        XCTAssertEqual(try Data(contentsOf: env.configFile), originalConfig)
        H.attachScreenshot(app.windows.firstMatch.screenshot(), name: "full-preset-live-preview", to: self)
        app.buttons["ThemePresetCancelButton"].click()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        XCTAssertTrue(H.wait { guard let color = H.samplePixelColor(from: pane) else { return false }; return H.colorDifference(dimmedOriginal, color) < 0.03 })
        H.dismissDialog(parent, in: app)
        XCTAssertTrue(H.wait { guard let color = H.samplePixelColor(from: pane) else { return false }; return H.colorDifference(original, color) < 0.03 })
    }

    @MainActor func testSavedThemeKeepsItsPaletteFontAndSizeAcrossRelaunch() throws {
        let env = try H(); defer { env.cleanup() }
        let app = try env.launchIsolatedApp()
        let pane = app.groups["Terminal pane"].firstMatch
        pane.typeText("printf '\\033[2J\\033[H\\033[?25lALPHABET\\n'; exec sleep 600\n")
        var before: H.GlyphObservation?
        XCTAssertTrue(H.wait { before = try? H.glyphs(in: pane); return before != nil })
        let original = try XCTUnwrap(before)
        let parent = openThemes(app)
        let editor = createDraft(app)
        app.buttons["ThemePresetSaveButton"].click()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        let url = env.testRoot.appendingPathComponent("themes/\(presetName)")
        let stored = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(stored.contains("font-family = Monaco") && stored.contains("font-size = 21") && stored.contains("1=#fa1234"))
        XCTAssertEqual(stored.components(separatedBy: "\n").filter { $0.hasPrefix("palette =") }.count, 16)
        H.dismissDialog(parent, in: app)
        var rendered: H.GlyphObservation?
        XCTAssertTrue(H.wait {
            rendered = try? H.glyphs(in: pane)
            return (rendered?.bounds.width ?? 0) > original.bounds.width * 1.35
        })
        let savedGlyphs = try XCTUnwrap(rendered)
        H.attachScreenshot(savedGlyphs.screenshot, name: "full-preset-rendered-font", to: self)
        app.terminate(); app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let restoredPane = app.groups["Terminal pane"].firstMatch
        restoredPane.typeText("printf '\\033[2J\\033[H\\033[?25lALPHABET\\n'; exec sleep 600\n")
        XCTAssertTrue(H.wait {
            guard let glyphs = try? H.glyphs(in: restoredPane) else { return false }
            return abs(glyphs.bounds.width - savedGlyphs.bounds.width) < savedGlyphs.bounds.width * 0.08
        })
        let reopened = openThemes(app)
        let edit = editSaved(app, dialog: reopened)
        edit.typeKey("6", modifierFlags: .command)
        let text = app.textViews["ThemePresetConfiguration"].value as? String ?? ""
        XCTAssertTrue(text.contains("font-size = 21") && text.contains("font-family = Monaco") && text.contains("1=#fa1234"))
        app.buttons["ThemePresetCancelButton"].click()
        H.dismissDialog(reopened, in: app)
    }

    @MainActor func testInvalidNameAndWriteFailurePreserveSavedPresetAndRenderer() throws {
        let env = try H(); defer { env.cleanup() }
        let app = try env.launchIsolatedApp()
        let parent = openThemes(app)
        let draft = createDraft(app)
        app.buttons["ThemePresetSaveButton"].click()
        XCTAssertTrue(draft.waitForNonExistence(timeout: 5))
        let url = env.testRoot.appendingPathComponent("themes/\(presetName)")
        let original = try Data(contentsOf: url)
        let invalid = editSaved(app, dialog: parent)
        let field = app.textFields["ThemePresetName"]
        field.click(); field.typeKey("a", modifierFlags: .command); field.typeText("../Invalid")
        app.buttons["ThemePresetSaveButton"].click()
        H.assertValue(invalid, contains: "theme_save_error:")
        XCTAssertTrue(invalid.exists)
        XCTAssertEqual(try Data(contentsOf: url), original)
        app.buttons["ThemePresetCancelButton"].click()
        let failure = editSaved(app, dialog: parent)
        setConfig(config.replacingOccurrences(of: "#123456", with: "#884422"), editor: failure, app: app)
        let pane = app.groups["Terminal pane"].firstMatch
        let before = try XCTUnwrap(H.samplePixelColor(from: pane))
        app.buttons["ThemePresetPreviewButton"].click()
        H.assertValue(failure, contains: "theme_preview_success")
        XCTAssertTrue(H.wait { guard let color = H.samplePixelColor(from: pane) else { return false }; return H.colorDifference(before, color) > 0.04 })
        let themes = url.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: themes.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: themes.path) }
        app.buttons["ThemePresetSaveButton"].click()
        H.assertValue(failure, contains: "theme_save_error:")
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertTrue(H.wait { guard let color = H.samplePixelColor(from: pane) else { return false }; return H.colorDifference(before, color) < 0.03 })
        app.buttons["ThemePresetCancelButton"].click()
        H.dismissDialog(parent, in: app)
    }
}
