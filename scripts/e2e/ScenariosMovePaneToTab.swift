/*
 * tako — Move to Tab end-to-end check
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

/// «Move to Tab» by real input: a right click on the pane's header, the
/// submenu, the destination tab. The pane lands beside the destination's
/// pane in that tab, its process (same PID, same start time) keeps running
/// and takes the next keystrokes, and the tab it left empty closes. Then the
/// header's «Move to Tab» button, «New Tab»: the pane leaves the split for a
/// tab of its own, the same process, still taking the keyboard.
///
/// Private as the sidebar rename journey is: private HOME, XDG dirs,
/// history and session namespace, panes not kept, the owner's shell history
/// checked unchanged. Every mouse gesture goes through the driver's
/// ownership check; nothing is pressed through AX. The processes it starts
/// are killed and checked gone at the end.
func runMovePaneToTabScenario(_ d: Driver) throws {
    d.quit()
    let saved = d.environment
    let home = d.path("move-home"), sessions = d.path("move-sessions")
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
    var processes = OwnedProcesses()
    var failure: Error?
    do { try movePaneToTabJourney(d, home: home, processes: &processes, history: { stamp() == historyBefore }) } catch { failure = error }
    let problems = processes.cleanUp()
    print("owned processes: \(processes.owned.map { "\($0.pid) born \($0.birth)" }) \(problems.isEmpty ? "all gone" : "PROBLEMS \(problems)")")
    print("owner history: \(stamp() == historyBefore ? "unchanged" : "CHANGED")")
    if let error = OwnedProcesses.outcome(failure: failure, problems: problems) { throw error }
}

private func movePaneToTabJourney(_ d: Driver, home: String, processes: inout OwnedProcesses, history: () -> Bool) throws {

    try d.launch(config: "window-save-state = never\nauto-update = off\nremote-control = on\nmacos-titlebar-style = tabs\n"
                 + "session-persistence = false\n", settleTerminal: false)
    print("fixture app: pid \(d.pid), bundle \(d.bundleID), \(d.appURL.path)")
    // Below where system prompts sit (they are never answered here; the
    // click guard refuses any point they cover).
    d.setPosition(CGPoint(x: 100, y: 410))
    d.setSize(CGSize(width: 1000, height: 540))
    d.focus()
    usleep(800_000)
    let ctl = "'\(d.appURL.path)/Contents/MacOS/takoctl' --bundle-id \(d.bundleID)"
    guard let moving = try d.focusedPaneId() else { throw Failure("no first pane") }
    try d.run("echo \"$HOME|$XDG_DATA_HOME|$HISTFILE\" > \(d.path("move_env"))")
    let seen = try d.file("move_env").trimmingCharacters(in: .whitespacesAndNewlines)
    guard seen == "\(home)|\(home)/.local/share|\(home)/.shell_history" else { throw Failure("the shell is not private: \(seen)") }

    // The destination: a second tab, not selected, titled MvDest.
    let anchor = try d.exec("\(ctl) tab-new --no-select --target \(moving)").split(separator: "\n").last.map(String.init) ?? ""
    guard !anchor.isEmpty else { throw Failure("could not open the destination tab") }
    let destPid = d.path("mv-dest.pid"), movePid = d.path("mv-move.pid"), witness = d.path("mv-witness.txt")
    _ = try d.exec("\(ctl) send --target \(anchor) \"printf '\\\\033]0;MvDest\\\\007'; sh -c 'echo \\$\\$ > \(destPid); exec sleep 600'\"")
    // The moving pane: its own process, reading the keyboard into a file.
    _ = try d.exec("\(ctl) send --target \(moving) \"printf '\\\\033]0;MvSource\\\\007'; sh -c 'echo \\$\\$ > \(movePid); exec cat > \(witness)'\"")
    // Both children recorded by PID and start time before anything else can fail.
    let pid = try processes.adopt(try d.file("mv-move.pid"), what: "the moving pane's process")
    try processes.adopt(try d.file("mv-dest.pid"), what: "the destination pane's process")
    let born = processes.birth(of: pid) ?? ""

    func tree() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(try d.exec("\(ctl) --json tree").utf8)) as? [String: Any] ?? [:]
    }
    /// Each tab's pane ids, and whether any pane is kept across launches.
    func tabs() throws -> (tabs: [[String]], persistent: [Bool]) {
        var tabs: [[String]] = [], persistent: [Bool] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let panes = dict["panes"] as? [[String: Any]] {
                    tabs.append(panes.compactMap { $0["id"] as? String })
                    persistent += panes.compactMap { $0["persistentSession"] as? Bool }
                }
                dict.values.forEach(walk)
            } else if let list = node as? [Any] { list.forEach(walk) }
        }
        walk(try tree())
        return (tabs, persistent)
    }
    let before = try tabs()
    print("before: tabs \(before.tabs), persistentSession \(before.persistent)")
    guard before.persistent.count >= 2, !before.persistent.contains(true) else { throw Failure("panes must be ≥2 and not kept") }
    guard before.tabs.contains([moving]), before.tabs.contains([anchor]) else { throw Failure("unexpected starting layout \(before.tabs)") }

    func center(_ e: AXUIElement) throws -> CGPoint {
        guard let p: AXValue = d.attribute(e, kAXPositionAttribute), let s: AXValue = d.attribute(e, kAXSizeAttribute) else {
            throw Failure("no accessibility frame")
        }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p, .cgPoint, &pos); AXValueGetValue(s, .cgSize, &size)
        return CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
    }
    func guarded(_ point: CGPoint) throws {
        guard let owner = d.topmostOwner(at: point), owner == d.pid else {
            throw Failure("\(point) not owned by Tako (owner \(String(describing: d.topmostOwner(at: point))), pid \(d.pid))")
        }
        try d.requireAXOwnedTarget(at: point)
    }
    func menu(_ title: String) throws {
        guard d.wait(for: { d.openMenuItem(titled: title) != nil }, timeout: 5), let item = d.openMenuItem(titled: title) else {
            let items = d.descendants(of: d.axApp, role: kAXMenuItemRole as String).compactMap { d.attribute($0, kAXTitleAttribute) as String? }
            throw Failure("no menu item \(title); open items: \(items)")
        }
        let point = try center(item)
        try d.click(at: point)
        usleep(300_000)
    }

    // A right click on the moving pane's own header.
    let headerID = "FloatingPaneHeader-\(moving.lowercased())"
    guard d.wait(for: { d.element(withIdentifier: headerID) != nil }, timeout: 5), let header = d.element(withIdentifier: headerID) else {
        throw Failure("no header \(headerID)")
    }
    let point = try center(header)
    try guarded(point)
    CGEvent(mouseEventSource: d.source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
    try guarded(point)
    CGEvent(mouseEventSource: d.source, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
    usleep(20_000)
    CGEvent(mouseEventSource: d.source, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
    try menu("Move to Tab")
    try menu("MvDest")

    guard d.wait(for: { ((try? tabs())?.tabs ?? []).contains { $0.contains(moving) && $0.contains(anchor) } }, timeout: 5) else {
        throw Failure("the pane did not join the destination tab: \(String(describing: try? tabs().tabs))")
    }
    let after = try tabs()
    print("after: tabs \(after.tabs), persistentSession \(after.persistent)")
    guard after.tabs.count == before.tabs.count - 1 else { throw Failure("the emptied tab did not close: \(after.tabs)") }
    guard let joined = after.tabs.first(where: { $0.contains(moving) }), joined == [anchor, moving] else {
        throw Failure("expected [destination, moved] side by side, got \(after.tabs)")
    }
    let now = processes.identity(pid)
    guard now == .running(birth: born) else {
        throw Failure("the moved pane's process is not the same one (pid \(pid), born \(born), now \(now))")
    }
    print("process: pid \(pid) born \(born), same after the move")

    // The keyboard went with the pane: what is typed now reaches its process.
    try d.type("moved-keys-ok")
    d.key(Key.returnKey)
    guard d.wait(for: { ((try? String(contentsOfFile: witness, encoding: .utf8)) ?? "").contains("moved-keys-ok") }, timeout: 5) else {
        throw Failure("the moved pane's process did not get the keystrokes: \(String(describing: try? String(contentsOfFile: witness, encoding: .utf8)))")
    }
    print("keyboard witness: moved-keys-ok reached pid \(pid)")

    // Back out of the split by the header's own button: a real left click on
    // «Move to Tab», then «New Tab». The pane gets a tab of its own again.
    let buttonID = "FloatingPaneMoveToTab-\(moving.lowercased())"
    guard d.wait(for: { d.element(withIdentifier: buttonID) != nil }, timeout: 5), let button = d.element(withIdentifier: buttonID) else {
        throw Failure("no header button \(buttonID)")
    }
    let buttonPoint = try center(button)
    try guarded(buttonPoint)
    CGEvent(mouseEventSource: d.source, mouseType: .mouseMoved, mouseCursorPosition: buttonPoint, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(150_000)
    try guarded(buttonPoint)
    try d.click(at: buttonPoint)
    try menu("New Tab")
    guard d.wait(for: { ((try? tabs())?.tabs ?? []).contains([moving]) }, timeout: 5) else {
        throw Failure("the pane did not get a tab of its own: \(String(describing: try? tabs().tabs))")
    }
    let out = try tabs()
    print("after New Tab: tabs \(out.tabs)")
    guard out.tabs.count == after.tabs.count + 1, out.tabs.contains([anchor]) else {
        throw Failure("expected the destination alone and the pane alone, got \(out.tabs)")
    }
    guard processes.identity(pid) == .running(birth: born) else { throw Failure("the pane's process changed on New Tab") }
    try d.type("newtab-keys-ok")
    d.key(Key.returnKey)
    guard d.wait(for: { ((try? String(contentsOfFile: witness, encoding: .utf8)) ?? "").contains("newtab-keys-ok") }, timeout: 5) else {
        throw Failure("the pane's process did not get the keystrokes in its new tab")
    }
    print("keyboard witness: newtab-keys-ok reached pid \(pid) in its new tab")

    // The sidebar: a right click on the session's row, «Move to Tab», MvDest.
    // The whole session joins MvDest and its tab closes.
    if !d.hasText(containing: "Sessions") { d.key(Key.s, [.maskCommand, .maskAlternate]) }
    func sidebarRow(_ text: String) -> AXUIElement? {
        guard let main: AXUIElement = d.attribute(AXUIElementCreateApplication(d.pid), kAXMainWindowAttribute),
              let bar = d.element(withIdentifier: "SessionSidebar", root: main) else { return nil }
        return d.descendants(of: bar, role: kAXStaticTextRole as String).first { (d.attribute($0, kAXValueAttribute) as String?) == text }
    }
    guard d.wait(for: { sidebarRow("MvSource") != nil }, timeout: 10), let row = sidebarRow("MvSource") else {
        throw Failure("the sidebar does not list MvSource: \(d.staticTexts().prefix(40))")
    }
    let rowPoint = try center(row)
    try guarded(rowPoint)
    CGEvent(mouseEventSource: d.source, mouseType: .mouseMoved, mouseCursorPosition: rowPoint, mouseButton: .right)?.post(tap: .cghidEventTap)
    try guarded(rowPoint)
    CGEvent(mouseEventSource: d.source, mouseType: .rightMouseDown, mouseCursorPosition: rowPoint, mouseButton: .right)?.post(tap: .cghidEventTap)
    usleep(20_000)
    CGEvent(mouseEventSource: d.source, mouseType: .rightMouseUp, mouseCursorPosition: rowPoint, mouseButton: .right)?.post(tap: .cghidEventTap)
    try menu("Move to Tab")
    try menu("MvDest")
    guard d.wait(for: { ((try? tabs())?.tabs ?? []).contains { $0.contains(moving) && $0.contains(anchor) } }, timeout: 5) else {
        throw Failure("the session did not join MvDest from the sidebar: \(String(describing: try? tabs().tabs))")
    }
    let merged = try tabs()
    print("after sidebar Move to Tab: tabs \(merged.tabs)")
    guard merged.tabs.count == out.tabs.count - 1 else { throw Failure("the session's emptied tab did not close: \(merged.tabs)") }
    guard processes.identity(pid) == .running(birth: born) else { throw Failure("the pane's process changed on the sidebar move") }
    print("process: pid \(pid) born \(born), same after all three moves")
    guard history() else { throw Failure("the owner's shell history changed") }
}
