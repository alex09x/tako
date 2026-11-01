/*
 * tako — Terminal emulator
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

func runSidebarWorkspaceMoveScenario(_ d: Driver) throws {
    d.quit()
    forgetLayout(d)
    try d.launch(config: "session-persistence = true\nwindow-save-state = always\nremote-control = on\n")
    guard let pane = try d.focusedPaneId() else { throw Failure("no focused pane") }
    try d.run("sh -c 'printf \"\\033]0;MoveWitness\\007\"; echo $$ > \(d.path("move-witness-pid")); exec sleep 600'")
    guard let process = Int32(try d.file("move-witness-pid").trimmingCharacters(in: .whitespacesAndNewlines)), process > 0 else {
        throw Failure("test process did not start")
    }
    let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
    _ = try d.exec("\(ctl) workspace create DragDestination")
    let alternatePane = try d.exec("\(ctl) tab-new").trimmingCharacters(in: .whitespacesAndNewlines)
    guard alternatePane != pane, d.wait(for: { (try? d.focusedPaneId()) == alternatePane }, timeout: 10) else {
        throw Failure("could not select a different tab before dragging")
    }
    if !d.hasText(containing: "Sessions") { d.key(Key.s, [.maskCommand, .maskAlternate]) }
    guard d.wait(for: { d.hasText(containing: "MoveWitness") && d.hasText(containing: "DRAGDESTINATION") }, timeout: 10) else {
        throw Failure("sidebar did not show the session and destination")
    }
    func textElement(_ text: String) throws -> AXUIElement {
        guard let window = d.activeWindow(), let element = d.descendants(of: window, role: kAXStaticTextRole as String).first(where: {
            (d.attribute($0, kAXValueAttribute) as String?)?.contains(text) == true
        }) else { throw Failure("sidebar text not found: \(text)") }
        return element
    }
    func center(_ element: AXUIElement) throws -> CGPoint {
        guard let point: AXValue = d.attribute(element, kAXPositionAttribute),
              let extent: AXValue = d.attribute(element, kAXSizeAttribute) else { throw Failure("no accessibility frame") }
        var position = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(point, .cgPoint, &position)
        AXValueGetValue(extent, .cgSize, &size)
        return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
    }
    func contextClick(_ point: CGPoint) {
        CGEvent(mouseEventSource: d.source, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: d.source, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
    }
    let start = try center(textElement("MoveWitness")), end = try center(textElement("DRAGDESTINATION"))
    try d.drag(from: start, to: end, steps: 24)
    guard d.wait(for: { (try? d.workspaceCurrent()?["name"] as? String) == "DragDestination" }, timeout: 10) else {
        throw Failure("drag did not move the tab: start=\(start), end=\(end), sidebar=\(d.staticTexts()), workspace=\((try? d.workspaceCurrent()) ?? [:])")
    }
    guard kill(process, 0) == 0, (try? d.focusedPaneId()) == pane else {
        throw Failure("drag replaced the process or selected a different pane")
    }

    let point = try center(textElement("MoveWitness"))
    contextClick(point)
    guard d.wait(for: { d.openMenuItem(titled: "Move to Workspace") != nil }, timeout: 5),
          let submenu = d.openMenuItem(titled: "Move to Workspace") else { throw Failure("no move-to-workspace context menu") }
    d.press(submenu)
    try d.clickOpenMenuItem(titled: "Default")
    guard d.wait(for: { (try? d.workspaceCurrent()?["name"] as? String) == "Default" }, timeout: 10),
          kill(process, 0) == 0, (try? d.focusedPaneId()) == pane else {
        throw Failure("context-menu move did not preserve the session")
    }

    // A standalone window can join the current tab bar without restarting it.
    d.key(Key.n, [.maskCommand])
    var otherPane: String?
    guard d.wait(for: {
        otherPane = try? d.focusedPaneId()
        return otherPane != nil && otherPane != pane
    }, timeout: 10), let other = otherPane else { throw Failure("second window did not open") }
    _ = try d.exec("\(ctl) title SecondWindow --target \(other)")
    _ = try d.exec("\(ctl) send \"sh -c 'echo \\$\\$ > \(d.path("second-window-pid")); exec sleep 600'\" --target \(other)")
    guard let second = Int32(try d.file("second-window-pid").trimmingCharacters(in: .whitespacesAndNewlines)), second > 0 else {
        throw Failure("second-window process did not start")
    }
    _ = try d.exec("\(ctl) focus --target \(pane)")
    if !d.hasText(containing: "Sessions") { d.key(Key.s, [.maskCommand, .maskAlternate]) }
    guard d.wait(for: { d.hasText(containing: "SecondWindow") }, timeout: 10) else {
        throw Failure("the separate window was missing from the sidebar")
    }
    contextClick(try center(textElement("SecondWindow")))
    try d.clickOpenMenuItem(titled: "Move to This Window")
    func oneWindowContains(_ expected: [String]) -> Bool {
        guard let json = try? d.exec("\(ctl) tree --json"), let data = json.data(using: .utf8),
              let outer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        let result = (outer["result"] as? [String: Any]) ?? outer
        guard let windows = result["windows"] as? [[String: Any]] else { return false }
        return windows.contains { window in
            let tabs = window["tabs"] as? [[String: Any]] ?? []
            let ids = tabs.flatMap { ($0["panes"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }
            return expected.allSatisfy { ids.contains($0) }
        }
    }
    guard d.wait(for: { oneWindowContains([pane, other]) }, timeout: 10), kill(process, 0) == 0, kill(second, 0) == 0 else {
        throw Failure("bringing the window into the tab bar did not preserve both processes")
    }

    // The inverse arrangement is common too: the current window is alone,
    // while the selected sidebar session already belongs to a tab group.
    d.key(Key.n, [.maskCommand])
    var standalone: String?
    guard d.wait(for: {
        standalone = try? d.focusedPaneId()
        return standalone != nil && standalone != pane && standalone != other
    }, timeout: 10), let third = standalone else { throw Failure("standalone current window did not open") }
    _ = try d.exec("\(ctl) send \"sh -c 'echo \\$\\$ > \(d.path("standalone-pid")); exec sleep 600'\" --target \(third)")
    guard let thirdPID = Int32(try d.file("standalone-pid").trimmingCharacters(in: .whitespacesAndNewlines)), thirdPID > 0 else {
        throw Failure("standalone process did not start")
    }
    if !d.hasText(containing: "Sessions") { d.key(Key.s, [.maskCommand, .maskAlternate]) }
    guard d.wait(for: { d.hasText(containing: "MoveWitness") }, timeout: 10) else {
        throw Failure("existing tab group was missing from the sidebar")
    }
    contextClick(try center(textElement("MoveWitness")))
    try d.clickOpenMenuItem(titled: "Move to This Window")
    guard d.wait(for: { oneWindowContains([pane, other, third]) }, timeout: 10),
          kill(process, 0) == 0, kill(second, 0) == 0, kill(thirdPID, 0) == 0 else {
        throw Failure("joining the standalone current window did not preserve all three processes")
    }
}

/// Exercise a real resize, scroll and move with more rows than fit on screen.
func runSidebarLongListScenario(_ d: Driver) throws {
    d.quit()
    forgetLayout(d)
    try d.launch(config: "session-persistence = true\nwindow-save-state = always\nremote-control = on\n")
    d.setPosition(CGPoint(x: 60, y: 40))
    d.setSize(CGSize(width: 1000, height: 600))
    let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
    _ = try d.exec("\(ctl) workspace create ScrollDestination")
    var lastPane = ""
    for i in 0..<15 {
        let pane = try d.exec("\(ctl) tab-new --no-select").trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try d.exec("\(ctl) title ListItem\(String(format: "%02d", i)) --target \(pane)")
        lastPane = pane
    }
    if !d.hasText(containing: "Sessions") { d.key(Key.s, [.maskCommand, .maskAlternate]) }
    guard d.wait(for: { d.hasText(containing: "ListItem00") }, timeout: 10),
          let window = d.activeWindow() else { throw Failure("long sidebar did not appear") }

    func frame(_ element: AXUIElement) -> CGRect? {
        guard let pos: AXValue = d.attribute(element, kAXPositionAttribute),
              let size: AXValue = d.attribute(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(pos, .cgPoint, &point)
        AXValueGetValue(size, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }
    func element(_ role: String, containing text: String) -> AXUIElement? {
        d.descendants(of: window, role: role).first {
            let value: String? = d.attribute($0, kAXValueAttribute)
            let label: String? = d.attribute($0, kAXDescriptionAttribute)
            let title: String? = d.attribute($0, kAXTitleAttribute)
            return value?.contains(text) == true || label?.contains(text) == true || title?.contains(text) == true
        }
    }
    guard let splitter = element(kAXSplitterRole as String, containing: "Resize session sidebar"),
          let gripBefore = frame(splitter) else { throw Failure("resize grip missing from accessibility") }
    let start = CGPoint(x: gripBefore.midX, y: gripBefore.midY)
    CGEvent(mouseEventSource: d.source, mouseType: .mouseMoved,
            mouseCursorPosition: start, mouseButton: .left)?.post(tap: .cghidEventTap)
    try d.drag(from: start, to: CGPoint(x: start.x + 55, y: start.y), steps: 16)
    guard d.wait(for: { (frame(splitter)?.midX ?? start.x) > start.x + 35 }, timeout: 5) else {
        throw Failure("dragging the sidebar edge did not resize it")
    }

    guard let scroll = d.descendants(of: window, role: kAXScrollAreaRole as String).first,
          let viewport = frame(scroll) else { throw Failure("sidebar scroll area missing") }
    let point = CGPoint(x: viewport.midX, y: viewport.midY)
    CGEvent(mouseEventSource: d.source, mouseType: .mouseMoved,
            mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    for _ in 0..<6 {
        let wheel = CGEvent(scrollWheelEvent2Source: d.source, units: .line, wheelCount: 1, wheel1: -8, wheel2: 0, wheel3: 0)
        wheel?.location = point
        wheel?.post(tap: .cghidEventTap)
        usleep(120_000)
    }
    func visible(_ text: String) -> CGRect? {
        guard let item = element(kAXStaticTextRole as String, containing: text),
              let rect = frame(item), viewport.contains(CGPoint(x: rect.midX, y: rect.midY)) else { return nil }
        return rect
    }
    guard d.wait(for: { visible("ListItem14") != nil && visible("SCROLLDESTINATION") != nil }, timeout: 8) else {
        throw Failure("scrolling a long sidebar did not reveal the last row and workspace: \(d.staticTexts())")
    }
    guard let scrollbar = d.descendants(of: scroll, role: kAXScrollBarRole as String).first,
          let bar = frame(scrollbar) else { throw Failure("sidebar scrollbar missing from accessibility") }
    try d.drag(from: CGPoint(x: bar.midX, y: bar.maxY - 8),
               to: CGPoint(x: bar.midX, y: bar.minY + 8), steps: 24)
    guard d.wait(for: { visible("ListItem00") != nil }, timeout: 8) else {
        throw Failure("dragging the scrollbar thumb did not scroll to the start")
    }
    CGEvent(mouseEventSource: d.source, mouseType: .mouseMoved,
            mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    for _ in 0..<6 {
        let wheel = CGEvent(scrollWheelEvent2Source: d.source, units: .line, wheelCount: 1, wheel1: -8, wheel2: 0, wheel3: 0)
        wheel?.location = point
        wheel?.post(tap: .cghidEventTap)
        usleep(120_000)
    }
    guard d.wait(for: { visible("ListItem14") != nil && visible("SCROLLDESTINATION") != nil }, timeout: 8),
          let row = visible("ListItem14"), let destination = visible("SCROLLDESTINATION") else {
        throw Failure("the last row and destination did not return after scrolling")
    }
    let pidBefore = try d.exec("\(ctl) tree --json")
    let dragStart = CGPoint(x: row.midX, y: row.midY)
    let dragEnd = CGPoint(x: destination.midX, y: destination.midY)
    guard d.topmostOwner(at: dragStart) == d.pid else { throw Failure("the test window does not own the drag start") }
    CGEvent(mouseEventSource: d.source, mouseType: .mouseMoved,
            mouseCursorPosition: dragStart, mouseButton: .left)?.post(tap: .cghidEventTap)
    CGEvent(mouseEventSource: d.source, mouseType: .leftMouseDown,
            mouseCursorPosition: dragStart, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(100_000)
    for i in 1...24 {
        let p = CGFloat(i) / 24
        let point = CGPoint(x: dragStart.x + (dragEnd.x - dragStart.x) * p,
                            y: dragStart.y + (dragEnd.y - dragStart.y) * p)
        CGEvent(mouseEventSource: d.source, mouseType: .leftMouseDragged,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(35_000)
    }
    usleep(250_000)
    CGEvent(mouseEventSource: d.source, mouseType: .leftMouseUp,
            mouseCursorPosition: dragEnd, mouseButton: .left)?.post(tap: .cghidEventTap)
    guard d.wait(for: { (try? d.workspaceCurrent()?["name"] as? String) == "ScrollDestination" }, timeout: 10) else {
        throw Failure("dragging the last visible row to the workspace failed")
    }
    let pidAfter = try d.exec("\(ctl) tree --json")
    func panePID(_ json: String) -> Int? {
        guard let data = json.data(using: .utf8), let outer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = outer["result"] as? [String: Any], let windows = result["windows"] as? [[String: Any]] else { return nil }
        return windows.flatMap { ($0["tabs"] as? [[String: Any]]) ?? [] }
            .flatMap { ($0["panes"] as? [[String: Any]]) ?? [] }
            .first(where: { $0["id"] as? String == lastPane })?["pid"] as? Int
    }
    guard let before = panePID(pidBefore), before == panePID(pidAfter), kill(Int32(before), 0) == 0 else {
        throw Failure("the moved long-list session did not keep its process")
    }
}
