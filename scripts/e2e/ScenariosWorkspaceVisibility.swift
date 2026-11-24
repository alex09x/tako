/*
 * tako — Workspace sessions remain reachable in the permanent sidebar
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import ApplicationServices
import Foundation

func runWorkspaceVisibilityScenario(_ d: Driver) throws {
    let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
    func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
    // One tab per entry: a long-running process, and for agents the status their hooks would set.
    struct Spec { let title: String; let workspace: String; let status: String?; let command: String }
    let log = d.path("ws-visible.log")
    try "start\n".write(toFile: log, atomically: true, encoding: .utf8)
    let specs = [
        Spec(title: "E2E Claude agent", workspace: "Default", status: "working", command: "exec sleep 600"),
        Spec(title: "E2E tail log", workspace: "Default", status: nil, command: "exec tail -f \(log)"),
        Spec(title: "E2E Codex agent", workspace: "E2ELegal", status: "needs_approval", command: "exec sleep 600"),
        Spec(title: "E2E Antigravity agent", workspace: "E2ELegal", status: "working", command: "exec sleep 600"),
        Spec(title: "E2E Vite server", workspace: "E2EFront", status: "waiting_for_input", command: "exec sleep 600"),
        Spec(title: "E2E front shell", workspace: "E2EFront", status: nil, command: "exec tail -f \(log)"),
    ]
    // A run that failed before its cleanup leaves its workspaces behind, and
    // creating one whose name is taken adds a number ("E2ELegal 2").
    func deleteOurWorkspaces() {
        _ = try? d.exec("\(ctl) workspace switch Default")
        for ws in (try? d.workspaceList()) ?? [] {
            guard let name = ws["name"] as? String, name.hasPrefix("E2ELegal") || name.hasPrefix("E2EFront") else { continue }
            _ = try? d.exec("\(ctl) workspace delete \"\(name)\"")
        }
    }
    deleteOurWorkspaces()
    _ = try d.exec("\(ctl) workspace create E2ELegal")
    _ = try d.exec("\(ctl) workspace create E2EFront")
    var panes: [String: String] = [:], pids: [String: String] = [:]
    var children = OwnedProcesses()
    var sidebarWasOpen = true
    defer {
        d.cleanupProblems.append(contentsOf: children.cleanUp())
        _ = try? d.exec("\(ctl) workspace switch Default")
        for pane in panes.values { _ = try? d.exec("\(ctl) close --target \(pane)") }
        deleteOurWorkspaces()
        if !sidebarWasOpen { d.key(Key.s, [.maskCommand, .maskAlternate]) }
    }
    for (i, spec) in specs.enumerated() {
        let pane = trimmed(try d.exec("\(ctl) tab-new --no-select"))
        guard !pane.isEmpty else { throw Failure("tab-new printed no pane id for \(spec.title)") }
        let pidFile = d.path("ws-visible-\(i).pid")
        _ = try d.exec("\(ctl) send \"sh -c 'echo \\$\\$ > \(pidFile); \(spec.command)'\" --target \(pane)")
        let child = trimmed(try d.file("ws-visible-\(i).pid"))
        pids[spec.title] = child
        try children.adopt(child, what: spec.title)
        _ = try d.exec("\(ctl) title \"\(spec.title)\" --target \(pane)")
        try d.exec("\(ctl) tree --json").write(toFile: d.path("ws-after-title-\(i).json"), atomically: true, encoding: .utf8)
        if let status = spec.status { _ = try d.exec("\(ctl) status set \(status) --target \(pane)") }
        if spec.workspace != "Default" {
            _ = try d.exec("\(ctl) workspace assign --workspace \(spec.workspace) --target \(pane)")
        }
        panes[spec.title] = pane
        try d.exec("\(ctl) tree --json").write(toFile: d.path("ws-after-assign-\(i).json"), atomically: true, encoding: .utf8)
    }
    // Room for the whole list: a row scrolled out of sight is not "shown".
    d.setPosition(CGPoint(x: 60, y: 40))
    d.setSize(CGSize(width: 1100, height: 900))
    // The sidebar, open in the window the user is in. Its visibility is
    // app-wide and kept, so it may be open already.
    d.activate()
    sidebarWasOpen = d.hasText(containing: "Sessions")
    if !sidebarWasOpen { d.key(Key.s, [.maskCommand, .maskAlternate]) }
    guard d.wait(for: { d.hasText(containing: "Sessions") }, timeout: 5) else {
        throw Failure("the session sidebar did not open (\(d.debugFocusState()))")
    }

    var windowsOf: [String: Set<CGWindowID>] = [:]
    func sidebarViewport() -> CGRect? {
        guard let window = d.activeOnScreenWindow(), let bounds = d.windowFrame(window),
              let sidebar = d.element(withIdentifier: "SessionSidebar", root: window),
              let scroll = d.descendants(of: sidebar, role: kAXScrollAreaRole as String)
                .compactMap({ d.axFrame($0) }).max(by: { $0.height < $1.height }) else { return nil }
        return scroll.intersection(bounds).intersection(CGDisplayBounds(CGMainDisplayID()))
    }
    func scrollSidebar(_ lines: Int32) throws {
        guard let clip = sidebarViewport(), clip.width > 10, clip.height > 10 else {
            throw Failure("no visible sidebar scroll viewport")
        }
        let point = CGPoint(x: clip.midX, y: clip.midY)
        guard d.topmostOwner(at: point) == d.pid else { throw Failure("sidebar wheel target is not the fixture's") }
        try d.requireAXOwnedTarget(at: point)
        guard let move = CGEvent(mouseEventSource: d.source, mouseType: .mouseMoved,
                                 mouseCursorPosition: point, mouseButton: .left),
              let wheel = CGEvent(scrollWheelEvent2Source: d.source, units: .line, wheelCount: 1,
                                  wheel1: lines, wheel2: 0, wheel3: 0) else { throw Failure("no sidebar wheel events") }
        move.post(tap: .cghidEventTap)
        try d.requireAXOwnedTarget(at: point)
        wheel.location = point
        wheel.post(tap: .cghidEventTap)
        usleep(150_000)
    }
    /// The element whose text is `text`, if it lies inside the on-screen window it belongs to.
    func visibleElement(_ text: String) -> (element: AXUIElement, frame: CGRect)? {
        for window in d.onScreenWindows() {
            guard let windowFrame = d.windowFrame(window) else { continue }
            for role in [kAXStaticTextRole as String, kAXButtonRole as String] {
                for element in d.descendants(of: window, role: role) {
                    let value: String? = d.attribute(element, kAXValueAttribute)
                    let title: String? = d.attribute(element, kAXTitleAttribute)
                    guard let shown = value ?? title, shown.caseInsensitiveCompare(text) == .orderedSame || shown.contains(text),
                          let posValue: AXValue = d.attribute(element, kAXPositionAttribute),
                          let sizeValue: AXValue = d.attribute(element, kAXSizeAttribute) else { continue }
                    var pos = CGPoint.zero, size = CGSize.zero
                    AXValueGetValue(posValue, .cgPoint, &pos)
                    AXValueGetValue(sizeValue, .cgSize, &size)
                    let frame = CGRect(origin: pos, size: size)
                    if size.width > 0, size.height > 0, windowFrame.contains(frame),
                       sidebarViewport()?.contains(frame) == true { return (element, frame) }
                }
            }
        }
        return nil
    }
    func check(_ workspace: String, how: String) throws {
        let current = try d.workspaceCurrent()?["name"] as? String
        guard current == workspace else { throw Failure("\(how): current workspace is \(current ?? "none"), not \(workspace)") }
        guard d.wait(for: { d.hasText(containing: "Sessions") }, timeout: 4) else {
            throw Failure("\(how): the session sidebar is not on screen after switching to \(workspace)")
        }
        // Each workspace keeps its own window frame: give this one the room too.
        if let window = d.activeOnScreenWindow() {
            d.setPosition(CGPoint(x: 60, y: 40), for: window)
            d.setSize(CGSize(width: 1100, height: 900), for: window)
            usleep(300_000)
        }
        // All sessions must stay in the list and be reachable on screen.
        // A LazyVStack does not materialize rows below the viewport; even
        // the requested 900 pt window is clamped on smaller displays.
        try scrollSidebar(50)
        for spec in specs {
            for _ in 0..<18 {
                if visibleElement(spec.title) != nil { break }
                try scrollSidebar(-4)
            }
            guard d.wait(for: { visibleElement(spec.title) != nil }, timeout: 4) else {
                let tree = try d.exec("\(ctl) tree --json")
                try tree.write(toFile: d.path("ws-visibility-failure.json"), atomically: true, encoding: .utf8)
                let id = panes[spec.title] ?? "missing"
                let parsed = try JSONSerialization.jsonObject(with: Data(tree.utf8)) as? [String: Any]
                let result = parsed?["result"] as? [String: Any]
                let windows = result?["windows"] as? [[String: Any]] ?? []
                let tab = windows.flatMap { $0["tabs"] as? [[String: Any]] ?? [] }.first {
                    ($0["panes"] as? [[String: Any]] ?? []).contains {
                        ($0["id"] as? String)?.lowercased() == id.lowercased()
                    }
                }
                let stableID = tab?["stableTabId"] as? String ?? "missing"
                let row = d.activeOnScreenWindow().flatMap {
                    d.element(withIdentifier: "session-tab-\(id.lowercased())", root: $0)
                        ?? d.element(withIdentifier: "session-tab-\(stableID)", root: $0)
                }
                let rowText = row.map { d.descendants(of: $0, role: kAXStaticTextRole as String).compactMap {
                    d.attribute($0, kAXValueAttribute) as String?
                } } ?? []
                let label = row.flatMap { d.attribute($0, kAXTitleAttribute) as String? }
                print("missing session pane=\(id), stableTabId=\(stableID), modelTitle=\(String(describing: tab?["title"])), exact row label=\(String(describing: label)), text=\(rowText), frame=\(String(describing: row.flatMap(d.axFrame))), viewport=\(String(describing: sidebarViewport()))")
                print("tab window titles: \(d.windows().map { (d.attribute($0, kAXTitleAttribute) as String?) ?? "?" })")
                throw Failure("\(how): the sidebar on screen does not show \(spec.title) (\(spec.workspace)) while in \(workspace); text=\(d.staticTexts()); window=\(String(describing: d.windowFrame()))")
            }
            guard let text = pids[spec.title], let pid = Int32(text),
                  let birth = children.birth(of: pid), children.identity(pid) == .running(birth: birth) else {
                throw Failure("\(how): the original process of \(spec.title) is no longer proved alive in \(workspace)")
            }
            if let status = spec.status, let pane = panes[spec.title] {
                let got = try d.exec("\(ctl) status get --target \(pane)")
                guard got.hasPrefix(status) else {
                    throw Failure("\(how): \(spec.title) lost its status \(status) after switching to \(workspace): \(trimmed(got))")
                }
            }
        }
        let tree = try d.exec("\(ctl) tree")
        for (title, pane) in panes where !tree.contains(String(pane.prefix(8))) {
            throw Failure("\(how): \(title)'s pane is missing from the tree in \(workspace)")
        }
        func titles(_ ids: Set<CGWindowID>) -> String {
            d.windows().compactMap { w -> String? in
                guard let id = d.windowID(for: w), ids.contains(id) else { return nil }
                return "\(id):\((d.attribute(w, kAXTitleAttribute) as String?) ?? "?")"
            }.joined(separator: ", ")
        }
        // Windows of other workspaces leave the screen; give a fade its time.
        var onScreen = d.onScreenWindowNumbers()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline,
              windowsOf.contains(where: { $0.key != workspace && !$0.value.isDisjoint(with: onScreen) }) {
            usleep(100_000)
            onScreen = d.onScreenWindowNumbers()
        }
        guard !onScreen.isEmpty else { throw Failure("\(how): no window of \(workspace) is on screen") }
        if let seen = windowsOf[workspace], seen != onScreen {
            throw Failure("\(how): \(workspace) came back with other windows on screen: [\(titles(onScreen))] vs [\(titles(seen))]")
        }
        for (other, theirs) in windowsOf where other != workspace && !theirs.isDisjoint(with: onScreen) {
            throw Failure("\(how): 3 s after switching to \(workspace), a window of \(other) is still on screen: on screen [\(titles(onScreen))], \(other) had [\(titles(theirs))]")
        }
        windowsOf[workspace] = onScreen
    }

    try check("Default", how: "start")
    for target in ["E2ELegal", "E2EFront", "Default", "E2EFront", "E2ELegal", "Default"] {
        _ = try d.exec("\(ctl) workspace switch \(target)")
        usleep(800_000)
        try check(target, how: "takoctl switch")
    }
    // A click on the workspace's header in the sidebar switches too.
    func clickSidebarText(_ text: String) throws {
        try scrollSidebar(50)
        for _ in 0..<18 {
            if visibleElement(text) != nil { break }
            try scrollSidebar(-4)
        }
        guard let (_, frame) = visibleElement(text) else { throw Failure("no \(text) header in the sidebar on screen") }
        try d.click(at: CGPoint(x: frame.midX, y: frame.midY))
    }
    for target in ["E2EFront", "E2ELegal", "Default"] {
        try clickSidebarText(target)
        guard d.wait(for: { (try? d.workspaceCurrent()?["name"] as? String) == target }, timeout: 4) else {
            throw Failure("clicking the \(target) header in the sidebar did not switch to it")
        }
        usleep(500_000)
        try check(target, how: "sidebar click")
    }

}
