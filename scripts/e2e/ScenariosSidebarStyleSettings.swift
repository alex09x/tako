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
    try d.launch(config: "window-save-state = never\nauto-update = off\nremote-control = on\nmacos-titlebar-style = tabs\n")
    d.setPosition(CGPoint(x: 100, y: 100))
    d.setSize(CGSize(width: 900, height: 600))
    d.focus()
    usleep(800_000)
    let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
    let alpha = d.path("sbstyle_alpha"), beta = d.path("sbstyle_beta")
    try FileManager.default.createDirectory(atPath: alpha, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: beta, withIntermediateDirectories: true)
    guard let pane0 = try d.focusedPaneId() else { throw Failure("no first pane") }
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
        try d.clickElement(e)
    }
    let config = d.path("config")
    func saved(_ line: String) -> Bool { (try? String(contentsOfFile: config, encoding: .utf8).contains(line)) == true }
    func applied(_ key: String, _ value: String) -> Bool {
        ((try? d.exec("\(ctl) config get \(key)")) ?? "").contains(value)
    }
    try click("DesktopSettingsSection-interface")
    for (id, key, value) in [("DesktopSetting-sidebar-style-minimal", "sidebar-style", "minimal"),
                             ("DesktopSetting-sidebar-group-status", "sidebar-group", "status"),
                             ("DesktopSetting-sidebar-text-size-large", "sidebar-text-size", "large"),
                             ("DesktopSetting-sidebar-secondary-text-strong", "sidebar-secondary-text", "strong")] {
        try click(id)
        guard d.wait(for: { saved("\(key) = \(value)") && applied(key, value) }, timeout: 5) else {
            throw Failure("clicking \(id) did not save \(key) = \(value)")
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
