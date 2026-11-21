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
    // Cmd+, opens the native Settings panel; its Appearance page lists the
    // bundled presets and applies a chosen one to the global config at once.
    d.key(Key.comma, .maskCommand)
    guard d.wait(for: { d.element(withIdentifier: "DesktopSettingsRoot") != nil }, timeout: 5) else { throw Failure("settings did not open") }
    let page = SettingsPage(d)
    page.placeWindow()
    try page.click("DesktopSettingsSection-appearance")
    guard d.wait(for: { d.element(withIdentifier: "DesktopTheme-TakoCore") != nil }, timeout: 5) else {
        throw Failure("the Appearance page did not list the bundled presets")
    }
    try page.enter("DesktopThemeFilter", "Tako Night", submit: false)
    try page.click("DesktopTheme-Tako Night")
    guard d.wait(for: { page.value("DesktopTheme-Tako Night") == "selected" }, timeout: 5) else { throw Failure("Tako Night was not selected") }
    let configPath = d.path("config")
    guard d.wait(for: { (try? String(contentsOfFile: configPath, encoding: .utf8).contains("theme = Tako Night")) == true }, timeout: 5) else {
        throw Failure("choosing the theme did not immediately apply it")
    }
    var after: NSColor?
    guard d.wait(for: {
        after = try? background("appearance-after.png")
        guard let after else { return false }
        return abs(after.redComponent - before.redComponent) + abs(after.greenComponent - before.greenComponent)
            + abs(after.blueComponent - before.blueComponent) > 0.03
    }, timeout: 10) else { throw Failure("the terminal did not apply the chosen theme") }

    let beforeFont = try screenshot("font-before.png")
    // Edit this theme, not separate global font settings: a bundled theme
    // opens as an editable «Tako Night Copy» draft.
    try page.click("DesktopThemeDuplicate")
    guard d.wait(for: { page.value("DesktopThemeName") == "Tako Night Copy" }, timeout: 5) else {
        throw Failure("theme editor did not open on a Tako Night copy: \(page.value("DesktopThemeName").debugDescription)")
    }
    func draftText() throws -> String {
        try page.click("DesktopThemeEditorSection-config")
        return page.value("DesktopThemeConfiguration")
    }
    try page.click("DesktopThemeEditorSection-type")
    try page.choose(menu: "DesktopThemeField-font-family", typing: "Monaco")
    guard d.wait(for: { (try? draftText())?.contains("font-family = Monaco") == true }, timeout: 5) else {
        throw Failure("font was not edited inside the theme")
    }
    try page.click("DesktopThemeEditorSection-type")
    for _ in 0..<2 { try page.click("DesktopThemeField-font-size-increase") } // 13 → 14 in 0.5 pt steps
    guard d.wait(for: { (try? draftText())?.contains("font-size = 14") == true }, timeout: 5) else {
        throw Failure("theme font size did not increase")
    }
    try page.click("DesktopThemeSave")
    guard d.wait(for: { d.element(withIdentifier: "DesktopThemeName") == nil }, timeout: 5) else { throw Failure("theme did not save") }
    let saved = try String(contentsOf: d.work.appendingPathComponent("themes/Tako Night Copy"), encoding: .utf8)
    let selected = try String(contentsOfFile: configPath, encoding: .utf8)
    guard saved.contains("font-family = Monaco"), saved.contains("font-size = 14"),
          selected.contains("theme = Tako Night Copy"), !selected.contains("font-family =") else {
        throw Failure("font and size did not belong to the saved theme")
    }
    d.key(Key.escape)
    guard d.wait(for: { d.element(withIdentifier: "DesktopSettingsRoot") == nil }, timeout: 5) else { throw Failure("Escape did not close Settings") }
    guard d.wait(for: { guard let image = try? screenshot("font-after.png") else { return false }; return image != beforeFont }, timeout: 10) else {
        throw Failure("the saved theme did not redraw terminal typography")
    }
}
