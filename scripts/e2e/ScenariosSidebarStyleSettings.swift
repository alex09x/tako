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

/// Settings › App Appearance › Sidebar by real clicks, end to end: every
/// style card, both groupings (and back), every text size and second-line
/// strength, and a reset; each is saved to the config file and is what the
/// running app reads. Grouped by status the sidebar shows its buckets and no
/// segments; back by workspace the segments return. A grouped row still
/// selects its session and the keyboard reaches its shell.
///
/// Private throughout: the shells get a private HOME, XDG dirs and history
/// (checked by the first command typed), sessions live in a private
/// namespace and are not kept, and the owner's shell history is checked
/// unchanged at the end. Only the owned Settings window is moved and raised;
/// the driver still refuses a click whose point another process owns.
func runSidebarStyleSettingsScenario(_ d: Driver) throws {
    d.quit()
    let saved = d.environment
    let home = d.path("private-home"), sessions = d.path("private-sessions")
    for dir in [home, home + "/.config", home + "/.local/share", home + "/.cache", sessions] {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    d.environment["HOME"] = home
    d.environment["XDG_CONFIG_HOME"] = home + "/.config"
    d.environment["XDG_DATA_HOME"] = home + "/.local/share"
    d.environment["XDG_CACHE_HOME"] = home + "/.cache"
    d.environment["HISTFILE"] = home + "/.shell_history"
    d.environment["TAKO_SESSIONS_HOME"] = sessions
    defer { d.environment = saved }

    let owner = NSHomeDirectory()
    let ownerHistory = [".local/share/fish/fish_history", ".bash_history", ".zsh_history"].map { owner + "/" + $0 }
    func stamp() -> [String] {
        ownerHistory.map { path in
            guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return "absent \(path)" }
            return "\(a[.size] ?? 0) \((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) \(path)"
        }
    }
    let historyBefore = stamp()
    defer {   // reported on every exit, a failed run included
        let after = stamp()
        print("owner history: \(after == historyBefore ? "unchanged" : "CHANGED before=\(historyBefore) after=\(after)")")
    }

    // No settle step: the first command typed is the boundary check.
    try d.launch(config: "window-save-state = never\nauto-update = off\nremote-control = on\nmacos-titlebar-style = tabs\n"
                 + "session-persistence = false\n", settleTerminal: false)
    print("fixture app: pid \(d.pid), bundle \(d.bundleID), \(d.appURL.path)")
    d.setPosition(CGPoint(x: 100, y: 410))
    d.setSize(CGSize(width: 1000, height: 560))
    d.focus()
    usleep(800_000)
    let ctl = "'\(d.appURL.path)/Contents/MacOS/takoctl' --bundle-id \(d.bundleID)"
    guard let pane0 = try d.focusedPaneId() else { throw Failure("no first pane") }
    try d.run("echo \"$HOME|$XDG_DATA_HOME|$HISTFILE\" > \(d.path("sbstyle_env"))")
    let seen = try d.file("sbstyle_env").trimmingCharacters(in: .whitespacesAndNewlines)
    guard seen == "\(home)|\(home)/.local/share|\(home)/.shell_history" else { throw Failure("the shell is not private: \(seen)") }

    let alpha = d.path("sbstyle_alpha"), beta = d.path("sbstyle_beta")
    try FileManager.default.createDirectory(atPath: alpha, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: beta, withIntermediateDirectories: true)
    try d.run("cd \(alpha)")
    d.key(Key.t, .maskCommand)
    guard d.wait(for: { d.tabElement(index: 1) != nil }, timeout: 5) else { throw Failure("second tab did not open") }
    usleep(600_000)
    try d.run("cd \(beta)")
    let tree = try d.exec("\(ctl) --json tree")
    var persistent: [Bool] = []
    func collect(_ node: Any) {
        if let dict = node as? [String: Any] {
            if let flag = dict["persistentSession"] as? Bool { persistent.append(flag) }
            dict.values.forEach(collect)
        } else if let list = node as? [Any] { list.forEach(collect) }
    }
    collect(try JSONSerialization.jsonObject(with: Data(tree.utf8)))
    print("fixture panes: \(persistent.count), persistentSession: \(persistent)")
    guard persistent.count >= 2, !persistent.contains(true) else {
        throw Failure("fixture panes must be ≥2 and all non-persistent, got \(persistent): \(tree.prefix(400))")
    }

    // Settings, the owned window, inside the display's visible frame and raised.
    d.key(Key.comma, .maskCommand)
    guard d.wait(for: { d.element(withIdentifier: "DesktopSettingsRoot") != nil }, timeout: 5) else { throw Failure("Settings did not open") }
    if let root = d.element(withIdentifier: "DesktopSettingsRoot"), let window: AXUIElement = d.attribute(root, kAXWindowAttribute),
       let screen = NSScreen.main, let sizeVal: AXValue = d.attribute(window, kAXSizeAttribute) {
        var size = CGSize.zero
        AXValueGetValue(sizeVal, .cgSize, &size)
        let visible = screen.visibleFrame, top = screen.frame.maxY     // AX y runs down from the main display's top
        var origin = CGPoint(x: visible.minX + 20, y: max(top - visible.maxY, top - visible.minY - size.height - 20))
        if let value = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        usleep(400_000)
    }
    func frame(_ e: AXUIElement) -> CGRect? {
        guard let p: AXValue = d.attribute(e, kAXPositionAttribute), let s: AXValue = d.attribute(e, kAXSizeAttribute) else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p, .cgPoint, &pos); AXValueGetValue(s, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }
    /// Where a control sits against the clickable part of the page: above
    /// it, below it (under the footer included), or inside it.
    func placement(_ id: String) throws -> (below: Bool, above: Bool, page: CGRect, floor: CGFloat) {
        guard let e = d.element(withIdentifier: id), let rect = frame(e),
              let pageEl = d.element(withIdentifier: "DesktopSettingsPage"), let page = frame(pageEl) else {
            throw Failure("no frame for \(id) or the settings page")
        }
        let floor = min(page.maxY, d.element(withIdentifier: "DesktopSettingsFooter").flatMap(frame)?.minY ?? page.maxY)
        return (rect.maxY > floor - 4, rect.minY < page.minY + 4, page, floor)
    }
    /// Scrolls the settings page with the wheel, as a person would, until the
    /// control sits clear of the footer and inside the page. Every wheel event
    /// goes to a point inside the page above the footer that Tako owns, both
    /// by the window list and by the actual AX recipient; otherwise it fails
    /// without posting. A control still outside the page afterwards fails too.
    func bringIntoView(_ id: String) throws {
        for _ in 0..<12 {
            let at = try placement(id)
            guard at.below || at.above else { return }
            let point = CGPoint(x: at.page.minX + at.page.width * 0.3, y: max(at.page.minY + 10, at.floor - 30))
            guard let owner = d.topmostOwner(at: point), owner == d.pid else {
                throw Failure("scroll point \(point) not owned by Tako (owner \(String(describing: d.topmostOwner(at: point))), pid \(d.pid))")
            }
            try d.requireAXOwnedTarget(at: point)
            CGEvent(mouseEventSource: d.source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            try d.requireAXOwnedTarget(at: point)
            let wheel = CGEvent(scrollWheelEvent2Source: d.source, units: .line, wheelCount: 1,
                                wheel1: at.below ? -4 : 4, wheel2: 0, wheel3: 0)
            wheel?.location = point
            wheel?.post(tap: .cghidEventTap)
            usleep(250_000)
        }
        let at = try placement(id)
        if at.below || at.above { throw Failure("\(id) is still outside the clickable page after scrolling (below \(at.below), above \(at.above))") }
    }
    func element(_ id: String) throws -> AXUIElement {
        guard d.wait(for: { d.element(withIdentifier: id) != nil }, timeout: 5), let e = d.element(withIdentifier: id) else {
            throw Failure("no control \(id)")
        }
        AXUIElementPerformAction(e, "AXScrollToVisible" as CFString)
        usleep(300_000)
        try bringIntoView(id)
        return d.element(withIdentifier: id) ?? e
    }
    func click(_ id: String) throws {   // the driver refuses foreign-owned points
        do { try d.clickElement(try element(id)); print("control \(id): clicked") }
        catch { print("control \(id): FAILED \(error)"); throw error }
    }
    let config = d.path("config")
    func file() -> String { (try? String(contentsOfFile: config, encoding: .utf8)) ?? "" }
    func applied(_ key: String) -> String { ((try? d.exec("\(ctl) config get \(key)")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    func choose(_ key: String, _ value: String, id: String) throws {
        try click(id)
        guard d.wait(for: { file().contains("\(key) = \(value)") && applied(key).hasSuffix(value) }, timeout: 5)
            || (value == "default" || value == "classic" || value == "workspace")
            && d.wait(for: { applied(key).contains(value) }, timeout: 5) else {
            throw Failure("clicking \(id) did not make \(key) \(value); config get: \(applied(key)); file: \(file())")
        }
    }

    try click("DesktopSettingsSection-interface")
    for style in ["compact", "classic", "minimal"] {
        try choose("sidebar-style", style, id: "DesktopSetting-sidebar-style-\(style)")
    }
    try choose("sidebar-group", "status", id: "DesktopSetting-sidebar-group-status")
    guard d.wait(for: { d.element(withIdentifier: "SidebarStatusBucket-quiet") != nil
                        && d.element(withIdentifier: "SessionSidebarSegmentAll") == nil }, timeout: 5) else {
        throw Failure("grouped by status: no buckets, or the segments are still shown")
    }
    try choose("sidebar-group", "workspace", id: "DesktopSetting-sidebar-group-workspace")
    try choose("sidebar-style", "classic", id: "DesktopSetting-sidebar-style-classic")
    guard d.wait(for: { d.element(withIdentifier: "SessionSidebarSegmentAll") != nil }, timeout: 5) else {
        throw Failure("back by workspace in Classic, the segments did not return")
    }
    for size in ["small", "large", "default"] {
        try choose("sidebar-text-size", size, id: "DesktopSetting-sidebar-text-size-\(size)")
    }
    for strength in ["soft", "strong"] {
        try choose("sidebar-secondary-text", strength, id: "DesktopSetting-sidebar-secondary-text-\(strength)")
    }
    try click("DesktopSettingReset-sidebar-secondary-text")
    guard d.wait(for: { !file().contains("sidebar-secondary-text") && applied("sidebar-secondary-text").contains("default") }, timeout: 5) else {
        throw Failure("Restore Default did not reset sidebar-secondary-text: \(applied("sidebar-secondary-text"))")
    }
    try choose("sidebar-style", "minimal", id: "DesktopSetting-sidebar-style-minimal")
    try choose("sidebar-group", "status", id: "DesktopSetting-sidebar-group-status")
    try click("DesktopSettingsClose")
    guard d.wait(for: { d.element(withIdentifier: "DesktopSettingsRoot") == nil }, timeout: 5) else { throw Failure("Settings did not close") }

    // A grouped row still selects its session, and the keyboard reaches its shell.
    guard d.wait(for: { d.element(withIdentifier: "SidebarStatusBucket-quiet") != nil }, timeout: 5),
          let win = d.activeWindow(), let alphaRow = d.descendants(of: win, role: kAXStaticTextRole as String).first(where: {
              (d.attribute($0, kAXValueAttribute) as String?)?.contains("sbstyle_alpha") == true
          }) else { throw Failure("no grouped sidebar row for sbstyle_alpha") }
    try d.clickElement(alphaRow)
    guard d.wait(for: { (try? d.focusedPaneId()) == pane0 }, timeout: 5) else {
        throw Failure("clicking the sbstyle_alpha row did not select its session")
    }
    try d.run("echo sidebar_style_ok > \(d.path("sbstyle_witness"))")
    try d.expect("sbstyle_witness", "sidebar_style_ok\n", "keyboard input after selecting a row grouped by status")
    guard stamp() == historyBefore else { throw Failure("the owner's shell history changed: \(stamp())") }
}
