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
        let saved = NSColor(srgbRed: 18.0 / 255, green: 52.0 / 255, blue: 86.0 / 255, alpha: 1)
        let draft = NSColor(srgbRed: 136.0 / 255, green: 68.0 / 255, blue: 34.0 / 255, alpha: 1)
        let baseline = expectRenderer(saved, phase: "saved preset", env: env, pane: id, app: app)
        editSaved(root, in: app)
        setConfig(background: "#884422", root: root)
        expectRenderer(draft, phase: "draft preview", env: env, pane: id, app: app, baseline: baseline)
        let themes = url.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: themes.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: themes.path) }
        root.buttons["DesktopThemeSave"].firstMatch.click()
        XCTAssertTrue(root.staticTexts["DesktopThemeError"].firstMatch.waitForExistence(timeout: 5), "the failed write is reported")
        XCTAssertTrue(H.editor(in: root).exists, "the draft stays open after a failed write")
        XCTAssertEqual(try Data(contentsOf: url), original)
        expectRenderer(draft, phase: "failed write keeps preview", env: env, pane: id, app: app, baseline: baseline)
        root.buttons["DesktopThemeCancel"].firstMatch.click()
        expectRenderer(saved, phase: "Undo restores saved background", env: env, pane: id, app: app, baseline: baseline)
        H.closeSettings(root)
    }

    // MARK: - Renderer evidence

    private struct RendererProbe {
        var background: NSColor?, image: CGImage?, error: String?
    }

    @discardableResult
    @MainActor private func expectRenderer(
        _ expected: NSColor, phase: String, env: H, pane: String, app: XCUIApplication,
        baseline: RendererProbe? = nil, file: StaticString = #filePath, line: UInt = #line
    ) -> RendererProbe {
        var last = RendererProbe()
        var samples = 0
        let matched = H.wait {
            samples += 1
            do {
                let image = try env.rendererImage(of: pane)
                last = RendererProbe(background: Self.backgroundColor(image), image: image)
            } catch {
                last = RendererProbe(error: String(describing: error))
            }
            guard let color = last.background else { return false }
            return H.colorDifference(expected, color) < 0.03
        }
        if !matched {
            report(expected: expected, phase: phase, baseline: baseline, last: last, samples: samples, app: app)
        } else {
            print("RENDERER-PROBE \(phase) background=\(Self.hex(last.background)) samples=\(samples)")
        }
        XCTAssertTrue(matched, "Unexpected renderer color: \(phase)", file: file, line: line)
        return last
    }

    /// Sample an interior majority so one cursor or glyph cannot stand in for the background.
    private static func backgroundColor(_ cg: CGImage) -> NSColor? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let grid = [0.25, 0.5, 0.75]
        var counts: [UInt32: Int] = [:]
        for y in grid {
            for x in grid {
                let offset = (Int(Double(cg.height) * y) * cg.width + Int(Double(cg.width) * x)) * 4
                let rgb = UInt32(data[offset]) << 16 | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2])
                counts[rgb, default: 0] += 1
            }
        }
        guard let majority = counts.first(where: { $0.value > grid.count * grid.count / 2 })?.key else { return nil }
        return NSColor(srgbRed: CGFloat((majority >> 16) & 0xff) / 255, green: CGFloat((majority >> 8) & 0xff) / 255,
                       blue: CGFloat(majority & 0xff) / 255, alpha: 1)
    }

    private static func hex(_ color: NSColor?) -> String {
        guard let c = color?.usingColorSpace(.sRGB) else { return "nil" }
        return String(format: "#%02x%02x%02x", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }

    @MainActor private func report(expected: NSColor, phase: String, baseline: RendererProbe?, last: RendererProbe, samples: Int, app: XCUIApplication) {
        let size = last.image.map { "\($0.width)x\($0.height)" } ?? "nil"
        let corner = last.image.flatMap { H.samplePixelColor(from: $0) }
        let text = "\(phase): expected=\(Self.hex(expected)) baseline=\(Self.hex(baseline?.background))\n"
            + "last background=\(Self.hex(last.background)) corner=\(Self.hex(corner)) image=\(size) error=\(last.error ?? "-") samples=\(samples)"
        let note = XCTAttachment(string: text); note.name = "renderer-probe"; note.lifetime = .keepAlways; add(note)
        for (name, image) in [("renderer-baseline", baseline?.image), ("renderer-last", last.image)] {
            guard let image else { continue }
            let png = XCTAttachment(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
            png.name = name; png.lifetime = .keepAlways; add(png)
        }
        H.attachScreenshot(app.windows.firstMatch.screenshot(), name: "window-at-renderer-failure", to: self)
        print("RENDERER-PROBE " + text.replacingOccurrences(of: "\n", with: " | "))
    }
}
