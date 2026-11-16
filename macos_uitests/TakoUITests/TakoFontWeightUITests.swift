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
        let id = try XCTUnwrap(env.primaryPaneID)
        try env.recordControlSocket()
        let pane = H.terminalPane(in: app)
        pane.typeText("printf '\\033[2J\\033[H\\033[?25lALPHABET\\n'; exec sleep 600\n")
        var witness: H.GlyphObservation?
        XCTAssertTrue(H.wait { witness = try? H.glyphs(in: pane); return witness != nil })
        let original = try XCTUnwrap(witness)
        let originalConfig = try Data(contentsOf: env.configFile)

        // The terminal's «Appearance ▸ Customize…» opens native Settings at its session's
        // level with the theme it shows in the draft editor; a user theme is edited in
        // place. Settings covers the window, so the live preview is read from the pane's
        // own renderer; the screen is read again once Settings is closed. Saving also
        // assigns the preset at that level; the global configuration stays
        // byte-identical, as asserted at the end.
        let root = H.openAppearance(.customize, from: H.sessionRow(id, in: app), in: app)
        XCTAssertTrue(H.editor(in: root).waitForExistence(timeout: 5))
        XCTAssertEqual(H.editor(in: root).value as? String, name, "Customize edits the theme the terminal shows")
        var lightInk: (bounds: CGRect, pixels: Data)?
        XCTAssertTrue(H.wait { lightInk = try? env.rendererGlyphs(of: id); return lightInk != nil })
        let light = try XCTUnwrap(lightInk)
        setWeight(550, in: root)
        var medium: (bounds: CGRect, pixels: Data)?
        XCTAssertTrue(H.wait {
            medium = try? env.rendererGlyphs(of: id)
            return medium.map { self.ink($0.pixels) > self.ink(light.pixels) * 1.05 && $0.pixels != light.pixels } ?? false
        })
        let rendered550 = try XCTUnwrap(medium)
        XCTAssertLessThan(abs(rendered550.bounds.width - light.bounds.width), 6, "Weight must not act like a size change")
        root.buttons["DesktopThemeSave"].firstMatch.click()
        XCTAssertFalse(H.editor(in: root).waitForExistence(timeout: 2), "Save closes the draft")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("font-weight = 550"))

        // Edit it again from its card, preview 600, then Undo: the saved 550 comes back.
        editFromCard(name, in: root, app: app)
        setWeight(600, in: root)
        XCTAssertTrue(H.wait {
            guard let heavier = try? env.rendererGlyphs(of: id) else { return false }
            return self.ink(heavier.pixels) > self.ink(rendered550.pixels) * 1.01 && heavier.pixels != rendered550.pixels
        })
        root.buttons["DesktopThemeCancel"].firstMatch.click()
        XCTAssertFalse(H.editor(in: root).waitForExistence(timeout: 2), "Undo closes the draft")
        XCTAssertTrue(H.wait { (try? env.rendererGlyphs(of: id).pixels) == rendered550.pixels })
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("font-weight = 550"))
        H.closeSettings(root)
        // On screen: the saved weight, heavier than the 400 the terminal started with.
        var final: H.GlyphObservation?
        XCTAssertTrue(H.wait { final = try? H.glyphs(in: pane); return final.map { self.ink($0.pixels) > self.ink(original.pixels) * 1.05 } ?? false })
        if let final { H.attachScreenshot(final.screenshot, name: "variable-font-weight-550", to: self) }
        XCTAssertEqual(try Data(contentsOf: env.configFile), originalConfig)
    }

    /// The draft's exact configuration text with `font-weight` changed; the preset's
    /// other lines are kept.
    @MainActor private func setWeight(_ weight: Int, in root: XCUIElement) {
        let field = H.configurationField(in: root)
        let text = field.value as? String ?? ""
        XCTAssertTrue(text.contains("font-weight ="), "the draft is the witness preset: \(text)")
        H.pasteText(into: field, H.configuration(text, setting: [("font-weight", "\(weight)")]))
    }

    @MainActor private func editFromCard(_ name: String, in root: XCUIElement, app: XCUIApplication) {
        // The lazy card grid builds only the cards in view: filter to this one first.
        let filter = root.textFields["DesktopThemeFilter"].firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        H.replaceText(of: filter, with: name)
        let menu = root.descendants(matching: .any)["DesktopThemeMenu-\(name)"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.click()
        let edit = app.menuItems["Edit…"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.click()
        XCTAssertTrue(H.editor(in: root).waitForExistence(timeout: 5))
    }

    private func ink(_ pixels: Data) -> Double {
        Double(pixels.reduce(0) { $0 + Int($1) })
    }
}
