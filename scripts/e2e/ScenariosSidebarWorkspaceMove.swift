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
