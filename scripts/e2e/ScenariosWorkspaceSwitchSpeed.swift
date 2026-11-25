/*
 * tako — Switching workspaces through their current desktop controls
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import ApplicationServices
import Foundation

func runWorkspaceSwitchSpeedScenario(_ d: Driver) throws {
    let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
    _ = try? d.exec("\(ctl) workspace switch Default")
    for ws in (try? d.workspaceList()) ?? [] {
        if let name = ws["name"] as? String, name.hasPrefix("E2ESpeed") { _ = try? d.exec("\(ctl) workspace delete \"\(name)\"") }
    }
    _ = try d.exec("\(ctl) workspace create E2ESpeed")
    defer {
        _ = try? d.exec("\(ctl) workspace switch Default")
        _ = try? d.exec("\(ctl) workspace delete E2ESpeed")
    }
    // The first switch to a workspace with no window opens one of its own.
    _ = try d.exec("\(ctl) workspace switch E2ESpeed")
    guard d.wait(for: { (try? d.workspaceCurrent()?["name"] as? String) == "E2ESpeed" }, timeout: 5) else {
        throw Failure("the switch to E2ESpeed never happened")
    }
    usleep(1_500_000)
    let speedWindows = d.onScreenWindowNumbers()
    _ = try d.exec("\(ctl) workspace switch Default")
    usleep(1_500_000)
    let defaultWindows = d.onScreenWindowNumbers()
    guard !speedWindows.isEmpty, !defaultWindows.isEmpty, speedWindows.isDisjoint(with: defaultWindows) else {
        throw Failure("the two workspaces do not show windows of their own: \(speedWindows) vs \(defaultWindows)")
    }
    var timings: [String] = []
    var slowest = 0.0
    for (i, target) in ["E2ESpeed", "Default", "E2ESpeed", "Default", "E2ESpeed", "Default"].enumerated() {
        let want = target == "E2ESpeed" ? speedWindows : defaultWindows
        let started = Date()
        _ = try d.exec("\(ctl) workspace switch \(target)")
        let answered = Date().timeIntervalSince(started)
        guard d.wait(for: { d.onScreenWindowNumbers() == want }, timeout: 5) else {
            throw Failure("switch \(i) to \(target): its window never came on screen alone (\(d.onScreenWindowNumbers()) vs \(want))")
        }
        let shown = Date().timeIntervalSince(started)
        slowest = max(slowest, shown)
        timings.append(String(format: "%@ answered %.0f ms, on screen %.0f ms", target, answered * 1000, shown * 1000))
        usleep(300_000)
    }
    // Measure the sidebar click from mouse-down to the expected window set
    // appearing alone on screen. Log the ownership checks before the click
    // and the takoctl verification afterward separately.
    for target in ["E2ESpeed", "Default", "E2ESpeed", "Default"] {
        let want = target == "E2ESpeed" ? speedWindows : defaultWindows
        guard let window = d.activeOnScreenWindow(),
              let header = d.element(withIdentifier: "SessionSidebarWorkspace-\(target)", root: window),
              let frame = d.axFrame(header) else { throw Failure("no visible \(target) workspace header") }
        let harness = ProcessInfo.processInfo.systemUptime
        let pressed = try d.postClick(at: CGPoint(x: frame.midX, y: frame.midY))
        var visible: TimeInterval?
        while ProcessInfo.processInfo.systemUptime - pressed < 5 {
            if d.onScreenWindowNumbers() == want { visible = ProcessInfo.processInfo.systemUptime; break }
            usleep(5_000)
        }
        guard let visible else {
            throw Failure("sidebar switch to \(target): its window never came on screen alone (\(d.onScreenWindowNumbers()) vs \(want))")
        }
        let current = try d.workspaceCurrent()?["name"] as? String
        let verified = ProcessInfo.processInfo.systemUptime
        guard current == target else {
            throw Failure("sidebar switch to \(target) showed its windows but takoctl reports \(current ?? "nil")")
        }
        let shown = visible - pressed
        slowest = max(slowest, shown)
        timings.append(String(format: "sidebar %@ on screen %.0f ms (checks %.0f, verify %.0f, harness %.0f)", target,
                              shown * 1000, (pressed - harness) * 1000, (verified - visible) * 1000, (verified - harness) * 1000))
        usleep(300_000)
    }
    // The current application Workspace menu remains usable. The old
    // tab-bar pill's click-to-toggle contract is retired with that UI.
    d.activate()
    try d.clickWorkspacePill(in: d.activeOnScreenWindow())
    guard d.wait(for: { d.openMenuItem(titled: "E2ESpeed") != nil }, timeout: 3) else {
        throw Failure("the application Workspace menu did not open")
    }
    d.key(Key.escape)
    guard d.wait(for: { d.openMenuItem(titled: "E2ESpeed") == nil }, timeout: 2) else {
        throw Failure("Escape did not close the application Workspace menu")
    }
    // Timings are information, not a gate: speed is profiled by hand.
    print("[timing] workspace switch: " + timings.joined(separator: "; "))
    print(String(format: "[timing] workspace switch: slowest %.0f ms", slowest * 1000))
}
