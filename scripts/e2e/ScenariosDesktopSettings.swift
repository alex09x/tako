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
        d.windows().lazy.compactMap { find([id], under: $0, depth: 30) }.first
    }

    /// The first element under `root` whose identifier is exactly one of `ids`.
    func find(_ ids: Set<String>, under root: AXUIElement, depth: Int) -> AXUIElement? {
        if let id = d.attribute(root, "AXIdentifier") as String?, ids.contains(id) { return root }
        guard depth > 0 else { return nil }
        for child in (d.attribute(root, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            if let hit = find(ids, under: child, depth: depth - 1) { return hit }
        }
        return nil
    }

    /// The action's own Record or Reset control, looked up only inside its
    /// row (`DesktopShortcut-<action>`): an unselected row names it
    /// `DesktopShortcut<kind>-<action>`, the selected one plain
    /// `DesktopShortcut<kind>`, which is never taken from another row.
    func control(_ kind: String, of action: String) -> AXUIElement? {
        guard let row = exact("DesktopShortcut-\(action)") else { return nil }
        return find(["DesktopShortcut\(kind)-\(action)", "DesktopShortcut\(kind)"], under: row, depth: 12)
    }

    func clickControl(_ kind: String, of action: String) throws {
        try clickLaidOut("the \(kind) control of the \(action) row") { control(kind, of: action) }
    }

    func hasFrame(_ e: AXUIElement) -> Bool {
        (d.attribute(e, kAXPositionAttribute) as AXValue?) != nil && (d.attribute(e, kAXSizeAttribute) as AXValue?) != nil
    }

    /// Scrolls the control into view and clicks it once it has a frame:
    /// SwiftUI can report a control in the tree a moment before it is laid out.
    func clickLaidOut(_ what: String, _ find: () -> AXUIElement?) throws {
        guard d.wait(for: { find() != nil }, timeout: 5), let e = find() else { throw Failure("no \(what)") }
        AXUIElementPerformAction(e, "AXScrollToVisible" as CFString)
        guard d.wait(for: { find().map(hasFrame) == true }, timeout: 3), let laidOut = find() else {
            throw Failure("\(what) has no AX position/size")
        }
        usleep(300_000)
        print("click \(what)")
        try d.clickElement(find() ?? laidOut)
        usleep(300_000)
    }

    var isOpen: Bool { exact("DesktopSettingsRoot") != nil }

    func open() throws {
        d.key(Key.comma, .maskCommand)
        guard d.wait(for: { isOpen }, timeout: 5) else { throw Failure("Cmd+, did not open Settings (no DesktopSettingsRoot)") }
        SettingsPage(d).placeWindow()
    }

    /// The owned window holding Settings, moved to the top left of the
    /// display's visible frame and raised, and proved fully inside it, just
    /// before Close. A notification alert sits at the right of the test
    /// Mac's screen: at SettingsPage's bottom-left placement Close ended up
    /// under it, while at the top left the page's own controls do. Nothing
    /// foreign is moved or dismissed, and clicks keep their ownership guards.
    func placeTopLeft() throws {
        guard let root = exact("DesktopSettingsRoot"), let window: AXUIElement = d.attribute(root, kAXWindowAttribute),
              let screen = NSScreen.screens.first, let sizeVal: AXValue = d.attribute(window, kAXSizeAttribute) else {
            throw Failure("no owned Settings window to place")
        }
        var size = CGSize.zero
        AXValueGetValue(sizeVal, .cgSize, &size)
        // AX coordinates run down from the top of the primary display.
        let visible = screen.visibleFrame, top = screen.frame.maxY
        let area = CGRect(x: visible.minX, y: top - visible.maxY, width: visible.width, height: visible.height)
        let margin = max(0, min(20, (area.height - size.height) / 2, (area.width - size.width) / 2))
        var origin = CGPoint(x: area.minX + margin, y: area.minY + margin)
        if let value = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        usleep(400_000)
        guard let posVal: AXValue = d.attribute(window, kAXPositionAttribute) else { throw Failure("Settings window has no position") }
        var pos = CGPoint.zero
        AXValueGetValue(posVal, .cgPoint, &pos)
        let frame = CGRect(origin: pos, size: size)
        print("settings window placed at \(frame) in visible \(area)")
        guard area.insetBy(dx: -1, dy: -1).contains(frame) else {
            throw Failure("the Settings window \(frame) is not fully inside the visible frame \(area)")
        }
    }

    func click(_ id: String) throws {
        try clickLaidOut(id) { exact(id) }
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
        try clickControl("Record", of: action)
        func label() -> String? {
            control("Record", of: action).flatMap { d.attribute($0, "AXLabel") as String? ?? d.attribute($0, kAXDescriptionAttribute) as String? }
        }
        guard d.wait(for: { label() == "Recording Shortcut" }, timeout: 5) else {
            throw Failure("\(action) did not start recording")
        }
    }

    func close() throws {
        try placeTopLeft()
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

    /// The pane tree as takoctl reports it, parsed: every pane with its
    /// window and tab, the focused pane, the selected tabs, and the tabs
    /// whose layout is split. The raw JSON goes to `name` in the work dir.
    func treeFacts(_ ctl: String, saveAs name: String) throws -> (panes: [String: String], focused: String?, selected: [String], split: [String]) {
        let raw = try exec("\(ctl) tree --json")
        try raw.write(toFile: path(name), atomically: true, encoding: .utf8)
        guard let obj = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let windows = ((obj["result"] as? [String: Any]) ?? obj)["windows"] as? [[String: Any]] else {
            throw Failure("takoctl tree is not the expected JSON: \(raw.prefix(300))")
        }
        var panes: [String: String] = [:], focused: String?, selected: [String] = [], split: [String] = []
        for w in windows {
            for t in (w["tabs"] as? [[String: Any]]) ?? [] {
                let place = "\(w["id"] as? String ?? "?")/\(t["id"] as? String ?? "?")"
                if t["selected"] as? Bool == true { selected.append(place) }
                if (t["layout"] as? [String: Any])?["split"] != nil { split.append(place) }
                for p in (t["panes"] as? [[String: Any]]) ?? [] {
                    guard let id = p["id"] as? String else { continue }
                    panes[id] = place
                    if p["focused"] as? Bool == true { focused = id }
                }
            }
        }
        return (panes, focused, selected.sorted(), split.sorted())
    }
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
    // Its shell exits, which leaves the tab open and empty by design; closing
    // that tab gives the keyboard back to the first one.
    try d.run("exit")
    usleep(800_000)
    d.closeTab()
    usleep(1_200_000)
    guard (try? d.tty("rec_tty3")) == first else { throw Failure("focus did not return to the first tab after the new one was closed") }

    // Restore the default with ↺; the chord does nothing, Cmd+T opens a tab.
    try keys.open()
    try keys.show("new_tab")
    try keys.clickControl("Reset", of: "new_tab")
    guard d.wait(for: { !keys.binds("new_tab") }, timeout: 5) else { throw Failure("↺ did not restore New Tab's default: \(keys.config)") }
    try keys.close()
    d.key(Key.k, [.maskCommand, .maskAlternate, .maskControl])
    usleep(800_000)
    guard (try? d.tty("rec_tty4")) == first else { throw Failure("Cmd+Opt+Ctrl+K still opened a tab after the reset") }
    d.key(Key.t, .maskCommand)
    usleep(1_200_000)
    guard try d.tty("rec_tty5") != first else { throw Failure("Cmd+T did not open a tab after the reset") }
    try d.run("exit")
    usleep(800_000)
    d.closeTab()
    usleep(1_200_000)
    guard (try? d.tty("rec_tty6")) == first else { throw Failure("focus did not return to the first tab after the Cmd+T tab was closed") }
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
    // Where the keyboard is after Reassign and Close: printed before the
    // next typed probe, which round 4 saw reach no shell (Screen: []).
    let facts = try d.treeFacts(ctl, saveAs: "conf-tree-after-reassign.json")
    let focusedEl: AXUIElement? = d.attribute(d.axApp, kAXFocusedUIElementAttribute)
    let role = focusedEl.flatMap { d.attribute($0, kAXRoleAttribute) as String? } ?? "nil"
    let id = focusedEl.flatMap { d.attribute($0, "AXIdentifier") as String? } ?? "nil"
    print("[diag conflict] after Reassign+Close: panes \(facts.panes) focused \(facts.focused ?? "nil") selected \(facts.selected) split \(facts.split); AX focus role \(role) id \(id); Settings open \(keys.isOpen); on-screen windows \(d.onScreenWindows().count)")
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
        // Only rows that carry an override show ↺; it is looked up in that row alone.
        if keys.control("Reset", of: action) != nil { try keys.clickControl("Reset", of: action) }
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
    // What Cmd+D finds and leaves, recorded either way: which panes exist
    // where, which pane has focus, which tab is shown and which is split,
    // plus the window AX calls key. A split anywhere -- or a new pane -- is
    // a leak; a split already there before would be a dirty fixture.
    func keyWindow() -> String {
        let w: AXUIElement? = d.attribute(d.axApp, kAXFocusedWindowAttribute)
        let title = w.flatMap { d.attribute($0, kAXTitleAttribute) as String? } ?? "nil"
        return "key window \(title.debugDescription), Settings open \(keys.isOpen), on-screen windows \(d.onScreenWindows().count)"
    }
    let treeBefore = try d.treeFacts(ctl, saveAs: "modal-tree-before.json")
    guard !treeBefore.panes.isEmpty else {
        throw Failure("the control tree returned no panes for the fixture's running shell")
    }
    print("[diag modal] before Cmd+D: panes \(treeBefore.panes) focused \(treeBefore.focused ?? "nil") selected \(treeBefore.selected) split \(treeBefore.split); \(keyWindow())")
    guard treeBefore.split.isEmpty else { throw Failure("the fixture was already split before Cmd+D: \(treeBefore.split)") }
    d.key(Key.d, .maskCommand)
    usleep(1_000_000)
    let treeAfter = try d.treeFacts(ctl, saveAs: "modal-tree-after.json")
    print("[diag modal] after Cmd+D:  panes \(treeAfter.panes) focused \(treeAfter.focused ?? "nil") selected \(treeAfter.selected) split \(treeAfter.split); \(keyWindow())")
    let added = Set(treeAfter.panes.keys).subtracting(treeBefore.panes.keys)
    guard added.isEmpty, treeAfter.split.isEmpty else {
        throw Failure("Cmd+D leaked through Settings: new panes \(added.sorted()) in \(added.map { treeAfter.panes[$0] ?? "?" }), split tabs \(treeAfter.split)")
    }
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
