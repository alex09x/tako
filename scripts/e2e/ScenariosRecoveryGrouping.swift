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

func retainOnlyPane(_ keptID: String, removing removedID: String, in d: Driver) throws {
    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    let layout = library.appendingPathComponent("Application Support/\(d.bundleID)/layout")
    let launchPath = layout.appendingPathComponent("launch.json")
    guard var launch = try JSONSerialization.jsonObject(with: Data(contentsOf: launchPath)) as? [String: Any],
          let generation = launch["journalGeneration"] as? NSNumber else { throw Failure("no layout generation") }
    let path = layout.appendingPathComponent("journal-\(generation.uint64Value).json")
    guard var journal = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any],
          var windows = journal["windows"] as? [[String: Any]], windows.count == 1,
          let tabs = windows[0]["tabs"] as? [Any], tabs.count == 2 else { throw Failure("expected one saved group with two tabs") }
    func containsPane(_ value: Any, id: String) -> Bool {
        if let text = value as? String { return text.lowercased() == id.lowercased() }
        if let list = value as? [Any] { return list.contains { containsPane($0, id: id) } }
        if let object = value as? [String: Any] { return object.values.contains { containsPane($0, id: id) } }
        return false
    }
    let kept = tabs.filter { containsPane($0, id: keptID) }
    guard kept.count == 1, tabs.contains(where: { containsPane($0, id: removedID) }) else { throw Failure("could not identify saved tabs") }
    windows[0]["tabs"] = kept
    windows[0]["selectedTab"] = 0
    journal["windows"] = windows
    try JSONSerialization.data(withJSONObject: journal).write(to: path)
    launch["state"] = "dirty"
    try JSONSerialization.data(withJSONObject: launch).write(to: launchPath)
}

