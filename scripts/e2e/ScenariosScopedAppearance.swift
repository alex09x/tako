/*
 * tako — Scoped appearance preserves live sessions
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

func runScopedAppearanceScenario(_ d: Driver) throws {
    d.quit()
    forgetLayout(d)
    let config = "session-persistence = true\nwindow-save-state = always\nremote-control = on\nauto-update = off\ncursor-style-blink = false\n"
    try d.launch(config: config)
    let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
    guard let pane = try d.focusedPaneId() else { throw Failure("missing test pane") }
    try d.run("sh -c 'printf \"\\033]0;AppearanceWitness\\007\"; echo $$ > \(d.path("appearance-pid")); exec sleep 600'")
    guard let process = Int32(try d.file("appearance-pid").trimmingCharacters(in: .whitespacesAndNewlines)), process > 0 else {
        throw Failure("test process did not start")
    }
    func sidebar() throws {
        if !d.hasText(containing: "Sessions") { d.key(Key.s, [.maskCommand, .maskAlternate]) }
        guard d.wait(for: { d.hasText(containing: "AppearanceWitness") }, timeout: 10) else { throw Failure("no sidebar witness") }
    }
    func openAppearance(text: String, menu: String) throws -> AXUIElement {
        try sidebar()
        guard let window = d.activeWindow(), let row = d.descendants(of: window, role: kAXStaticTextRole as String).first(where: {
            (d.attribute($0, kAXValueAttribute) as String?) == text
        }), let position: AXValue = d.attribute(row, kAXPositionAttribute),
           let extent: AXValue = d.attribute(row, kAXSizeAttribute) else { throw Failure("no sidebar row: \(text)") }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(position, .cgPoint, &point)
        AXValueGetValue(extent, .cgSize, &size)
        point.x += size.width / 2; point.y += size.height / 2
        CGEvent(mouseEventSource: d.source, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: d.source, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
        try d.clickOpenMenuItem(titled: menu)
        guard d.wait(for: { d.element(withIdentifier: "TerminalSettingsDialog") != nil }, timeout: 5),
              let dialog = d.element(withIdentifier: "TerminalSettingsDialog") else { throw Failure("appearance dialog did not open") }
        return dialog
    }
    func background(_ name: String) throws -> NSColor {
        let path = d.path(name + ".png")
        _ = try d.exec("\(ctl) screenshot --target \(pane) --out \(path)")
        guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path))),
              let color = bitmap.colorAt(x: bitmap.pixelsWide - 8, y: bitmap.pixelsHigh - 8)?.usingColorSpace(.sRGB) else {
            throw Failure("no screenshot color")
        }
        return color
    }
    func moveUsingSidebar(to workspace: String) throws {
        try sidebar()
        guard let window = d.activeWindow(), let row = d.descendants(of: window, role: kAXStaticTextRole as String).first(where: {
            (d.attribute($0, kAXValueAttribute) as String?) == "AppearanceWitness"
        }), let position: AXValue = d.attribute(row, kAXPositionAttribute), let extent: AXValue = d.attribute(row, kAXSizeAttribute) else {
            throw Failure("missing styled sidebar session")
        }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(position, .cgPoint, &point); AXValueGetValue(extent, .cgSize, &size)
        point.x += size.width / 2; point.y += size.height / 2
        CGEvent(mouseEventSource: d.source, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: d.source, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
        guard d.wait(for: { d.openMenuItem(titled: "Move to Workspace") != nil }, timeout: 5),
              let submenu = d.openMenuItem(titled: "Move to Workspace") else { throw Failure("missing workspace move submenu") }
        d.press(submenu)
        try d.clickOpenMenuItem(titled: workspace)
    }
    func difference(_ a: NSColor, _ b: NSColor) -> CGFloat {
        abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
    }
    let initial = try background("scoped-before")
    let configBefore = try String(contentsOfFile: d.path("config"), encoding: .utf8)
    let workspaceDialog = try openAppearance(text: "DEFAULT", menu: "Workspace Appearance…")
    func value(_ dialog: AXUIElement) -> String { (d.attribute(dialog, kAXValueAttribute) as String?) ?? "" }
    guard value(workspaceDialog).contains("Themes:") else { throw Failure("workspace themes missing") }
    // Inherit, TakoCore, Forest, Night, Ocean.
    for _ in 0..<4 { d.key(Key.down) }
    guard value(workspaceDialog).contains("Tako Ocean") else { throw Failure("workspace preset missing: \(value(workspaceDialog))") }
    d.key(Key.returnKey)
    d.key(Key.escape)
    guard d.wait(for: { guard let color = try? background("scoped-workspace") else { return false }; return difference(initial, color) > 0.03 }, timeout: 10) else {
        throw Failure("workspace theme did not reach the live renderer")
    }
    let ocean = try background("scoped-ocean")
    // A session styled by its source workspace must keep that custom
    // appearance even before it has any explicit pane preset of its own.
    _ = try d.exec("\(ctl) workspace create Unstyled")
    try moveUsingSidebar(to: "Unstyled")
    guard d.wait(for: { guard let color = try? background("scoped-inherited-moved") else { return false }; return difference(ocean, color) < 0.02 }, timeout: 10) else {
        throw Failure("moving the session discarded its source workspace's custom theme")
    }
    _ = try d.exec("\(ctl) workspace assign --workspace Default --target \(pane)")
    _ = try d.exec("\(ctl) workspace switch Default")
    let paneDialog = try openAppearance(text: "AppearanceWitness", menu: "Terminal Appearance…")
    d.key(14, .maskCommand) // Edit the inherited effective theme as a custom preset.
    guard d.wait(for: { d.element(withIdentifier: "ThemePresetEditor") != nil }, timeout: 5),
          let editor = d.element(withIdentifier: "ThemePresetEditor") else { throw Failure("pane theme editor missing") }
    d.key(Key.a, .maskCommand); try d.type("Scoped Session"); d.key(Key.returnKey)
    d.key(23, .maskCommand) // Font Size
    guard d.wait(for: { value(editor).contains("Font Size:") && value(editor).contains("= 13") }, timeout: 5) else {
        throw Failure("pane theme did not start with its inherited size: \(value(editor))")
    }
    d.key(Key.right)
    guard d.wait(for: { value(editor).contains("setting_custom_success: font-size") }, timeout: 5) else {
        throw Failure("pane theme size did not change: \(value(editor))")
    }
    // The save acknowledgement temporarily replaces the section description.
    // Return to the section to read its persisted effective size.
    d.key(Key.three, .maskCommand)
    d.key(23, .maskCommand)
    guard d.wait(for: { value(editor).contains("= 14") }, timeout: 5) else {
        throw Failure("pane theme size did not read back: \(value(editor))")
    }
    d.key(Key.one, .maskCommand)
    guard value(editor).contains("14") else { throw Failure("theme editor escaped into global settings") }
    guard let save = d.element(withIdentifier: "ThemePresetSaveButton") else { throw Failure("missing theme Save") }
    d.press(save)
    guard d.wait(for: { d.element(withIdentifier: "ThemePresetEditor") == nil }, timeout: 5),
          value(paneDialog).contains("Scoped Session") else { throw Failure("pane custom theme did not save") }
    d.key(Key.escape)
    _ = try d.exec("\(ctl) workspace assign --workspace Unstyled --target \(pane)")
    _ = try d.exec("\(ctl) workspace switch Unstyled")
    guard d.wait(for: { guard let color = try? background("scoped-moved") else { return false }; return difference(ocean, color) < 0.02 }, timeout: 10) else {
        throw Failure("moving a pane lost its explicit complete theme")
    }
    d.quit()
    guard kill(process, 0) == 0 else { throw Failure("quitting the renderer killed its process") }
    try d.launch(config: config)
    _ = try d.exec("\(ctl) focus --target \(pane)")
    let restored = try openAppearance(text: "AppearanceWitness", menu: "Terminal Appearance…")
    guard value(restored).contains("Scoped Session") else { throw Failure("pane theme assignment did not survive restore") }
    d.key(14, .maskCommand)
    guard d.wait(for: { d.element(withIdentifier: "ThemePresetEditor") != nil }, timeout: 5),
          let restoredEditor = d.element(withIdentifier: "ThemePresetEditor") else { throw Failure("restored theme editor missing") }
    d.key(23, .maskCommand)
    guard d.wait(for: { value(restoredEditor).contains("Font Size:") && value(restoredEditor).contains("= 14") }, timeout: 5) else {
        throw Failure("pane theme typography did not survive restore: \(value(restoredEditor))")
    }
    d.key(Key.escape)
    d.key(Key.escape)
    _ = try d.exec("\(ctl) workspace assign --workspace Default --target \(pane)")
    _ = try d.exec("\(ctl) workspace switch Default")
    guard d.wait(for: { guard let color = try? background("scoped-restored-workspace") else { return false }; return difference(ocean, color) < 0.02 }, timeout: 10),
          kill(process, 0) == 0, (try? d.focusedPaneId()) == pane else {
        throw Failure("workspace style or original live session did not survive restore")
    }
    guard try String(contentsOfFile: d.path("config"), encoding: .utf8) == configBefore else { throw Failure("scoped editor changed global config") }
}
