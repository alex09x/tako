/*
 * tako — Sidebar in-place rename end-to-end check
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

/// Renaming in the sidebar by real input, end to end, on a session and on a
/// terminal: the row menu's «Rename …», a double-click on the name and F2 on
/// the list open the field; Return keeps the name, Esc and clicking away
/// leave the old one; «Use Automatic Name» gives the automatic one back; a
/// row that changes status group mid-typing keeps the field, the draft and
/// the keyboard.
///
/// Private as the settings journey is: private HOME, XDG dirs, history and
/// session namespace, panes not kept, the owner's shell history checked
/// unchanged on every exit. Every mouse gesture -- menus included -- goes
/// through the driver's ownership check; nothing is pressed through AX.
func runSidebarRenameScenario(_ d: Driver) throws {
    d.quit()
    let saved = d.environment
    let home = d.path("rename-home"), sessions = d.path("rename-sessions")
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
    defer {
        let after = stamp()
        print("owner history: \(after == historyBefore ? "unchanged" : "CHANGED before=\(historyBefore) after=\(after)")")
    }

    try d.launch(config: "window-save-state = never\nauto-update = off\nremote-control = on\nmacos-titlebar-style = tabs\n"
                 + "session-persistence = false\nsidebar-style = classic\nsidebar-group = workspace\n", settleTerminal: false)
    print("fixture app: pid \(d.pid), bundle \(d.bundleID), \(d.appURL.path)")
    d.setPosition(CGPoint(x: 100, y: 300))
    d.setSize(CGSize(width: 1000, height: 600))
    d.focus()
    usleep(800_000)
    let ctl = "'\(d.appURL.path)/Contents/MacOS/takoctl' --bundle-id \(d.bundleID)"
    guard let alpha = try d.focusedPaneId() else { throw Failure("no first pane") }
    try d.run("echo \"$HOME|$XDG_DATA_HOME|$HISTFILE\" > \(d.path("rename_env"))")
    let seen = try d.file("rename_env").trimmingCharacters(in: .whitespacesAndNewlines)
    guard seen == "\(home)|\(home)/.local/share|\(home)/.shell_history" else { throw Failure("the shell is not private: \(seen)") }

    // Session «RnAlpha» with one terminal; a second session with two, «RnBetaL» and «RnBetaR».
    let beta = try d.exec("\(ctl) tab-new --target \(alpha)").split(separator: "\n").last.map(String.init) ?? ""
    let betaRight = try d.exec("\(ctl) split right --target \(beta)").split(separator: "\n").last.map(String.init) ?? ""
    guard !beta.isEmpty, !betaRight.isEmpty else { throw Failure("could not open the second session's terminals") }
    for (pane, title) in [(alpha, "RnAlpha"), (beta, "RnBetaL"), (betaRight, "RnBetaR")] {
        _ = try d.exec("\(ctl) send --target \(pane) \"printf '\\\\033]0;\(title)\\\\007'; exec sleep 600\"")
    }
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
    guard persistent.count >= 3, !persistent.contains(true) else { throw Failure("panes must be ≥3 and not kept: \(persistent)") }

    if !d.hasText(containing: "Sessions") { d.key(Key.s, [.maskCommand, .maskAlternate]) }
    func sidebarText(_ text: String) -> AXUIElement? {
        guard let bar = d.element(withIdentifier: "SessionSidebar") else { return nil }
        return d.descendants(of: bar, role: kAXStaticTextRole as String).first {
            (d.attribute($0, kAXValueAttribute) as String?) == text
        }
    }
    func shows(_ text: String) -> Bool { sidebarText(text) != nil }
    guard d.wait(for: { shows("RnAlpha") && shows("RnBetaL") && shows("RnBetaR") }, timeout: 10) else {
        throw Failure("the sidebar does not list RnAlpha, RnBetaL and RnBetaR: \(d.staticTexts().prefix(40))")
    }

    func center(_ e: AXUIElement) throws -> CGPoint {
        guard let p: AXValue = d.attribute(e, kAXPositionAttribute), let s: AXValue = d.attribute(e, kAXSizeAttribute) else {
            throw Failure("no accessibility frame")
        }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p, .cgPoint, &pos); AXValueGetValue(s, .cgSize, &size)
        return CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
    }
    func named(_ text: String) throws -> CGPoint {
        guard d.wait(for: { shows(text) }, timeout: 5), let e = sidebarText(text) else { throw Failure("no sidebar name \(text)") }
        return try center(e)
    }
    func guarded(_ point: CGPoint) throws {
        guard let owner = d.topmostOwner(at: point), owner == d.pid else {
            throw Failure("\(point) not owned by Tako (owner \(String(describing: d.topmostOwner(at: point))), pid \(d.pid))")
        }
        try d.requireAXOwnedTarget(at: point)
    }
    func contextClick(_ text: String) throws {
        let point = try named(text)
        try guarded(point)
        CGEvent(mouseEventSource: d.source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
        try guarded(point)
        CGEvent(mouseEventSource: d.source, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
        usleep(20_000)
        CGEvent(mouseEventSource: d.source, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
    }
    /// A menu item by a real, ownership-checked click: no AX press.
    func menu(_ title: String) throws {
        guard d.wait(for: { d.openMenuItem(titled: title) != nil }, timeout: 5), let item = d.openMenuItem(titled: title) else {
            throw Failure("no menu item \(title)")
        }
        try d.click(at: try center(item))
        usleep(300_000)
    }
    func field() -> AXUIElement? { d.element(withIdentifier: "SidebarRenameField") }
    func fieldValue() -> String? { field().flatMap { d.attribute($0, kAXValueAttribute) as String? } }
    /// Who has the keys: the field's own AXFocused and the app's focused element.
    func focusReport() -> String {
        let fieldFocused = field().flatMap { d.attribute($0, kAXFocusedAttribute) as Bool? }
        let app = AXUIElementCreateApplication(d.pid)
        let focused: AXUIElement? = d.attribute(app, kAXFocusedUIElementAttribute)
        let role = focused.flatMap { d.attribute($0, kAXRoleAttribute) as String? } ?? "nil"
        let id = focused.flatMap { d.attribute($0, kAXIdentifierAttribute) as String? } ?? "nil"
        func describe(_ w: AXUIElement?) -> String {
            guard let w else { return "nil" }
            let title = (d.attribute(w, kAXTitleAttribute) as String?) ?? "?"
            let main = (d.attribute(w, kAXMainAttribute) as Bool?) ?? false
            return "\(title)\(main ? " (main)" : "")"
        }
        let fieldWindow: AXUIElement? = field().flatMap { d.attribute($0, kAXWindowAttribute) }
        let mainWindow: AXUIElement? = d.attribute(app, kAXMainWindowAttribute)
        return "field \(field() != nil) focused \(String(describing: fieldFocused)) value \(String(describing: fieldValue())) in window \(describe(fieldWindow)); "
            + "app focus \(role)/\(id), main window \(describe(mainWindow))"
    }
    func editing() throws {
        guard d.wait(for: { field() != nil }, timeout: 5) else { throw Failure("the rename field did not open") }
        print("  opened: \(focusReport())")
        usleep(200_000)
        print("  +200ms: \(focusReport())")
    }
    func replace(with text: String) throws {
        d.key(Key.a, .maskCommand)
        try d.type(text)
        print("  typed \(text): \(focusReport())")
    }
    func step(_ name: String, _ body: () throws -> Void) throws {
        do { try body(); print("step \(name): ok") } catch { print("step \(name): FAILED \(error)"); throw error }
    }
    func expectName(_ shown: String, gone: [String], _ what: String) throws {
        guard d.wait(for: { field() == nil && shows(shown) && gone.allSatisfy { !shows($0) } }, timeout: 5) else {
            throw Failure("\(what): field \(field() != nil), shows \(shown) \(shows(shown)) (anywhere in the app \(d.hasText(containing: shown))), "
                          + "still shown \(gone.filter(shows)); \(focusReport())")
        }
    }

    try step("menu rename session + Return") {
        try contextClick("RnAlpha"); try menu("Rename Session"); try editing()
        try replace(with: "Alpha One"); d.key(Key.returnKey)
        try expectName("Alpha One", gone: ["RnAlpha"], "Return keeps the session name")
    }
    try step("double-click + Escape") {
        try d.doubleClick(at: try named("Alpha One")); try editing()
        try replace(with: "Nope"); d.key(Key.escape)
        try expectName("Alpha One", gone: ["Nope"], "Esc leaves the name")
    }
    try step("double-click + click away") {
        try d.doubleClick(at: try named("Alpha One")); try editing()
        try replace(with: "Away")
        guard let window = d.activeWindow(), let p: AXValue = d.attribute(window, kAXPositionAttribute),
              let s: AXValue = d.attribute(window, kAXSizeAttribute) else { throw Failure("no window frame") }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p, .cgPoint, &pos); AXValueGetValue(s, .cgSize, &size)
        try d.click(at: CGPoint(x: pos.x + size.width - 120, y: pos.y + size.height / 2))   // the terminal
        try expectName("Alpha One", gone: ["Away"], "clicking away leaves the name")
    }
    try step("Use Automatic Name (session)") {
        try contextClick("Alpha One"); try menu("Use Automatic Name")
        try expectName("RnAlpha", gone: ["Alpha One"], "the automatic name is back")
    }
    try step("F2 on the list") {
        guard let search = d.element(withIdentifier: "SessionSidebarSearchField") else { throw Failure("no sidebar search field") }
        try d.clickElement(search)
        usleep(300_000)
        d.key(Key.escape)   // the search hands the keys to the list
        usleep(300_000)
        d.key(120)          // F2: the row under the list's cursor
        try editing()
        let before = fieldValue() ?? ""
        try replace(with: "Keys Named"); d.key(Key.returnKey)
        try expectName("Keys Named", gone: [before], "F2 renames the cursor's row")
        try contextClick("Keys Named"); try menu("Use Automatic Name")
        try expectName(before, gone: ["Keys Named"], "and it goes back")
    }
    try step("menu rename terminal + automatic") {
        try contextClick("RnBetaR"); try menu("Rename Terminal"); try editing()
        try replace(with: "Logs Pane"); d.key(Key.returnKey)
        try expectName("Logs Pane", gone: ["RnBetaR"], "Return keeps the terminal name")
        guard shows("RnBetaL") else { throw Failure("the other terminal's name changed too") }
        try contextClick("Logs Pane"); try menu("Use Automatic Name")
        try expectName("RnBetaR", gone: ["Logs Pane"], "the terminal's automatic name is back")
    }
    try step("status regroup mid-typing") {
        _ = try d.exec("\(ctl) config set sidebar-group=status")
        guard d.wait(for: { d.element(withIdentifier: "SidebarStatusBucket-") != nil }, timeout: 5) else {
            throw Failure("grouping by status did not show its buckets: \(d.staticTexts().prefix(30))")
        }
        try d.doubleClick(at: try named("RnAlpha")); try editing()
        try replace(with: "Moving")
        _ = try d.exec("\(ctl) status set needs_approval --text RenameCheck --target \(alpha)")
        guard d.wait(for: { d.element(withIdentifier: "SidebarStatusBucket-needsYou") != nil }, timeout: 5) else {
            throw Failure("the row did not move to Needs you: \(d.staticTexts().prefix(30))")
        }
        usleep(500_000)
        guard fieldValue() == "Moving" else { throw Failure("after the regroup the field shows \(String(describing: fieldValue()))") }
        try d.type(" Row"); d.key(Key.returnKey)
        try expectName("Moving Row", gone: ["RnAlpha"], "the draft and the keyboard survive the row moving")
        try contextClick("Moving Row"); try menu("Use Automatic Name")
        try expectName("RnAlpha", gone: ["Moving Row"], "and it goes back")
    }
    guard stamp() == historyBefore else { throw Failure("the owner's shell history changed: \(stamp())") }
}
