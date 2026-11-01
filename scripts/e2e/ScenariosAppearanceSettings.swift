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
    let beforeChoice = try String(contentsOfFile: configPath, encoding: .utf8)
    guard !beforeChoice.contains("theme = ") else { throw Failure("highlighting a preset changed the config") }
    d.key(Key.returnKey)
    guard d.wait(for: { (try? String(contentsOfFile: configPath, encoding: .utf8).contains("theme = Tako Night")) == true }, timeout: 5) else {
        throw Failure("the chosen theme was not saved")
    }
    var after: NSColor?
    guard d.wait(for: {
        after = try? background("appearance-after.png")
        guard let after else { return false }
        return abs(after.redComponent - before.redComponent) + abs(after.greenComponent - before.greenComponent)
            + abs(after.blueComponent - before.blueComponent) > 0.03
    }, timeout: 10) else { throw Failure("the terminal did not apply the chosen theme") }

    let beforeFont = try screenshot("font-before.png")
    d.key(21, .maskCommand) // Cmd+4: Fonts
    guard d.wait(for: { value().contains("Fonts:") }, timeout: 5) else {
        throw Failure("font section did not show installed families: \(value())")
    }
    let initialFontDescription = value()
    d.key(Key.down)
    let familyDescription = value()
    guard familyDescription != initialFontDescription else { throw Failure("no installed font family to choose") }
    d.key(Key.returnKey)
    guard d.wait(for: { (try? String(contentsOfFile: configPath, encoding: .utf8).contains("font-family = ")) == true }, timeout: 5) else {
        throw Failure("selected font was not saved")
    }
    guard d.wait(for: { guard let image = try? screenshot("font-after.png") else { return false }; return image != beforeFont }, timeout: 10) else {
        throw Failure("the terminal did not redraw with the chosen font")
    }

    let beforeSize = try screenshot("size-before.png")
    d.key(23, .maskCommand) // Cmd+5: Font Size
    guard d.wait(for: { value().contains("Font Size:") && value().contains("Font size") }, timeout: 5) else {
        throw Failure("font size section missing: \(value())")
    }
    d.key(Key.right)
    guard d.wait(for: { (try? String(contentsOfFile: configPath, encoding: .utf8).contains("font-size = 14")) == true }, timeout: 5) else {
        throw Failure("font size did not increase")
    }
    guard d.wait(for: { guard let image = try? screenshot("size-after.png") else { return false }; return image != beforeSize }, timeout: 10) else {
        throw Failure("the terminal did not redraw at the new font size")
    }
    d.key(Key.escape)
}
