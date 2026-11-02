/*
 * tako — Full theme create, preview, cancel and save journey
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import ApplicationServices
import Foundation
import Vision

func runThemePresetScenario(_ d: Driver) throws {
    d.quit()
    let initialConfig = "window-save-state = never\nauto-update = off\nremote-control = on\nsession-persistence = false\nconfirm-close-surface = never\ncommand = /bin/sh\ncursor-style-blink = false\nfont-size = 13\nforeground = #ffffff\n"
    try d.launch(config: initialConfig)
    try d.run("printf '\\033[2J\\033[H\\033[?25lALPHABET\\n\\033[48;5;1m    \\033[0m\\n'; exec sleep 600")
    let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
    let configPath = d.path("config")
    func processIdentity() throws -> (String, Int) {
        let raw = try d.exec("\(ctl) tree --json")
        let outer = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] ?? [:]
        let result = outer["result"] as? [String: Any] ?? outer
        let panes = (result["windows"] as? [[String: Any]] ?? []).flatMap { $0["tabs"] as? [[String: Any]] ?? [] }
            .flatMap { $0["panes"] as? [[String: Any]] ?? [] }
        guard let pane = panes.first, let id = pane["id"] as? String, let pid = pane["pid"] as? Int else { throw Failure("missing live pane identity") }
        return (id, pid)
    }
    let originalProcess = try processIdentity()
    let themeName = "E2E Custom Theme"
    let themeURL = d.work.appendingPathComponent("themes").appendingPathComponent(themeName)
    let source = "font-family = Monaco\nfont-size = 21\nbackground = #123456\nforeground = #c0ffee\npalette = 1=#fa1234\npalette = 15=#feabcd\ncursor-style-blink = false\n"

    func button(_ id: String) throws {
        guard d.wait(for: { d.element(withIdentifier: id) != nil }, timeout: 5),
              let element = d.element(withIdentifier: id) else { throw Failure("missing button: \(id)") }
        d.press(element)
    }
    func editorValue() -> String {
        guard let element = d.element(withIdentifier: "ThemePresetEditor") else { return "" }
        return (d.attribute(element, kAXValueAttribute) as String?) ?? ""
    }
    func createDraft() throws {
        try button("ThemePresetNewButton")
        guard d.wait(for: { d.element(withIdentifier: "ThemePresetEditor") != nil }, timeout: 5) else { throw Failure("theme editor did not open") }
        d.key(Key.a, .maskCommand)
        try d.type(themeName)
        d.key(Key.returnKey) // Commit name and focus the Colors list.
        for _ in 0..<11 { d.key(Key.down) } // Palette 1 after all terminal and status colors.
        d.key(Key.returnKey)
        guard d.wait(for: { d.textField(identifier: "terminal-setting-color-palette:1") != nil }, timeout: 5) else {
            throw Failure("ANSI 1 structured color editor did not open")
        }
        d.key(Key.a, .maskCommand); try d.type("#fa1234"); d.key(Key.returnKey)
        for _ in 0..<14 { d.key(Key.down) } // Scroll to the last ANSI color.
        d.key(Key.returnKey)
        guard d.wait(for: { d.textField(identifier: "terminal-setting-color-palette:15") != nil }, timeout: 5) else {
            throw Failure("last ANSI color was not reachable through the scrolling list")
        }
        d.key(Key.a, .maskCommand); try d.type("#feabcd"); d.key(Key.returnKey)
        d.key(21, .maskCommand) // Fonts
        d.key(Key.slash); try d.type("Monaco"); d.key(Key.returnKey)
        guard d.wait(for: { editorValue().contains("font-family = Monaco") }, timeout: 5) else { throw Failure("draft font family did not apply") }
        d.key(Key.slash); d.key(Key.a, .maskCommand); d.key(51); d.key(Key.down)
        d.key(23, .maskCommand) // Font Size
        for _ in 0..<8 { d.key(Key.right) }
        d.key(22, .maskCommand) // Cmd+6: full configuration
        guard d.wait(for: { editorValue().hasPrefix("Config:") }, timeout: 5),
              let text = d.element(withIdentifier: "ThemePresetConfiguration"),
              let draft = d.attribute(text, kAXValueAttribute) as String?, draft.contains("font-size = 21"),
              draft.contains("font-family = Monaco"), draft.contains("1=#fa1234"), draft.contains("15=#feabcd") else {
            throw Failure("structured palette/font changes did not reach complete config: \(editorValue())")
        }
        d.key(Key.a, .maskCommand)
        try d.type(source)
    }
    func background(_ name: String) throws -> NSColor {
        let path = d.path(name + ".png")
        _ = try d.exec("\(ctl) screenshot --out \(path)")
        guard let image = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path))),
              let color = pixel(image, x: image.pixelsWide - 8, y: image.pixelsHigh - 8) else {
            throw Failure("cannot inspect terminal pixels")
        }
        return color
    }
    // The control renderer writes sRGB PNG bytes. NSBitmapImageRep.colorAt
    // returns a calibrated NSColor on this macOS version; converting that
    // again changes #123456 despite the PNG bytes being exactly 18,52,86.
    func pixel(_ image: NSBitmapImageRep, x: Int, y: Int) -> NSColor? {
        guard image.bitsPerSample == 8, image.samplesPerPixel >= 3 else { return nil }
        var values = [Int](repeating: 0, count: image.samplesPerPixel)
        image.getPixel(&values, atX: x, y: y)
        let offset = image.bitmapFormat.contains(.alphaFirst) ? 1 : 0
        guard values.count >= offset + 3 else { return nil }
        return NSColor(srgbRed: CGFloat(values[offset]) / 255, green: CGFloat(values[offset + 1]) / 255,
                       blue: CGFloat(values[offset + 2]) / 255, alpha: 1)
    }
    func difference(_ a: NSColor, _ b: NSColor) -> CGFloat {
        abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
    }
    func palettePixels(_ name: String) throws -> Int {
        let path = d.path(name + ".png")
        _ = try d.exec("\(ctl) screenshot --out \(path)")
        guard let image = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path))) else { throw Failure("missing palette screenshot") }
        var count = 0
        for y in stride(from: 0, to: min(250, image.pixelsHigh), by: 2) {
            for x in stride(from: 0, to: min(400, image.pixelsWide), by: 2) {
                guard let c = pixel(image, x: x, y: y) else { continue }
                if abs(c.redComponent - 250 / 255.0) < 0.02 && abs(c.greenComponent - 18 / 255.0) < 0.02 && abs(c.blueComponent - 52 / 255.0) < 0.02 { count += 1 }
            }
        }
        return count
    }
    func glyphBounds(_ name: String) throws -> CGSize {
        let path = d.path(name + ".png")
        _ = try d.exec("\(ctl) screenshot --out \(path)")
        guard let image = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path)))?.cgImage else {
            throw Failure("missing glyph screenshot")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let word = request.results?.first(where: { $0.topCandidates(1).first?.string == "ALPHABET" }) else {
            throw Failure("rendered font witness was not recognized")
        }
        return CGSize(width: word.boundingBox.width * CGFloat(image.width), height: word.boundingBox.height * CGFloat(image.height))
    }
    func waitBackground(_ expected: NSColor, name: String) throws {
        var observed: NSColor?
        guard d.wait(for: { guard let color = try? background(name) else { return false }; return difference(color, expected) < 0.025 }, timeout: 10) else {
            observed = try? background(name)
            let proof = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("target/appearance-ui-proof")
            try? FileManager.default.createDirectory(at: proof, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: proof.appendingPathComponent(name + ".png"))
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: d.path(name + ".png")), to: proof.appendingPathComponent(name + ".png"))
            throw Failure("rendered background did not match \(name): got \(String(describing: observed)), expected \(expected); editor=\(editorValue())")
        }
    }
    let before = try background("preset-original")
    var originalGlyphs: CGSize?
    guard d.wait(for: { originalGlyphs = try? glyphBounds("preset-glyphs-original"); return originalGlyphs != nil }, timeout: 10),
          let originalGlyphs else { throw Failure("font witness was not rendered before editing") }
    let blue = NSColor(srgbRed: 0x12 / 255.0, green: 0x34 / 255.0, blue: 0x56 / 255.0, alpha: 1)
    d.key(Key.comma, .maskCommand)
    d.key(Key.three, .maskCommand)

    // Preview changes the renderer but not config/preset files; Cancel restores.
    try createDraft()
    try button("ThemePresetPreviewButton")
    guard d.wait(for: { editorValue().hasPrefix("theme_preview_success:") }, timeout: 5) else { throw Failure("preview failed: \(editorValue())") }
    try waitBackground(blue, name: "preset-preview")
    guard d.wait(for: { ((try? palettePixels("preset-palette-preview")) ?? 0) > 8 }, timeout: 10) else { throw Failure("ANSI palette did not reach live preview") }
    guard !FileManager.default.fileExists(atPath: themeURL.path), try String(contentsOfFile: configPath, encoding: .utf8) == initialConfig else {
        throw Failure("preview persisted an unsaved draft")
    }
    try button("ThemePresetCancelButton")
    guard d.wait(for: { d.element(withIdentifier: "ThemePresetEditor") == nil }, timeout: 5) else { throw Failure("cancel did not close editor") }
    try waitBackground(before, name: "preset-cancelled")
    guard try palettePixels("preset-palette-cancelled") == 0 else { throw Failure("Cancel left preview ANSI colors applied") }

    // Saving the full preset applies its own fonts/colors, replacing stale root overrides.
    try createDraft()
    try button("ThemePresetSaveButton")
    guard d.wait(for: { FileManager.default.fileExists(atPath: themeURL.path) && d.element(withIdentifier: "ThemePresetEditor") == nil }, timeout: 5) else {
        throw Failure("preset save failed: \(editorValue())")
    }
    let saved = try String(contentsOf: themeURL, encoding: .utf8)
    let appliedConfig = try String(contentsOfFile: configPath, encoding: .utf8)
    guard saved.contains("font-size = 21"), saved.contains("font-family = Monaco"), saved.contains("1=#fa1234"),
          appliedConfig.contains("theme = \(themeName)"), !appliedConfig.contains("font-size = 13"), !appliedConfig.contains("foreground = #ffffff") else {
        throw Failure("full preset did not own saved typography and palette")
    }
    guard let catalog = d.element(withIdentifier: "TerminalSettingsDialog"),
          ((d.attribute(catalog, kAXValueAttribute) as String?) ?? "").contains(themeName) else {
        throw Failure("saved preset was not selected in its catalog")
    }
    d.key(Key.escape)
    try waitBackground(blue, name: "preset-saved")
    guard d.wait(for: { ((try? palettePixels("preset-palette-saved")) ?? 0) > 8 }, timeout: 10) else { throw Failure("saved ANSI palette did not reach terminal pixels") }
    guard d.wait(for: {
        guard let glyphs = try? glyphBounds("preset-glyphs-saved") else { return false }
        return glyphs.width > originalGlyphs.width * 1.35 && glyphs.height > originalGlyphs.height * 1.2
    }, timeout: 10) else { throw Failure("saved font size did not reach rendered glyph metrics") }
    let afterSave = try processIdentity()
    guard afterSave == originalProcess else { throw Failure("theme editing replaced the live pane or process") }

    // Reopen after relaunch: name, all palette entries, font and size are still there.
    d.quit()
    try d.launch(config: appliedConfig)
    try waitBackground(blue, name: "preset-relaunched")
    d.key(Key.comma, .maskCommand)
    d.key(Key.three, .maskCommand)
    d.key(Key.slash)
    d.key(Key.a, .maskCommand)
    try d.type(themeName)
    d.key(14, .maskCommand)
    guard d.wait(for: { d.element(withIdentifier: "ThemePresetEditor") != nil }, timeout: 5),
          let nameField = d.textField(identifier: "ThemePresetName"),
          (d.attribute(nameField, kAXValueAttribute) as String?) == themeName else { throw Failure("saved theme did not reopen for editing") }
    let originalBytes = try Data(contentsOf: themeURL)

    // Existing theme survives invalid names and storage failure; draft stays editable.
    d.key(Key.a, .maskCommand)
    try d.type("../Invalid")
    try button("ThemePresetSaveButton")
    guard d.wait(for: { editorValue().hasPrefix("theme_save_error:") }, timeout: 5), try Data(contentsOf: themeURL) == originalBytes else {
        throw Failure("invalid name was not refused without changing the theme")
    }
    try button("ThemePresetCancelButton")
    try button("ThemePresetEditButton")
    guard d.wait(for: { d.element(withIdentifier: "ThemePresetEditor") != nil }, timeout: 5) else { throw Failure("theme did not reopen after cancelled invalid edit") }
    let themes = themeURL.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: themes.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: themes.path) }
    try button("ThemePresetSaveButton")
    guard d.wait(for: { editorValue().hasPrefix("theme_save_error:") }, timeout: 5), try Data(contentsOf: themeURL) == originalBytes else {
        throw Failure("failed write changed original preset or closed the draft")
    }
    try button("ThemePresetCancelButton")
    d.key(Key.escape)
}
