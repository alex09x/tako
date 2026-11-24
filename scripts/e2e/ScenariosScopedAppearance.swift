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
    // «Appearance ▸» (1ecffe22) replaced the legacy «Workspace / Terminal
    // Appearance…» dialog: a workspace header offers the workspace level, the
    // terminal's own right-click menu the pane level, and «Customize…» opens
    // Settings › Terminal Appearance at that level with the shown theme in
    // its editor. Every click goes to a point Tako owns.
    func rightClick(_ point: CGPoint) throws {
        guard d.topmostOwner(at: point) == d.pid else { throw Failure("\(point) is not Tako's") }
        try d.requireAXOwnedTarget(at: point)
        CGEvent(mouseEventSource: d.source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: d.source, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: d.source, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
    }
    /// The workspace header's menu (sidebar text `text`), or the focused
    /// terminal's own menu when `text` is nil; then its «Appearance» submenu.
    func openAppearanceMenu(sidebarText text: String?) throws {
        if let text {
            try sidebar()
            guard let window = d.activeWindow(), let row = d.descendants(of: window, role: kAXStaticTextRole as String).first(where: {
                (d.attribute($0, kAXValueAttribute) as String?) == text
            }), let rect = d.axFrame(row) else { throw Failure("no sidebar row: \(text)") }
            try rightClick(CGPoint(x: rect.midX, y: rect.midY))
        } else {
            guard let rect = d.terminalFrame() else { throw Failure("no terminal to right-click") }
            try rightClick(CGPoint(x: rect.midX, y: rect.midY))
        }
        try openSubmenu("Appearance")
    }
    /// Opens the submenu item `title` of the open menu with a real HID click
    /// on its frame (Driver.clickOpenMenuItem: owner + AX target guarded, no
    /// AXPress). Each caller then requires the exact child it needs
    /// (clickOpenMenuItem, which lists every menu item when it is missing, or
    /// appearanceChecks): that child is the proof the submenu opened.
    func openSubmenu(_ title: String) throws {
        try d.clickOpenMenuItem(titled: title)
    }
    /// Whether the open Appearance submenu checks `name` (the level's own preset).
    func appearanceChecks(_ name: String) -> Bool {
        guard d.wait(for: { d.openMenuItem(titled: name) != nil }, timeout: 5), let item = d.openMenuItem(titled: name) else { return false }
        return ((d.attribute(item, "AXMenuItemMarkChar") as String?) ?? "").isEmpty == false
    }
    /// Escape to the open menu itself (HID), only while a menu is open, so no
    /// Escape reaches the terminal underneath.
    func dismissMenu() throws {
        for _ in 0..<3 where d.openMenuItem(titled: "Appearance") != nil {
            d.systemKey(Key.escape)
            usleep(200_000)
        }
        guard d.openMenuItem(titled: "Appearance") == nil else { throw Failure("the Appearance menu did not close") }
    }
    let page = SettingsPage(d)
    func closeSettings() throws {
        try page.click("DesktopSettingsClose")
        guard d.wait(for: { d.element(withIdentifier: "DesktopSettingsRoot") == nil }, timeout: 5) else {
            throw Failure("Close did not dismiss Settings")
        }
    }
    /// Settings › Terminal Appearance for the focused terminal (pane level),
    /// its shown theme open in the editor.
    func customizePane() throws {
        try openAppearanceMenu(sidebarText: nil)
        try d.clickOpenMenuItem(titled: "Customize…")
        guard d.wait(for: { page.exact("DesktopThemeName") != nil }, timeout: 5) else { throw Failure("the pane theme editor did not open") }
        page.placeWindow()
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
        try rightClick(point)
        guard d.wait(for: { d.openMenuItem(titled: "Move to Workspace") != nil }, timeout: 5) else { throw Failure("missing workspace move submenu") }
        try openSubmenu("Move to Workspace")
        try d.clickOpenMenuItem(titled: workspace)
    }
    func difference(_ a: NSColor, _ b: NSColor) -> CGFloat {
        abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
    }
    let initial = try background("scoped-before")
    let configBefore = try String(contentsOfFile: d.path("config"), encoding: .utf8)
    // The submenu offers the first six presets of the catalog (TakoCore, Ayu
    // Mirage, Dracula, …); Tako Ocean is chosen the way the product offers
    // every other one: «All Themes…» at the workspace level, then its card.
    try openAppearanceMenu(sidebarText: "DEFAULT")
    try d.clickOpenMenuItem(titled: "All Themes…")
    guard d.wait(for: { d.element(withIdentifier: "DesktopSettingsRoot") != nil }, timeout: 5) else {
        throw Failure("All Themes… did not open Settings")
    }
    page.placeWindow()
    try page.click("DesktopTheme-Tako Ocean")
    guard d.wait(for: { page.value("DesktopTheme-Tako Ocean") == "selected" }, timeout: 5) else {
        throw Failure("the workspace did not select Tako Ocean: [\(page.value("DesktopTheme-Tako Ocean"))]")
    }
    try closeSettings()
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
    // The pane level: the terminal's own menu › Appearance › Customize… opens
    // the inherited effective theme (Tako Ocean) in the editor as a copy.
    try customizePane()
    try page.enter("DesktopThemeName", "Scoped Session", submit: false)
    try page.click("DesktopThemeEditorSection-type")
    // DesktopStepper's field shows DesktopStepper.render(value) ("13", "13.5")
    // and draws its "pt" unit as a separate label, so the AX value is the
    // bare number: the whole value must parse and equal the size exactly.
    func fontSize() -> String { page.value("DesktopThemeField-font-size") }
    func fontSizeIs(_ size: Double) -> Bool {
        Double(fontSize().trimmingCharacters(in: .whitespaces)) == size
    }
    guard d.wait(for: { fontSizeIs(13) }, timeout: 5) else {
        throw Failure("pane theme did not start with its inherited size: [\(fontSize())]")
    }
    // The stepper moves 0.5 pt a step.
    try page.click("DesktopThemeField-font-size-increase")
    try page.click("DesktopThemeField-font-size-increase")
    guard d.wait(for: { fontSizeIs(14) }, timeout: 5) else {
        throw Failure("pane theme size did not change to 14: [\(fontSize())]")
    }
    try page.click("DesktopThemeSave")
    guard d.wait(for: { page.exact("DesktopThemeName") == nil }, timeout: 5) else {
        throw Failure("pane custom theme did not save: \(page.value("DesktopThemeError"))")
    }
    try closeSettings()
    // Selected at the pane level, and only there: the workspace keeps Ocean.
    try openAppearanceMenu(sidebarText: nil)
    guard appearanceChecks("Scoped Session") else { throw Failure("the pane level does not select Scoped Session") }
    try dismissMenu()
    try openAppearanceMenu(sidebarText: "DEFAULT")
    guard appearanceChecks("Tako Ocean"), !appearanceChecks("Scoped Session") else {
        throw Failure("the workspace level changed with the pane's theme")
    }
    try dismissMenu()
    _ = try d.exec("\(ctl) workspace assign --workspace Unstyled --target \(pane)")
    _ = try d.exec("\(ctl) workspace switch Unstyled")
    guard d.wait(for: { guard let color = try? background("scoped-moved") else { return false }; return difference(ocean, color) < 0.02 }, timeout: 10) else {
        throw Failure("moving a pane lost its explicit complete theme")
    }
    d.quit()
    guard kill(process, 0) == 0 else { throw Failure("quitting the renderer killed its process") }
    // The restored pane is the live session (its `sleep` runs in front), not
    // a fresh shell: no bootstrap is typed into it, as in the recovery journeys.
    try d.launch(config: config, settleTerminal: false)
    _ = try d.exec("\(ctl) focus --target \(pane)")
    try openAppearanceMenu(sidebarText: nil)
    guard appearanceChecks("Scoped Session") else { throw Failure("pane theme assignment did not survive restore") }
    try dismissMenu()
    try customizePane()
    try page.click("DesktopThemeEditorSection-type")
    guard d.wait(for: { fontSizeIs(14) }, timeout: 5) else {
        throw Failure("pane theme typography did not survive restore: [\(fontSize())]")
    }
    try page.click("DesktopThemeCancel")
    try closeSettings()
    _ = try d.exec("\(ctl) workspace assign --workspace Default --target \(pane)")
    _ = try d.exec("\(ctl) workspace switch Default")
    guard d.wait(for: { guard let color = try? background("scoped-restored-workspace") else { return false }; return difference(ocean, color) < 0.02 }, timeout: 10),
          kill(process, 0) == 0, (try? d.focusedPaneId()) == pane else {
        throw Failure("workspace style or original live session did not survive restore")
    }
    guard try String(contentsOfFile: d.path("config"), encoding: .utf8) == configBefore else { throw Failure("scoped editor changed global config") }
}
