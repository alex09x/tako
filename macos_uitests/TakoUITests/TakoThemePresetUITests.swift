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
    /// What the theme changes in the complete preset it is copied from.
    private let settings = [("font-family", "Monaco"), ("font-size", "21"), ("background", "#123456"), ("foreground", "#c0ffee")]
    private let palette = [1: "#fa1234"]

    /// The full-preset editor is native Settings › Terminal Appearance, opened at the
    /// default workspace's level by its row's «Appearance ▸ All Themes…». Contract on
    /// this route: a saved preset is assigned to that workspace (fixed id, so it
    /// survives a relaunch), not written as the global `theme =`.
    @MainActor private func openThemes(_ app: XCUIApplication) -> XCUIElement {
        H.openAppearance(.allThemes, from: H.workspaceRow(in: app), in: app)
    }

    /// «New Theme…»: an editable copy of the selected (complete) preset, renamed and
    /// changed in its exact configuration text.
    @MainActor private func createDraft(_ root: XCUIElement) {
        let new = root.buttons["DesktopThemeDuplicate"].firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 5))
        new.click()
        H.setThemeName(presetName, in: root)
        setConfig(background: "#123456", root: root)
    }

    @MainActor private func setConfig(background: String, root: XCUIElement) {
        let field = H.configurationField(in: root)
        let source = field.value as? String ?? ""
        XCTAssertFalse(source.isEmpty, "the draft starts from the copied preset's text")
        let changes = settings.map { $0.0 == "background" ? ($0.0, background) : $0 }
        H.pasteText(into: field, H.configuration(source, setting: changes, palette: palette))
    }

    @MainActor private func editSaved(_ root: XCUIElement, in app: XCUIApplication) {
        // The lazy card grid builds only the cards in view: filter to this one first.
        let filter = root.textFields["DesktopThemeFilter"].firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        H.replaceText(of: filter, with: presetName)
        let menu = root.descendants(matching: .any)["DesktopThemeMenu-\(presetName)"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.click()
        let edit = app.menuItems["Edit…"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.click()
        XCTAssertTrue(H.editor(in: root).waitForExistence(timeout: 5))
        XCTAssertEqual(H.editor(in: root).value as? String, presetName)
    }

    @MainActor func testPreviewCancelRestoresRendererWithoutPersisting() throws {
        let env = try H(); defer { env.cleanup() }
        let app = try env.launchIsolatedApp()
        let id = try XCTUnwrap(env.primaryPaneID)
        try env.recordControlSocket()
        let originalConfig = try Data(contentsOf: env.configFile)
        let pane = H.terminalPane(in: app)
        let original = try XCTUnwrap(H.samplePixelColor(from: pane))
        let rendered = try XCTUnwrap(env.rendererColor(of: id))
        let root = openThemes(app)
        createDraft(root)
        // Editing the complete theme previews on the pane's own renderer without a Save.
        XCTAssertTrue(H.wait { guard let color = env.rendererColor(of: id) else { return false }; return H.colorDifference(rendered, color) > 0.04 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.testRoot.appendingPathComponent("themes/\(presetName)").path))
        XCTAssertEqual(try Data(contentsOf: env.configFile), originalConfig)
        H.attachScreenshot(app.windows.firstMatch.screenshot(), name: "full-preset-live-preview", to: self)
        root.buttons["DesktopThemeCancel"].firstMatch.click()
        XCTAssertFalse(H.editor(in: root).waitForExistence(timeout: 2), "Undo closes the draft")
        XCTAssertTrue(H.wait { guard let color = env.rendererColor(of: id) else { return false }; return H.colorDifference(rendered, color) < 0.03 })
        H.closeSettings(root)
        XCTAssertTrue(H.wait { guard let color = H.samplePixelColor(from: pane) else { return false }; return H.colorDifference(original, color) < 0.03 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.testRoot.appendingPathComponent("themes/\(presetName)").path))
        XCTAssertEqual(try Data(contentsOf: env.configFile), originalConfig)
    }

    @MainActor func testSavedThemeKeepsItsPaletteFontAndSizeAcrossRelaunch() throws {
        let env = try H(); defer { env.cleanup() }
        let app = try env.launchIsolatedApp()
        let pane = H.terminalPane(in: app)
        pane.typeText("printf '\\033[2J\\033[H\\033[?25lALPHABET\\n'; exec sleep 600\n")
        var before: H.GlyphObservation?
        XCTAssertTrue(H.wait { before = try? H.glyphs(in: pane); return before != nil })
        let original = try XCTUnwrap(before)
        let root = openThemes(app)
        createDraft(root)
        root.buttons["DesktopThemeSave"].firstMatch.click()
        XCTAssertFalse(H.editor(in: root).waitForExistence(timeout: 2), "Save closes the draft")
        let url = env.testRoot.appendingPathComponent("themes/\(presetName)")
        let stored = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(stored.contains("font-family = Monaco") && stored.contains("font-size = 21") && stored.contains("1=#fa1234"))
        // A full preset: every ANSI colour of the complete theme it was copied from.
        XCTAssertEqual(stored.components(separatedBy: "\n").filter { $0.hasPrefix("palette =") }.count, 16)
        H.closeSettings(root)
        var rendered: H.GlyphObservation?
        XCTAssertTrue(H.wait {
            rendered = try? H.glyphs(in: pane)
            return (rendered?.bounds.width ?? 0) > original.bounds.width * 1.35
        })
        let savedGlyphs = try XCTUnwrap(rendered)
        H.attachScreenshot(savedGlyphs.screenshot, name: "full-preset-rendered-font", to: self)
        app.terminate(); app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let restoredPane = H.terminalPane(in: app)
        restoredPane.typeText("printf '\\033[2J\\033[H\\033[?25lALPHABET\\n'; exec sleep 600\n")
        XCTAssertTrue(H.wait {
            guard let glyphs = try? H.glyphs(in: restoredPane) else { return false }
            return abs(glyphs.bounds.width - savedGlyphs.bounds.width) < savedGlyphs.bounds.width * 0.08
        })
        let reopened = openThemes(app)
        editSaved(reopened, in: app)
        let text = H.configurationField(in: reopened).value as? String ?? ""
        XCTAssertTrue(text.contains("font-size = 21") && text.contains("font-family = Monaco") && text.contains("1=#fa1234"))
        reopened.buttons["DesktopThemeCancel"].firstMatch.click()
        H.closeSettings(reopened)
    }

    @MainActor func testInvalidNameAndWriteFailurePreserveSavedPresetAndRenderer() throws {
        let env = try H(); defer { env.cleanup() }
        let app = try env.launchIsolatedApp()
        let id = try XCTUnwrap(env.primaryPaneID)
        try env.recordControlSocket()
        let root = openThemes(app)
        createDraft(root)
        root.buttons["DesktopThemeSave"].firstMatch.click()
        XCTAssertFalse(H.editor(in: root).waitForExistence(timeout: 2))
        let url = env.testRoot.appendingPathComponent("themes/\(presetName)")
        let original = try Data(contentsOf: url)

        // An invalid name is refused before anything is written.
        editSaved(root, in: app)
        H.setThemeName("../Invalid", in: root)
        let save = root.buttons["DesktopThemeSave"].firstMatch
        XCTAssertFalse(save.isEnabled, "an invalid name cannot be saved")
        XCTAssertTrue(root.staticTexts["DesktopThemeError"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(try Data(contentsOf: url), original)
        root.buttons["DesktopThemeCancel"].firstMatch.click()

        // A failed write keeps the saved file; the draft stays open and previewed with
        // the error shown, and only Undo gives the pane its saved look back.
        let before = try XCTUnwrap(env.rendererColor(of: id))
        editSaved(root, in: app)
        setConfig(background: "#884422", root: root)
        XCTAssertTrue(H.wait { guard let color = env.rendererColor(of: id) else { return false }; return H.colorDifference(before, color) > 0.04 })
        let themes = url.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: themes.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: themes.path) }
        root.buttons["DesktopThemeSave"].firstMatch.click()
        XCTAssertTrue(root.staticTexts["DesktopThemeError"].firstMatch.waitForExistence(timeout: 5), "the failed write is reported")
        XCTAssertTrue(H.editor(in: root).exists, "the draft stays open after a failed write")
        XCTAssertEqual(try Data(contentsOf: url), original)
        root.buttons["DesktopThemeCancel"].firstMatch.click()
        XCTAssertTrue(H.wait { guard let color = env.rendererColor(of: id) else { return false }; return H.colorDifference(before, color) < 0.03 })
        H.closeSettings(root)
    }
}
