/*
 * tako — Numeric font weight changes actual displayed glyphs
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import XCTest

final class TakoFontWeightUITests: TakoCustomConfigCase {
    private typealias H = TakoScopedAppearanceHelpers

    @MainActor func testVariableWeight550And600ChangesInkAndCancelRestores550() throws {
        let env = try H(); defer { env.cleanup() }
        let name = "XCUI Weight Witness"
        let folder = env.testRoot.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try "# tako-preset-version: 1\nbackground = #101010\nforeground = #ffffff\nfont-family = Fira Code\nfont-size = 24\nfont-weight = 400\ncursor-style-blink = false\n".write(to: file, atomically: true, encoding: .utf8)
        let source = try String(contentsOf: env.configFile, encoding: .utf8)
        // Start with one complete preset assignment. Saving a complete
        // preset intentionally removes earlier global appearance fields.
        let base = source.components(separatedBy: "\n").filter {
            !$0.hasPrefix("theme =") && !$0.hasPrefix("cursor-style-blink =")
        }.joined(separator: "\n")
        try (base + "\ntheme = \(name)\n").write(to: env.configFile, atomically: true, encoding: .utf8)
        let app = try env.launchIsolatedApp()
        let pane = app.groups["Terminal pane"].firstMatch
        pane.typeText("printf '\\033[2J\\033[H\\033[?25lALPHABET\\n'; exec sleep 600\n")
        var witness: H.GlyphObservation?
        XCTAssertTrue(H.wait { witness = try? H.glyphs(in: pane); return witness != nil })
        let original = try XCTUnwrap(witness)
        let originalConfig = try Data(contentsOf: env.configFile)

        app.typeKey(",", modifierFlags: .command)
        let parent = app.groups["TerminalSettingsDialog"]
        XCTAssertTrue(parent.waitForExistence(timeout: 5))
        parent.typeKey("3", modifierFlags: .command)
        H.search(name, in: parent)
        parent.typeKey("e", modifierFlags: .command)
        let editor = app.groups["ThemePresetEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeKey("4", modifierFlags: .command)
        filterWeight(in: editor)
        let light = try XCTUnwrap(try? H.glyphs(in: pane))
        for _ in 0..<3 { editor.typeKey(.rightArrow, modifierFlags: []) }
        H.assertValue(editor, contains: "font-weight = 550")
        var medium: H.GlyphObservation?
        XCTAssertTrue(H.wait {
            medium = try? H.glyphs(in: pane)
            return medium.map { self.ink($0) > self.ink(light) * 1.05 && $0.pixels != light.pixels } ?? false
        })
        let rendered550 = try XCTUnwrap(medium)
        XCTAssertLessThan(abs(rendered550.bounds.width - light.bounds.width), 6, "Weight must not act like a size change")
        H.attachScreenshot(rendered550.screenshot, name: "variable-font-weight-550", to: self)
        app.buttons["ThemePresetSaveButton"].click()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("font-weight = 550"))

        parent.typeKey("e", modifierFlags: .command)
        let edited = app.groups["ThemePresetEditor"]
        XCTAssertTrue(edited.waitForExistence(timeout: 5))
        edited.typeKey("4", modifierFlags: .command)
        filterWeight(in: edited)
        edited.typeKey(.rightArrow, modifierFlags: [])
        H.assertValue(edited, contains: "font-weight = 600")
        XCTAssertTrue(H.wait {
            guard let heavier = try? H.glyphs(in: pane) else { return false }
            return self.ink(heavier) > self.ink(rendered550) * 1.01 && heavier.pixels != rendered550.pixels
        })
        app.buttons["ThemePresetCancelButton"].click()
        XCTAssertTrue(edited.waitForNonExistence(timeout: 5))
        XCTAssertTrue(H.wait { (try? H.glyphs(in: pane).pixels) == rendered550.pixels })
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("font-weight = 550"))
        H.dismissDialog(parent, in: app)
        XCTAssertTrue(H.wait { guard let final = try? H.glyphs(in: pane) else { return false }; return self.ink(final) > self.ink(original) * 1.05 })
        XCTAssertEqual(try Data(contentsOf: env.configFile), originalConfig)
    }

    @MainActor private func filterWeight(in editor: XCUIElement) {
        let field = editor.textFields["SettingsSearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.click()
        field.typeKey("a", modifierFlags: .command); field.typeText("regular weight")
        field.typeKey(.downArrow, modifierFlags: [])
    }

    private func ink(_ glyph: H.GlyphObservation) -> Double {
        Double(glyph.pixels.reduce(0) { $0 + Int($1) })
    }
}
