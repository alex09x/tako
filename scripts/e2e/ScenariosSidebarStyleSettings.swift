/*
 * tako — Sidebar style settings end-to-end check
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

/// Settings › App Appearance › Sidebar by real clicks: the Minimal preview
/// card, Status grouping, Large text and a Strong second line are saved to
/// the config file and are what the running app reads; grouped by status the
/// sidebar shows its buckets without the All / Needs you segments, and a
/// session's row still selects that session.
func runSidebarStyleSettingsScenario(_ d: Driver) throws {
    d.quit()
    // The shells this app starts get a private HOME, XDG dirs and history:
    // nothing of the owner's is read, and no command lands in their history.
    let saved = d.environment
    let home = d.path("private-home")
    for dir in ["", "/.config", "/.local/share", "/.cache"] {
        try FileManager.default.createDirectory(atPath: home + dir, withIntermediateDirectories: true)
    }
    d.environment["HOME"] = home
    d.environment["XDG_CONFIG_HOME"] = home + "/.config"
    d.environment["XDG_DATA_HOME"] = home + "/.local/share"
    d.environment["XDG_CACHE_HOME"] = home + "/.cache"
    d.environment["HISTFILE"] = home + "/.shell_history"
    defer { d.environment = saved }
    try d.launch(config: "window-save-state = never\nauto-update = off\nremote-control = on\nmacos-titlebar-style = tabs\n")
    // Below the top of the screen, where a system alert can stand.
    d.setPosition(CGPoint(x: 100, y: 410))
    d.setSize(CGSize(width: 1000, height: 560))
    d.focus()
    usleep(800_000)
    let ctl = "'\(d.appURL.path)/Contents/MacOS/takoctl' --bundle-id \(d.bundleID)"
    let alpha = d.path("sbstyle_alpha"), beta = d.path("sbstyle_beta")
    try FileManager.default.createDirectory(atPath: alpha, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: beta, withIntermediateDirectories: true)
    guard let pane0 = try d.focusedPaneId() else { throw Failure("no first pane") }
    // The boundary itself, checked before anything else is typed.
    try d.run("echo \"$HOME|$XDG_DATA_HOME|$HISTFILE\" > \(d.path("sbstyle_env"))")
    let seen = try d.file("sbstyle_env").trimmingCharacters(in: .whitespacesAndNewlines)
    guard seen == "\(home)|\(home)/.local/share|\(home)/.shell_history" else {
        throw Failure("the shell is not private: \(seen)")
    }
    try d.run("cd \(alpha)")
    d.key(Key.t, .maskCommand)
    guard d.wait(for: { d.tabElement(index: 1) != nil }, timeout: 5) else { throw Failure("second tab did not open") }
    usleep(600_000)
    try d.run("cd \(beta)")

    d.key(Key.comma, .maskCommand)
    guard d.wait(for: { d.element(withIdentifier: "DesktopSettingsRoot") != nil }, timeout: 5) else {
        throw Failure("Settings did not open")
    }
    func click(_ id: String) throws {
        guard d.wait(for: { d.element(withIdentifier: id) != nil }, timeout: 5), let e = d.element(withIdentifier: id) else {
            throw Failure("no control \(id)")
        }
        // The Sidebar block is at the foot of the page: bring it into view first.
        AXUIElementPerformAction(e, "AXScrollToVisible" as CFString)
        usleep(400_000)
        try d.clickElement(d.element(withIdentifier: id) ?? e)
    }
    let config = d.path("config")
    func saved(_ line: String) -> Bool { (try? String(contentsOfFile: config, encoding: .utf8).contains(line)) == true }
    func applied(_ key: String, _ value: String) -> Bool {
        ((try? d.exec("\(ctl) config get \(key)")) ?? "").contains(value)
    }
    // Settings is a window of its own, centred: move it, inside the display's
    // visible frame, to its lower part (a system alert can stand at the top),
    // and raise it. Only the owned Settings window is moved; the driver still
    // refuses any click whose point another process owns.
    if let root = d.element(withIdentifier: "DesktopSettingsRoot"), let window: AXUIElement = d.attribute(root, kAXWindowAttribute),
       let screen = NSScreen.main, let sizeVal: AXValue = d.attribute(window, kAXSizeAttribute) {
        var size = CGSize.zero
        AXValueGetValue(sizeVal, .cgSize, &size)
        let visible = screen.visibleFrame, top = screen.frame.maxY   // AX origin is the top-left of the main display
        var origin = CGPoint(x: visible.minX + 20, y: max(top - visible.maxY, top - visible.minY - size.height - 20))
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        usleep(400_000)
    }
    try click("DesktopSettingsSection-interface")
    // The Sidebar block is the page's last: wheel the page to its foot, as a
    // person would, so no control sits under the footer.
    if let page = d.element(withIdentifier: "DesktopSettingsPage"),
       let posVal: AXValue = d.attribute(page, kAXPositionAttribute), let sizeVal: AXValue = d.attribute(page, kAXSizeAttribute) {
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posVal, .cgPoint, &pos); AXValueGetValue(sizeVal, .cgSize, &size)
        // Low on the page: a system alert can sit over its middle.
        let point = CGPoint(x: pos.x + size.width * 0.3, y: pos.y + size.height * 0.85)
        CGEvent(mouseEventSource: d.source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        for _ in 0..<8 {
            let wheel = CGEvent(scrollWheelEvent2Source: d.source, units: .line, wheelCount: 1, wheel1: -10, wheel2: 0, wheel3: 0)
            wheel?.location = point
            wheel?.post(tap: .cghidEventTap)
            usleep(100_000)
        }
        usleep(300_000)
    }
    for (id, key, value) in [("DesktopSetting-sidebar-style-minimal", "sidebar-style", "minimal"),
                             ("DesktopSetting-sidebar-group-status", "sidebar-group", "status"),
                             ("DesktopSetting-sidebar-text-size-large", "sidebar-text-size", "large"),
                             ("DesktopSetting-sidebar-secondary-text-strong", "sidebar-secondary-text", "strong")] {
        try click(id)
        guard d.wait(for: { saved("\(key) = \(value)") && applied(key, value) }, timeout: 5) else {
            let file = (try? String(contentsOfFile: config, encoding: .utf8)) ?? "(unreadable)"
            let got = (try? d.exec("\(ctl) config get \(key)")) ?? "(no answer)"
            throw Failure("clicking \(id) did not save \(key) = \(value); config get: \(got); file: \(file)")
        }
    }
    try click("DesktopSettingsClose")
    guard d.wait(for: { d.element(withIdentifier: "DesktopSettingsRoot") == nil }, timeout: 5) else {
        throw Failure("Settings did not close")
    }

    // Grouped by status: the buckets, no All / Needs you segments.
    guard d.wait(for: { d.element(withIdentifier: "SidebarStatusBucket-quiet") != nil }, timeout: 5) else {
        throw Failure("the sidebar did not group by status")
    }
    guard d.element(withIdentifier: "SessionSidebarSegmentAll") == nil else {
        throw Failure("the All / Needs you segments are still shown while grouped by status")
    }

    // A row still selects its session.
    guard let win = d.activeWindow(), let alphaRow = d.descendants(of: win, role: kAXStaticTextRole as String).first(where: {
        (d.attribute($0, kAXValueAttribute) as String?)?.contains("sbstyle_alpha") == true
    }) else { throw Failure("no sidebar row for sbstyle_alpha") }
    try d.clickElement(alphaRow)
    guard d.wait(for: { (try? d.focusedPaneId()) == pane0 }, timeout: 5) else {
        throw Failure("clicking the sbstyle_alpha row did not select its session")
    }
    try d.run("echo sidebar_style_ok > \(d.path("sbstyle_witness"))")
    try d.expect("sbstyle_witness", "sidebar_style_ok\n", "keyboard input after selecting a row grouped by status")
}
