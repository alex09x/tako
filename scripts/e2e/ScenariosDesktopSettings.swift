/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

// The settings, shortcut and sidebar scenarios on today's routes: Cmd+,
// opens the desktop Settings (AppDelegate.showSettings), whose Keys page
// records shortcuts; the session sidebar is permanent. Every runtime proof
// the old in-terminal-dialog versions made is kept: a recorded chord runs its
// action, a reassigned chord runs the new one and not the old, nothing typed
// while Settings is open reaches the shell, and real typing reaches it after.

import AppKit
import ApplicationServices
import Foundation

/// The desktop Settings Keys page, by real clicks and keys.
struct DesktopKeys {
    let d: Driver
    var config: String { (try? String(contentsOfFile: d.path("config"), encoding: .utf8)) ?? "" }

    /// The element whose identifier is exactly `id` (Driver.element also
    /// matches identifiers that merely contain it, and every row's Record
    /// button contains "DesktopShortcutRecord").
    func exact(_ id: String) -> AXUIElement? {
        func walk(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
            if (d.attribute(e, "AXIdentifier") as String?) == id { return e }
            guard depth > 0 else { return nil }
            for child in (d.attribute(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                if let hit = walk(child, depth - 1) { return hit }
            }
            return nil
        }
        return d.windows().lazy.compactMap { walk($0, 30) }.first
    }

    var isOpen: Bool { exact("DesktopSettingsRoot") != nil }

    func open() throws {
        d.key(Key.comma, .maskCommand)
        guard d.wait(for: { isOpen }, timeout: 5) else { throw Failure("Cmd+, did not open Settings (no DesktopSettingsRoot)") }
        SettingsPage(d).placeWindow()
    }

    func click(_ id: String) throws {
        guard d.wait(for: { exact(id) != nil }, timeout: 5), let e = exact(id) else { throw Failure("no control \(id)") }
        AXUIElementPerformAction(e, "AXScrollToVisible" as CFString)
        usleep(300_000)
        try d.clickElement(exact(id) ?? e)
        usleep(300_000)
    }

    /// The Keys page, filtered by real typing to the one action.
    func show(_ action: String) throws {
        try click("DesktopSettingsSection-keys")
        try click("DesktopShortcutFilter")
        d.key(Key.a, .maskCommand)
        try d.type(action)
        guard d.wait(for: { exact("DesktopShortcut-\(action)") != nil }, timeout: 5) else {
            throw Failure("the Keys filter did not show \(action)")
        }
    }

    /// Clicks the action's shortcut, which selects it and starts recording.
    func record(_ action: String) throws {
        try click("DesktopShortcutRecord-\(action)")
        guard d.wait(for: { (exact("DesktopShortcutRecord").flatMap { d.attribute($0, "AXLabel") as String? }
                              ?? exact("DesktopShortcutRecord").flatMap { d.attribute($0, kAXDescriptionAttribute) as String? })
                              == "Recording Shortcut" }, timeout: 5) else {
            throw Failure("\(action) did not start recording")
        }
    }

    func close() throws {
        try click("DesktopSettingsClose")
        guard d.wait(for: { !isOpen }, timeout: 5) else { throw Failure("Close did not dismiss Settings") }
    }

    func binds(_ action: String) -> Bool { config.contains("=\(action)") }
}

extension Driver {
    /// The tty of the focused pane, written by the shell itself.
    func tty(_ name: String) throws -> String {
        try run("tty > \(path(name))")
        return try file(name).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func hasSplit(_ ctl: String) throws -> Bool { try exec("\(ctl) tree --json").contains("\"split\"") }
}

func runDesktopSettingsOpenCloseScenario(_ d: Driver) throws {
    let keys = DesktopKeys(d: d)
    try keys.open()
    d.key(Key.escape)
    guard d.wait(for: { !keys.isOpen }, timeout: 5) else { throw Failure("Escape did not dismiss Settings") }
    try d.run("echo 'settings_ok' > \(d.path("settings_witness"))")
    try d.expect("settings_witness", "settings_ok\n", "terminal keyboard input after Settings closed")
}

func runDesktopSettingsRecordScenario(_ d: Driver) throws {
    let keys = DesktopKeys(d: d)
    let before = keys.config
    try keys.open()
    try keys.show("new_tab")
    // Esc while recording cancels it and leaves Settings open, unchanged.
    try keys.record("new_tab")
    d.key(Key.escape)
    guard d.wait(for: { keys.isOpen && keys.exact("DesktopShortcutConflict") == nil }, timeout: 5), keys.config == before else {
        throw Failure("first Escape did not cancel recording while leaving Settings open and the config unchanged")
    }
    // Record Cmd+Opt+Ctrl+K on New Tab.
    try keys.record("new_tab")
    d.key(Key.k, [.maskCommand, .maskAlternate, .maskControl])
    guard d.wait(for: { keys.binds("new_tab") }, timeout: 5) else { throw Failure("the recorded shortcut was not saved: \(keys.config)") }
    try keys.close()

    // The recorded chord runs its action: a new tab with its own tty.
    let first = try d.tty("rec_tty1")
    d.key(Key.k, [.maskCommand, .maskAlternate, .maskControl])
    usleep(1_200_000)
    guard try d.tty("rec_tty2") != first else { throw Failure("Cmd+Opt+Ctrl+K did not open a new tab with its own tty") }
    // Closing it gives the keyboard back to the first tab.
    try d.run("exit")
    usleep(1_200_000)
    guard (try? d.tty("rec_tty3")) == first else { throw Failure("focus did not return to the first tab after the new one exited") }

    // Restore the default with ↺; the chord does nothing, Cmd+T opens a tab.
    try keys.open()
    try keys.show("new_tab")
    try keys.click("DesktopShortcutReset-new_tab")
    guard d.wait(for: { !keys.binds("new_tab") }, timeout: 5) else { throw Failure("↺ did not restore New Tab's default: \(keys.config)") }
    try keys.close()
    d.key(Key.k, [.maskCommand, .maskAlternate, .maskControl])
    usleep(800_000)
    guard (try? d.tty("rec_tty4")) == first else { throw Failure("Cmd+Opt+Ctrl+K still opened a tab after the reset") }
    d.key(Key.t, .maskCommand)
    usleep(1_200_000)
    guard try d.tty("rec_tty5") != first else { throw Failure("Cmd+T did not open a tab after the reset") }
    try d.run("exit")
    usleep(1_200_000)
    try d.run("echo 'settings_ok' > \(d.path("settings_witness"))")
    try d.expect("settings_witness", "settings_ok\n", "terminal keyboard input after Settings")
}

func runDesktopSettingsConflictScenario(_ d: Driver) throws {
    let ctl = "'\(d.appURL.path)/Contents/MacOS/takoctl' --bundle-id \(d.bundleID)"
    let keys = DesktopKeys(d: d)
    let before = keys.config
    try keys.open()
    try keys.show("new_tab")
    // Cmd+D belongs to Split Right: recording it on New Tab asks first.
    try keys.record("new_tab")
    d.key(Key.d, .maskCommand)
    guard d.wait(for: { keys.exact("DesktopShortcutConflict") != nil }, timeout: 5) else {
        throw Failure("no conflict for Cmd+D, which Split Right holds")
    }
    try keys.click("DesktopShortcutConflictCancel")
    guard d.wait(for: { keys.exact("DesktopShortcutConflict") == nil }, timeout: 5), keys.config == before else {
        throw Failure("Cancel did not leave the bindings unchanged: \(keys.config)")
    }
    try keys.close()
    // Unchanged at run time: Cmd+D still splits, Cmd+T still opens a tab.
    let first = try d.tty("conf_tty1")
    d.key(Key.d, .maskCommand)
    usleep(1_500_000)
    guard try d.tty("conf_split_tty") != first, try d.hasSplit(ctl) else { throw Failure("Cmd+D did not split after the cancelled conflict") }
    d.closeTab()
    usleep(1_200_000)
    d.key(Key.t, .maskCommand)
    usleep(1_200_000)
    d.activate()
    guard try d.tty("conf_tab_tty") != first else { throw Failure("Cmd+T did not open a tab after the cancelled conflict") }
    d.closeTab()
    usleep(1_200_000)

    // Reassign: Cmd+D now opens a tab, and does not split.
    try keys.open()
    try keys.show("new_tab")
    try keys.record("new_tab")
    d.key(Key.d, .maskCommand)
    guard d.wait(for: { keys.exact("DesktopShortcutConflict") != nil }, timeout: 5) else { throw Failure("no conflict on the second pass") }
    try keys.click("DesktopShortcutConflictConfirm")
    guard d.wait(for: { keys.binds("new_tab") }, timeout: 5) else { throw Failure("Reassign did not save Cmd+D for New Tab: \(keys.config)") }
    try keys.close()
    d.activate()
    let base = try d.tty("conf_owner_tty1")
    d.key(Key.d, .maskCommand)
    usleep(1_500_000)
    d.activate()
    guard try d.tty("conf_owner_tty2") != base else { throw Failure("Cmd+D did nothing after it was reassigned to New Tab") }
    guard try !d.hasSplit(ctl) else { throw Failure("Cmd+D still split after it was reassigned to New Tab") }
    d.closeTab()
    usleep(1_200_000)

    // Restore both defaults with ↺: Cmd+D splits again, Cmd+T opens a tab.
    try keys.open()
    for action in ["new_tab", "new_split:right"] {
        try keys.show(action)
        if keys.exact("DesktopShortcutReset-\(action)") != nil { try keys.click("DesktopShortcutReset-\(action)") }
    }
    // Reassigning shadows Split Right's default with a New Tab line; removing that line brings it back.
    guard d.wait(for: { !keys.binds("new_tab") && !keys.binds("new_split:right") }, timeout: 5) else {
        throw Failure("↺ did not restore the default bindings: \(keys.config)")
    }
    try keys.close()
    d.key(Key.d, .maskCommand)
    usleep(1_500_000)
    guard try d.hasSplit(ctl) else { throw Failure("Cmd+D did not split after the defaults came back") }
    d.closeTab()
    usleep(1_200_000)
    d.key(Key.t, .maskCommand)
    usleep(1_200_000)
    d.activate()
    guard try d.tty("conf_reset_tab") != base else { throw Failure("Cmd+T did not open a tab after the reset") }
    d.closeTab()
    usleep(1_200_000)
    d.activate()
    usleep(400_000)
    try d.run("echo 'conflict_ok' > \(d.path("conflict_witness"))")
    try d.expect("conflict_witness", "conflict_ok\n", "terminal keyboard input after the conflict flow")
}

func runDesktopSettingsContainmentScenario(_ d: Driver) throws {
    let ctl = "'\(d.appURL.path)/Contents/MacOS/takoctl' --bundle-id \(d.bundleID)"
    let keys = DesktopKeys(d: d)
    let before = keys.config
    try keys.open()
    // A command typed while Settings is open goes into Settings, never the shell.
    try keys.click("DesktopSettingsSearch")
    let leakFile = d.path("containment_leak.txt")
    let leak = "echo 'leaked_to_pty' > \(leakFile)"
    try d.run(leak)
    guard d.wait(for: { (keys.exact("DesktopSettingsSearch").flatMap { d.attribute($0, kAXValueAttribute) as String? }) == leak },
                 timeout: 5) else {
        throw Failure("what was typed did not stay in the Settings search field")
    }
    d.key(Key.d, .maskCommand)
    usleep(400_000)
    guard try !d.hasSplit(ctl) else { throw Failure("Cmd+D leaked through Settings and split the pane") }
    usleep(600_000)
    guard !FileManager.default.fileExists(atPath: leakFile) else { throw Failure("keys typed into Settings reached the shell") }
    // Recording, then Esc, cancels without closing or changing anything.
    try keys.show("new_tab")
    try keys.record("new_tab")
    d.key(Key.escape)
    guard d.wait(for: { keys.isOpen }, timeout: 3), keys.config == before else {
        throw Failure("Escape did not cancel recording while keeping Settings open and the config unchanged")
    }
    try keys.close()
    try d.run("echo 'containment_ok' > \(d.path("containment_recovered.txt"))")
    try d.expect("containment_recovered.txt", "containment_ok\n", "terminal keyboard input after Settings closed")
    guard !FileManager.default.fileExists(atPath: leakFile) else { throw Failure("the contained command reached the shell when Settings closed") }
}

func runPermanentSidebarScenario(_ d: Driver) throws {
    let keys = DesktopKeys(d: d)
    func shown() -> Bool { keys.exact("SessionSidebarHeader") != nil }
    guard d.wait(for: shown, timeout: 5) else { throw Failure("the session sidebar is not shown at launch") }
    // The legacy toggle and Escape leave the permanent sidebar where it is.
    d.key(Key.s, [.maskCommand, .maskAlternate])
    d.key(Key.escape)
    usleep(800_000)
    guard shown() else { throw Failure("Cmd+Opt+S or Escape hid the permanent session sidebar") }
    try d.run("echo 'sidebar_ok' > \(d.path("sidebar_witness"))")
    try d.expect("sidebar_witness", "sidebar_ok\n", "terminal keyboard input after Cmd+Opt+S")
}