func runCrossWindowWorkspaceMoveScenario(_ d: Driver) throws {
    d.quit()
    forgetLayout(d)
    try d.launch(config: "session-persistence = true\nwindow-save-state = always\nremote-control = on\n")
    let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
    guard let first = try d.focusedPaneId() else { throw Failure("no initial pane") }
    _ = try d.exec("\(ctl) workspace create MoveAcrossWindows")
    _ = try d.exec("\(ctl) workspace switch MoveAcrossWindows")
    var workspacePane: String?
    guard d.wait(for: { workspacePane = try? d.focusedPaneId(); return workspacePane != nil && workspacePane != first }, timeout: 10),
          let middle = workspacePane else { throw Failure("workspace pane did not open") }
    d.key(Key.n, [.maskCommand])
    var standalone: String?
    guard d.wait(for: { standalone = try? d.focusedPaneId(); return standalone != nil && standalone != first && standalone != middle }, timeout: 10),
          let moved = standalone else { throw Failure("standalone window did not open") }
    _ = try d.exec("\(ctl) title CrossWindowMove --target \(moved)")
    _ = try d.exec("\(ctl) send \"sh -c 'echo \\$\\$ > \(d.path("cross-window-pid")); exec sleep 600'\" --target \(moved)")
    guard let process = Int32(try d.file("cross-window-pid").trimmingCharacters(in: .whitespacesAndNewlines)), process > 0 else {
        throw Failure("no process in standalone window")
    }
    if !d.hasText(containing: "Sessions") { d.key(Key.s, [.maskCommand, .maskAlternate]) }
    guard d.wait(for: { d.hasText(containing: "CrossWindowMove") && d.hasText(containing: "DEFAULT") }, timeout: 10),
          let window = d.activeWindow() else { throw Failure("sidebar targets not found") }
    func center(_ text: String) throws -> CGPoint {
        guard let element = d.descendants(of: window, role: kAXStaticTextRole as String).first(where: {
            (d.attribute($0, kAXValueAttribute) as String?) == text
        }), let position: AXValue = d.attribute(element, kAXPositionAttribute),
              let sizeValue: AXValue = d.attribute(element, kAXSizeAttribute) else { throw Failure("no sidebar target: \(text)") }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(position, .cgPoint, &point); AXValueGetValue(sizeValue, .cgSize, &size)
        return CGPoint(x: point.x + size.width / 2, y: point.y + size.height / 2)
    }
    try d.drag(from: center("CrossWindowMove"), to: center("DEFAULT"), steps: 24)
    guard d.wait(for: {
        guard let raw = try? d.exec("\(ctl) tree --json"), let data = raw.data(using: .utf8),
              let outer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = outer["result"] as? [String: Any], let windows = result["windows"] as? [[String: Any]] else { return false }
        return windows.contains { window in
            let tabs = window["tabs"] as? [[String: Any]] ?? []
            let ids = tabs.flatMap { ($0["panes"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }
            return ids.contains(first) && ids.contains(middle) && ids.contains(moved)
        }
    }, timeout: 15), kill(process, 0) == 0 else { throw Failure("moving across window groups split the destination or ended the process") }
}

func runInactiveWorkspaceRecoveryScenario(_ d: Driver) throws {
    d.quit()
    forgetLayout(d)
    let config = "session-persistence = true\nwindow-save-state = always\nremote-control = on\n"
    try d.launch(config: config)
    let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
    guard let first = try d.focusedPaneId() else { throw Failure("no initial pane") }
    try d.run("sh -c 'echo $PPID > \(d.path("inactive-first-pid"))'")
    guard let firstPID = Int32(try d.file("inactive-first-pid").trimmingCharacters(in: .whitespacesAndNewlines)), firstPID > 0 else {
        throw Failure("no initial shell")
    }
    _ = try d.exec("\(ctl) workspace create InactiveRestore")
    _ = try d.exec("\(ctl) workspace switch InactiveRestore")
    var candidate: String?
    guard d.wait(for: { candidate = try? d.focusedPaneId(); return candidate != nil && candidate != first }, timeout: 10),
          let second = candidate else { throw Failure("no inactive workspace pane") }
    try d.run("sh -c 'echo $PPID > \(d.path("inactive-second-pid"))'")
    guard let secondPID = Int32(try d.file("inactive-second-pid").trimmingCharacters(in: .whitespacesAndNewlines)), secondPID > 0 else {
        throw Failure("no second shell")
    }
    _ = try d.exec("\(ctl) workspace switch Default")
    guard d.wait(for: { (try? d.focusedPaneId()) == first }, timeout: 10) else { throw Failure("default did not return") }
    try d.quitNormally()
    try retainOnlyPane(first, removing: second, in: d)
    try d.launch(config: config, settleTerminal: false)
    guard d.wait(for: { d.hasText(containing: "Session Recovery") }, timeout: 20) else { throw Failure("no recovery dialog") }
    try d.clickButton(titled: "Restore")
    guard d.wait(for: {
        guard let raw = try? d.exec("\(ctl) tree --json"), let data = raw.data(using: .utf8),
              let outer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = outer["result"] as? [String: Any], let windows = result["windows"] as? [[String: Any]] else { return false }
        return windows.contains { window in
            let tabs = window["tabs"] as? [[String: Any]] ?? []
            let ids = tabs.flatMap { ($0["panes"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }
            return ids.contains(first) && ids.contains(second)
        }
    }, timeout: 20), (try? d.focusedPaneId()) == first, d.onScreenWindows().count == 1,
          kill(firstPID, 0) == 0, kill(secondPID, 0) == 0 else {
        throw Failure("inactive recovery changed focus, split the group, or ended a shell")
    }
    _ = try d.exec("\(ctl) workspace switch InactiveRestore")
    guard d.wait(for: { (try? d.focusedPaneId()) == second }, timeout: 10), kill(secondPID, 0) == 0 else {
        throw Failure("the inactive session did not return to its workspace")
    }
}

func runAssignSelectedTabScenario(_ d: Driver) throws {
    d.quit()
    forgetLayout(d)
    try d.launch(config: "session-persistence = true\nwindow-save-state = always\nremote-control = on\n")
    let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
    guard let first = try d.focusedPaneId() else { throw Failure("no initial pane") }
    guard let firstTab = try d.workspaceCurrent()?["active_tab"] as? String else { throw Failure("no initial tab identity") }
    try d.run("sh -c 'echo $PPID > \(d.path("assign-first-pid"))'")
    guard let firstPID = Int32(try d.file("assign-first-pid").trimmingCharacters(in: .whitespacesAndNewlines)), firstPID > 0 else {
        throw Failure("no first shell PID")
    }
    let second = try d.exec("\(ctl) tab-new").trimmingCharacters(in: .whitespacesAndNewlines)
    guard second != first, d.wait(for: { (try? d.focusedPaneId()) == second }, timeout: 10) else {
        throw Failure("second tab did not become active")
    }
    try d.run("sh -c 'echo $PPID > \(d.path("assigned-shell-pid"))'")
    guard let shell = Int32(try d.file("assigned-shell-pid").trimmingCharacters(in: .whitespacesAndNewlines)), shell > 0 else {
        throw Failure("no shell PID")
    }
    _ = try d.exec("\(ctl) workspace create AssignDestination")
    _ = try d.exec("\(ctl) workspace assign --workspace AssignDestination --target \(second)")
    guard d.wait(for: { (try? d.focusedPaneId()) == first }, timeout: 10), kill(shell, 0) == 0 else {
        throw Failure("moving the selected tab did not reveal the remaining tab, or ended the moved shell")
    }
    _ = try d.exec("\(ctl) workspace switch AssignDestination")
    guard d.wait(for: { (try? d.focusedPaneId()) == second }, timeout: 10), kill(shell, 0) == 0 else {
        throw Failure("assigned tab did not reappear with its original shell")
    }
    _ = try d.exec("\(ctl) workspace assign --workspace AssignDestination --target \(first)")
    guard d.wait(for: { (try? d.workspaceCurrent()?["tabs"] as? [String])?.contains(firstTab) == true }, timeout: 10),
          (try? d.focusedPaneId()) == second, kill(shell, 0) == 0, kill(firstPID, 0) == 0 else {
        throw Failure("moving an inactive tab into the active workspace changed focus or ended a shell")
    }
}

func runIntentionalWindowsScenario(_ d: Driver) throws {
    d.quit()
    forgetLayout(d)
    let config = "session-persistence = true\nwindow-save-state = always\nremote-control = on\n"
    try d.launch(config: config)
    let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
    guard let first = try d.focusedPaneId() else { throw Failure("no initial pane") }
    try d.run("sh -c 'echo $PPID > \(d.path("intentional-first-pid"))'")
    guard let firstPID = Int32(try d.file("intentional-first-pid").trimmingCharacters(in: .whitespacesAndNewlines)), firstPID > 0 else {
        throw Failure("no first shell")
    }
    d.key(Key.n, [.maskCommand])
    var other: String?
    guard d.wait(for: { other = try? d.focusedPaneId(); return other != nil && other != first }, timeout: 10),
          let second = other else { throw Failure("second window did not open") }
    try d.run("sh -c 'echo $PPID > \(d.path("intentional-second-pid"))'")
    guard let secondPID = Int32(try d.file("intentional-second-pid").trimmingCharacters(in: .whitespacesAndNewlines)), secondPID > 0 else {
        throw Failure("no second shell")
    }
    try d.quitNormally()
    try d.launch(config: config, settleTerminal: false)
    func separate() -> Bool {
        guard let raw = try? d.exec("\(ctl) tree --json"), let data = raw.data(using: .utf8),
              let outer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = outer["result"] as? [String: Any], let windows = result["windows"] as? [[String: Any]] else { return false }
        let groups: [[String]] = windows.map { window in
            let tabs = window["tabs"] as? [[String: Any]] ?? []
            return tabs.flatMap { ($0["panes"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }
        }
        return groups.contains { $0.contains(first) && !$0.contains(second) }
            && groups.contains { $0.contains(second) && !$0.contains(first) }
    }
    guard d.wait(for: separate, timeout: 20), kill(firstPID, 0) == 0, kill(secondPID, 0) == 0 else {
        throw Failure("intentionally separate windows did not restore independently")
    }
}

func runLegacyWindowChoiceScenario(_ d: Driver) throws {
    d.quit()
    forgetLayout(d)
    let config = "session-persistence = true\nwindow-save-state = always\nremote-control = on\n"
    try d.launch(config: config)
    let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
    guard let first = try d.focusedPaneId() else { throw Failure("no first pane") }
    try d.run("sh -c 'echo $PPID > \(d.path("legacy-choice-first"))'")
    guard let firstPID = Int32(try d.file("legacy-choice-first").trimmingCharacters(in: .whitespacesAndNewlines)), firstPID > 0 else {
        throw Failure("no first process")
    }
    d.key(Key.n, [.maskCommand])
    var candidate: String?
    guard d.wait(for: { candidate = try? d.focusedPaneId(); return candidate != nil && candidate != first }, timeout: 10),
          let second = candidate, let secondID = UUID(uuidString: second) else { throw Failure("no second window") }
    try d.run("sh -c 'echo $PPID > \(d.path("legacy-choice-second"))'")
    guard let secondPID = Int32(try d.file("legacy-choice-second").trimmingCharacters(in: .whitespacesAndNewlines)), secondPID > 0 else {
        throw Failure("no second process")
    }
    try d.quitNormally()
    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    let support = library.appendingPathComponent("Application Support/\(d.bundleID)")
    let layout = support.appendingPathComponent("layout")
    let launchPath = layout.appendingPathComponent("launch.json")
    guard var launch = try JSONSerialization.jsonObject(with: Data(contentsOf: launchPath)) as? [String: Any],
          let generation = launch["journalGeneration"] as? NSNumber else { throw Failure("no launch record") }
    let journalPath = layout.appendingPathComponent("journal-\(generation.uint64Value).json")
    guard var journal = try JSONSerialization.jsonObject(with: Data(contentsOf: journalPath)) as? [String: Any],
          let windows = journal["windows"] as? [[String: Any]], windows.count == 2 else { throw Failure("expected two saved windows") }
    func containsPane(_ value: Any, id: String) -> Bool {
        if let text = value as? String { return text.lowercased() == id.lowercased() }
        if let list = value as? [Any] { return list.contains { containsPane($0, id: id) } }
        if let object = value as? [String: Any] { return object.values.contains { containsPane($0, id: id) } }
        return false
    }
    let kept = windows.filter { containsPane($0, id: first) }
    guard kept.count == 1, windows.contains(where: { containsPane($0, id: second) }) else { throw Failure("cannot identify the saved windows") }
    journal["windows"] = kept
    try JSONSerialization.data(withJSONObject: journal).write(to: journalPath)
    launch["state"] = "dirty"
    try JSONSerialization.data(withJSONObject: launch).write(to: launchPath)
    let recordPath = support.appendingPathComponent("SessionRecords/\(secondID.uuidString).session")
    guard var record = try JSONSerialization.jsonObject(with: Data(contentsOf: recordPath)) as? [String: Any] else { throw Failure("no session record") }
    record.removeValue(forKey: "windowTabIdentifiers")
    try JSONSerialization.data(withJSONObject: record).write(to: recordPath)
    try d.launch(config: config, settleTerminal: false)
    guard d.wait(for: { d.hasText(containing: "Session Recovery") }, timeout: 20) else { throw Failure("no recovery dialog") }
    try d.clickButton(titled: "Restore")
    guard d.wait(for: { d.hasText(containing: "Choose Window") }, timeout: 10) else { throw Failure("legacy placement was guessed") }
    try d.clickButton(titled: "Next")
    guard d.wait(for: { d.hasText(containing: "New Window") }, timeout: 10) else { throw Failure("no separate window option") }
    try d.clickButton(titled: "New Window")
    guard d.wait(for: {
        guard let raw = try? d.exec("\(ctl) tree --json"), let data = raw.data(using: .utf8),
              let outer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = outer["result"] as? [String: Any], let windows = result["windows"] as? [[String: Any]] else { return false }
        let groups = windows.map { window in
            (window["tabs"] as? [[String: Any]] ?? []).flatMap { ($0["panes"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }
        }
        return groups.contains { $0.contains(first) && !$0.contains(second) }
            && groups.contains { $0.contains(second) && !$0.contains(first) }
    }, timeout: 20), kill(firstPID, 0) == 0, kill(secondPID, 0) == 0 else {
        throw Failure("the explicit separate-window choice did not preserve both sessions")
    }
}

func runTaskWorkspaceGroupingScenario(_ d: Driver) throws {
    d.quit()
    forgetLayout(d)
    let config = "session-persistence = true\nwindow-save-state = always\nremote-control = on\n"
    try d.launch(config: config)
    let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
    guard let first = try d.focusedPaneId() else { throw Failure("no initial pane") }
    let repo = d.work.appendingPathComponent("task-repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    _ = try d.exec("git -C \(repo.path) init -q -b main")
    _ = try d.exec("git -C \(repo.path) config user.name 'Tako Test'")
    _ = try d.exec("git -C \(repo.path) config user.email test@tako.local")
    try Data("fixture\n".utf8).write(to: repo.appendingPathComponent("fixture"))
    _ = try d.exec("git -C \(repo.path) add fixture")
    _ = try d.exec("git -C \(repo.path) commit -qm initial")
    do {
        _ = try d.exec("\(ctl) task create Grouping --path \(repo.path) --target workspace")
    } catch {
        let running = d.running().contains { $0.processIdentifier == d.pid }
        let tree = (try? d.exec("\(ctl) tree --json")) ?? "unavailable"
        let worktrees = (try? d.exec("git -C \(repo.path) worktree list")) ?? "unavailable"
        throw Failure("task create failed: \(error); app running=\(running), tree=\(tree), worktrees=\(worktrees)")
    }
    guard d.wait(for: { (try? d.workspaceCurrent()?["name"] as? String) == "Task: Grouping" }, timeout: 15) else {
        throw Failure("task workspace did not open")
    }
    let raw = try d.exec("\(ctl) tree --json")
    guard let outer = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
          let result = outer["result"] as? [String: Any], let windows = result["windows"] as? [[String: Any]],
          windows.count == 1, let tabs = windows[0]["tabs"] as? [[String: Any]], tabs.count == 2 else {
        throw Failure("task workspace created an extra blank tab or separate window")
    }
    let ids = tabs.flatMap { ($0["panes"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }
    guard ids.contains(first), Set(ids).count == 2 else { throw Failure("task workspace did not preserve the original pane") }
}

func runEmptyWorkspaceGroupingScenario(_ d: Driver) throws {
    d.quit()
    forgetLayout(d)
    let config = "session-persistence = true\nwindow-save-state = always\nremote-control = on\n"
    try d.launch(config: config)
    let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
    guard let first = try d.focusedPaneId() else { throw Failure("no initial pane") }
    try d.run("sh -c 'echo $PPID > \(d.path("empty-ws-first-pid"))'")
    guard let firstPID = Int32(try d.file("empty-ws-first-pid").trimmingCharacters(in: .whitespacesAndNewlines)), firstPID > 0 else {
        throw Failure("no first shell")
    }
    _ = try d.exec("\(ctl) workspace create EmptyGroupTest")
    _ = try d.exec("\(ctl) workspace switch EmptyGroupTest")
    var second: String?
    guard d.wait(for: {
        second = try? d.focusedPaneId()
        return second != nil && second != first
    }, timeout: 15), let second else { throw Failure("empty workspace did not open its first pane") }
    try d.run("sh -c 'echo $PPID > \(d.path("empty-ws-second-pid"))'")
    guard let secondPID = Int32(try d.file("empty-ws-second-pid").trimmingCharacters(in: .whitespacesAndNewlines)), secondPID > 0 else {
        throw Failure("no second shell")
    }
    let raw = try d.exec("\(ctl) tree --json")
    guard let outer = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
          let result = outer["result"] as? [String: Any], let windows = result["windows"] as? [[String: Any]],
          windows.contains(where: { window in
              let tabs = window["tabs"] as? [[String: Any]] ?? []
              let ids = tabs.flatMap { ($0["panes"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }
              return ids.contains(first) && ids.contains(second)
          }), kill(firstPID, 0) == 0, kill(secondPID, 0) == 0 else {
        throw Failure("switching to an empty workspace created a separate window group or ended a shell")
    }
}

func runPartialLayoutGroupingScenario(_ d: Driver) throws {
    d.quit()
    forgetLayout(d)
    let config = "session-persistence = true\nwindow-save-state = always\nremote-control = on\n"
    try d.launch(config: config)
    let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
    guard let first = try d.focusedPaneId() else { throw Failure("no first pane") }
    try d.run("sh -c 'echo $PPID > \(d.path("group-first-pid"))'")
    let firstPID = try d.file("group-first-pid").trimmingCharacters(in: .whitespacesAndNewlines)
    let second = try d.exec("\(ctl) tab-new").trimmingCharacters(in: .whitespacesAndNewlines)
    guard second != first, d.wait(for: { (try? d.focusedPaneId()) == second }, timeout: 10) else {
        throw Failure("the second tab did not open")
    }
    try d.run("sh -c 'echo $PPID > \(d.path("group-second-pid"))'")
    let secondPID = try d.file("group-second-pid").trimmingCharacters(in: .whitespacesAndNewlines)
    try d.quitNormally()
    try retainOnlyPane(first, removing: second, in: d)
    try d.launch(config: config, settleTerminal: false)
    guard d.wait(for: { d.hasText(containing: "Session Recovery") }, timeout: 20) else { throw Failure("no recovery dialog") }
    try d.clickButton(titled: "Restore")
    guard d.wait(for: {
        guard let raw = try? d.exec("\(ctl) tree --json"), let data = raw.data(using: .utf8),
              let outer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = outer["result"] as? [String: Any], let windows = result["windows"] as? [[String: Any]] else { return false }
        return windows.contains { window in
            let tabs = window["tabs"] as? [[String: Any]] ?? []
            let ids = tabs.flatMap { ($0["panes"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }
            return ids.contains(first) && ids.contains(second)
        }
    }, timeout: 20) else { throw Failure("partial recovery split two original tabs into different windows") }
    guard let pid1 = Int32(firstPID), pid1 > 0, let pid2 = Int32(secondPID), pid2 > 0,
          kill(pid1, 0) == 0, kill(pid2, 0) == 0 else { throw Failure("recovery ended an original shell") }
}
