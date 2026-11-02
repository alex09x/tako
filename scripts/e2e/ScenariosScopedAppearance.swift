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
    let paneDialog = try openAppearance(text: "AppearanceWitness", menu: "Terminal Appearance…")
    d.key(23, .maskCommand) // Font Size
    guard d.wait(for: { value(paneDialog).contains("Font Size:") && value(paneDialog).contains("= 13") }, timeout: 5) else {
        throw Failure("pane did not inherit global size: \(value(paneDialog))")
    }
    d.key(Key.right)
    guard d.wait(for: { value(paneDialog).contains("setting_custom_success: font-size") }, timeout: 5) else {
        throw Failure("pane size did not save: \(value(paneDialog))")
    }
    // The save acknowledgement temporarily replaces the section description.
    // Return to the section to read its persisted effective size.
    d.key(Key.three, .maskCommand)
    d.key(23, .maskCommand)
    guard d.wait(for: { value(paneDialog).contains("= 14") }, timeout: 5) else {
        throw Failure("pane size did not read back: \(value(paneDialog))")
    }
    d.key(Key.one, .maskCommand)
    guard value(paneDialog).contains("14") else { throw Failure("scoped editor escaped into global settings") }
    d.key(Key.escape)
    _ = try d.exec("\(ctl) workspace create Unstyled")
    _ = try d.exec("\(ctl) workspace assign --workspace Unstyled --target \(pane)")
    _ = try d.exec("\(ctl) workspace switch Unstyled")
    guard d.wait(for: { guard let color = try? background("scoped-moved") else { return false }; return difference(initial, color) < 0.02 }, timeout: 10) else {
        throw Failure("moved pane retained its old workspace background")
    }
    d.quit()
    guard kill(process, 0) == 0 else { throw Failure("quitting the renderer killed its process") }
    try d.launch(config: config)
    _ = try d.exec("\(ctl) focus --target \(pane)")
    let restored = try openAppearance(text: "AppearanceWitness", menu: "Terminal Appearance…")
    d.key(23, .maskCommand)
    guard d.wait(for: { value(restored).contains("Font Size:") && value(restored).contains("= 14") }, timeout: 5) else {
        throw Failure("pane override did not survive restore: \(value(restored))")
    }
    d.key(Key.escape)
    _ = try d.exec("\(ctl) workspace assign --workspace Default --target \(pane)")
    _ = try d.exec("\(ctl) workspace switch Default")
    guard d.wait(for: { guard let color = try? background("scoped-restored-workspace") else { return false }; return difference(ocean, color) < 0.02 }, timeout: 10),
          kill(process, 0) == 0, (try? d.focusedPaneId()) == pane else {
        throw Failure("workspace style or original live session did not survive restore")
    }
    guard try String(contentsOfFile: d.path("config"), encoding: .utf8) == configBefore else { throw Failure("scoped editor changed global config") }
}
