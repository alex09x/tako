/*
 * tako — How long a sidebar click takes to switch tabs (diagnostic)
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

/// A real click on a sidebar row, timed until the window set on screen
/// changes to the clicked tab's. Five tabs, one of them printing a line every
/// 100 ms. Clicks land on a row's name and beside it; every switch must reach
/// the screen within 250 ms. Private HOME/XDG/history/sessions; the processes
/// it starts are killed and checked gone.
func runSidebarSwitchSpeedScenario(_ d: Driver) throws {
    d.quit()
    let saved = d.environment
    let home = d.path("switch-home"), sessions = d.path("switch-sessions")
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
    do { try sidebarSwitchJourney(d, home: home, processes: &processes) } catch { failure = error }
    let problems = processes.cleanUp()
    print("owned processes: \(processes.owned.count) \(problems.isEmpty ? "all gone" : "PROBLEMS \(problems)")")
    let historyKept = stamp() == historyBefore
    print("owner history: \(historyKept ? "unchanged" : "CHANGED")")
    if failure == nil, !historyKept { failure = Failure("the owner's shell history changed") }
    if let error = OwnedProcesses.outcome(failure: failure, problems: problems) { throw error }
}

private func sidebarSwitchJourney(_ d: Driver, home: String, processes: inout OwnedProcesses) throws {
    try d.launch(config: "window-save-state = never\nauto-update = off\nremote-control = on\nmacos-titlebar-style = tabs\n"
                 + "session-persistence = false\n", settleTerminal: false)
    // Keep all five row targets on the hosted VM's 1024x768 display as well
    // as on the larger test Mac. No click may land behind the Dock.
    let display = CGDisplayBounds(CGMainDisplayID())
    let height = min(560, display.height - 120)
    d.setPosition(CGPoint(x: display.minX + 60,
                          y: max(display.minY + 60, display.maxY - height - 80)))
    d.setSize(CGSize(width: min(1100, display.width - 120), height: height))
    d.focus()
    usleep(800_000)
    let ctl = "'\(d.appURL.path)/Contents/MacOS/takoctl' --bundle-id \(d.bundleID)"
    guard let first = try d.focusedPaneId() else { throw Failure("no first pane") }
    // Checked from inside the shell: the fixture's own HOME, data and history.
    try d.run("echo \"$HOME|$XDG_DATA_HOME|$HISTFILE\" > \(d.path("switch_env"))")
    let seen = try d.file("switch_env").trimmingCharacters(in: .whitespacesAndNewlines)
    guard seen == "\(home)|\(home)/.local/share|\(home)/.shell_history" else { throw Failure("the shell is not private: \(seen)") }
    let names = ["SwA", "SwB", "SwC", "SwD", "SwE"]
    var panes = [first]
    for _ in names.dropFirst() {
        let id = try d.exec("\(ctl) tab-new --no-select --target \(first)").split(separator: "\n").last.map(String.init) ?? ""
        guard !id.isEmpty else { throw Failure("could not open a tab") }
        panes.append(id)
    }
    for (i, (pane, name)) in zip(panes, names).enumerated() {
        let pidFile = d.path("sw-\(name).pid")
        // SwC prints a line every 100 ms, as a working agent does.
        let body = i == 2 ? "while :; do date; sleep 0.1; done" : "exec sleep 600"
        _ = try d.exec("\(ctl) send --target \(pane) \"printf '\\\\033]0;\(name)\\\\007'; sh -c 'echo \\$\\$ > \(pidFile); \(body)'\"")
        try processes.adopt(try d.file("sw-\(name).pid"), what: "\(name)'s process")
    }
    if !d.hasText(containing: "Sessions") { d.key(Key.s, [.maskCommand, .maskAlternate]) }
    func row(_ text: String) -> AXUIElement? {
        guard let main: AXUIElement = d.attribute(AXUIElementCreateApplication(d.pid), kAXMainWindowAttribute),
              let bar = d.element(withIdentifier: "SessionSidebar", root: main) else { return nil }
        return d.descendants(of: bar, role: kAXStaticTextRole as String).first { (d.attribute($0, kAXValueAttribute) as String?) == text }
    }
    func center(_ e: AXUIElement) throws -> CGPoint {
        guard let p: AXValue = d.attribute(e, kAXPositionAttribute), let s: AXValue = d.attribute(e, kAXSizeAttribute) else {
            throw Failure("no accessibility frame")
        }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p, .cgPoint, &pos); AXValueGetValue(s, .cgSize, &size)
        return CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
    }
    guard d.wait(for: { names.allSatisfy { row($0) != nil } }, timeout: 10) else {
        throw Failure("the sidebar does not list all of \(names): \(d.staticTexts().prefix(40))")
    }
    usleep(1_000_000)

    func frame(_ e: AXUIElement) throws -> CGRect {
        guard let p: AXValue = d.attribute(e, kAXPositionAttribute), let s: AXValue = d.attribute(e, kAXSizeAttribute) else {
            throw Failure("no accessibility frame")
        }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p, .cgPoint, &pos); AXValueGetValue(s, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }
    var timings: [Double] = []
    var lines: [String] = []
    struct Boundary {
        let name: String
        let down: Double
        let up: Double
        let shown: Double
        let wallMS: Double
        let polls: Int
        let maxPoll: Double
        let lastUnchangedStart: Double
        let changedPollStart: Double
    }
    var boundaries: [Boundary] = []
    // Two rounds on the row's name (where a double click renames), one beside
    // it. SwA is shown at the start; no order clicks the tab already shown.
    let orders = [["SwB", "SwC", "SwD", "SwE", "SwA"], ["SwC", "SwE", "SwB", "SwD", "SwA"], ["SwE", "SwD", "SwC", "SwB", "SwA"]]
    for (round, order) in orders.enumerated() {
        let beside = round == 2
        for name in order {
            guard let r = row(name) else { throw Failure("no row \(name)") }
            var point = try center(r)
            if beside { point.x = try frame(r).maxX + 14 }
            let before = d.onScreenWindowNumbers()
            // The ownership checks first; the clock starts at the press itself.
            guard let owner = d.topmostOwner(at: point), owner == d.pid else { throw Failure("\(point) not Tako's") }
            try d.requireAXOwnedTarget(at: point)
            CGEvent(mouseEventSource: d.source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(30_000)
            let downAt = ProcessInfo.processInfo.systemUptime
            let started = Date()
            CGEvent(mouseEventSource: d.source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(20_000)
            CGEvent(mouseEventSource: d.source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            let upAt = ProcessInfo.processInfo.systemUptime
            var changed = false
            var polls = 0, maxPoll = 0.0
            var lastUnchangedStart = downAt, changedPollStart = downAt
            while Date().timeIntervalSince(started) < 3 {
                let pollStart = ProcessInfo.processInfo.systemUptime
                let numbers = d.onScreenWindowNumbers()
                let pollEnd = ProcessInfo.processInfo.systemUptime
                polls += 1
                maxPoll = max(maxPoll, pollEnd - pollStart)
                if numbers != before { changed = true; changedPollStart = pollStart; break }
                lastUnchangedStart = pollStart
                usleep(5_000)
            }
            let shown = Date().timeIntervalSince(started)
            let shownAt = ProcessInfo.processInfo.systemUptime
            boundaries.append(Boundary(name: (beside ? "beside " : "name ") + name,
                                       down: downAt, up: upAt, shown: shownAt, wallMS: shown * 1000,
                                       polls: polls, maxPoll: maxPoll,
                                       lastUnchangedStart: lastUnchangedStart, changedPollStart: changedPollStart))
            lines.append(String(format: "%@%@ %.0f ms", beside ? "beside " : "name ", name, shown * 1000))
            guard changed else { throw Failure("a click on \(name)'s row did not switch tabs: \(lines)") }
            timings.append(shown * 1000)
            usleep(450_000)
        }
    }
    let sorted = timings.sorted()
    print("[timing] sidebar switch: " + lines.joined(separator: "; "))
    print(String(format: "[timing] sidebar switch: %d switches, median %.0f ms, max %.0f ms",
                 timings.count, sorted[sorted.count / 2], sorted.last ?? 0))
    // Read the existing public app history once, after ALL timed clicks. No
    // control request or AX read is inserted into a click's measured interval.
    // Its timestamp uses the same systemUptime clock as these boundaries.
    let history = try d.tabTransitions()
    guard let origin = boundaries.first?.down else {
        throw Failure("no app-side transition history for the timed sidebar switches")
    }
    let timedHistory = history.filter { ((($0["timestamp"] as? NSNumber)?.doubleValue) ?? -1) >= origin }
    guard !timedHistory.isEmpty else { throw Failure("no app-side transition recorded after the timed clicks began") }
    for b in boundaries {
        print(String(format: "[timing boundary] %@ down@%.1f up@%.1f shown@%.1f ms; wall=%.1f mono=%.1f ms; polls=%d maxCG=%.1f lastOldQuery@%.1f changedQuery@%.1f ms",
                     b.name, (b.down-origin)*1000, (b.up-origin)*1000, (b.shown-origin)*1000,
                     b.wallMS, (b.shown-b.down)*1000, b.polls, b.maxPoll*1000,
                     (b.lastUnchangedStart-origin)*1000, (b.changedPollStart-origin)*1000))
    }
    for event in timedHistory.prefix(50) {
        guard let time = (event["timestamp"] as? NSNumber)?.doubleValue, time >= origin else { continue }
        print(String(format: "[timing model] %@ -> %@ @%.1f ms",
                     event["from_id"] as? String ?? "missing", event["to_id"] as? String ?? "missing", (time-origin)*1000))
    }
    // A click on the name used to wait out the double-click interval (~480 ms).
    guard let slowest = sorted.last, slowest < 250 else {
        throw Failure(String(format: "a sidebar switch took %.0f ms to reach the screen", sorted.last ?? 0))
    }
}
