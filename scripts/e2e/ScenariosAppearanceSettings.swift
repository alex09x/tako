/*
 * tako — Terminal appearance settings end-to-end checks
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

func runAppearanceSettingsScenario(_ d: Driver) throws {
    d.quit()
    try d.launch(config: "window-save-state = never\nauto-update = off\nremote-control = on\ncursor-style-blink = false\n")
    let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
    func screenshot(_ filename: String) throws -> Data {
        let path = d.path(filename)
        _ = try d.exec("\(ctl) screenshot --out \(path)")
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }
    func background(_ filename: String) throws -> NSColor {
        guard let bitmap = NSBitmapImageRep(data: try screenshot(filename)),
              let color = bitmap.colorAt(x: bitmap.pixelsWide - 8, y: bitmap.pixelsHigh - 8)?.usingColorSpace(NSColorSpace.sRGB) else {
            throw Failure("could not read terminal screenshot")
        }
        return color
    }
    let before = try background("appearance-before.png")
    d.key(Key.comma, .maskCommand)
    guard d.wait(for: { d.element(withIdentifier: "TerminalSettingsDialog") != nil }, timeout: 5),
          let dialog = d.element(withIdentifier: "TerminalSettingsDialog") else { throw Failure("settings did not open") }
    func value() -> String { (d.attribute(dialog, kAXValueAttribute) as String?) ?? "" }
    d.key(Key.three, .maskCommand)
    guard d.wait(for: { value().contains("Themes:") && value().contains("TakoCore") }, timeout: 5) else {
        throw Failure("themes section did not list the bundled presets: \(value())")
    }
    d.key(Key.down)
    d.key(Key.down)
    guard d.wait(for: { value().contains("Tako Night") }, timeout: 5) else { throw Failure("Tako Night not found: \(value())") }
    let configPath = d.path("config")
    guard d.wait(for: { (try? String(contentsOfFile: configPath, encoding: .utf8).contains("theme = Tako Night")) == true }, timeout: 5) else {
        throw Failure("keyboard selection did not immediately apply the theme")
    }
    var after: NSColor?
    guard d.wait(for: {
        after = try? background("appearance-after.png")
        guard let after else { return false }
        return abs(after.redComponent - before.redComponent) + abs(after.greenComponent - before.greenComponent)
            + abs(after.blueComponent - before.blueComponent) > 0.03
    }, timeout: 10) else { throw Failure("the terminal did not apply the chosen theme") }

    let beforeFont = try screenshot("font-before.png")
    d.key(14, .maskCommand) // Edit this theme, not separate global font settings.
    guard d.wait(for: { d.element(withIdentifier: "ThemePresetEditor") != nil }, timeout: 5),
          let editor = d.element(withIdentifier: "ThemePresetEditor") else { throw Failure("theme editor did not open") }
    func editorValue() -> String { (d.attribute(editor, kAXValueAttribute) as String?) ?? "" }
    d.key(21, .maskCommand)
    d.key(Key.slash); try d.type("Monaco"); d.key(Key.returnKey)
    guard d.wait(for: { editorValue().contains("font-family = Monaco") }, timeout: 5) else {
        throw Failure("font was not edited inside the theme")
    }
    d.key(Key.slash); d.key(Key.a, .maskCommand); d.key(51); d.key(Key.down)
    d.key(23, .maskCommand)
    d.key(Key.right)
    guard d.wait(for: { editorValue().contains("setting_custom_success: font-size") }, timeout: 5) else {
        throw Failure("theme font size did not increase")
    }
    guard let save = d.element(withIdentifier: "ThemePresetSaveButton") else { throw Failure("missing theme Save") }
    d.press(save)
    guard d.wait(for: { d.element(withIdentifier: "ThemePresetEditor") == nil }, timeout: 5) else { throw Failure("theme did not save") }
    let saved = try String(contentsOf: d.work.appendingPathComponent("themes/Tako Night Copy"), encoding: .utf8)
    let selected = try String(contentsOfFile: configPath, encoding: .utf8)
    guard saved.contains("font-family = Monaco"), saved.contains("font-size = 14"),
          selected.contains("theme = Tako Night Copy"), !selected.contains("font-family =") else {
        throw Failure("font and size did not belong to the saved theme")
    }
    d.key(Key.escape)
    guard d.wait(for: { guard let image = try? screenshot("font-after.png") else { return false }; return image != beforeFont }, timeout: 10) else {
        throw Failure("the saved theme did not redraw terminal typography")
    }
}
