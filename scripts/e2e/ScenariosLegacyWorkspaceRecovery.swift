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
import Foundation

func runLegacyWorkspaceChoiceScenario(_ d: Driver) throws {
    d.quit()
    forgetLayout(d)
    let config = "session-persistence = true\nwindow-save-state = always\nremote-control = on\n"
    try d.launch(config: config)
    let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
    guard let first = try d.focusedPaneId() else { throw Failure("no default pane") }
    _ = try d.exec("\(ctl) workspace create LegacyDestination")
    _ = try d.exec("\(ctl) workspace switch LegacyDestination")
    var orphan: String?
    guard d.wait(for: { orphan = try? d.focusedPaneId(); return orphan != nil && orphan != first }, timeout: 10),
          let second = orphan, let id = UUID(uuidString: second) else { throw Failure("no second workspace pane") }
    try d.run("sh -c 'echo $PPID > \(d.path("legacy-workspace-pid"))'")
    guard let shell = Int32(try d.file("legacy-workspace-pid").trimmingCharacters(in: .whitespacesAndNewlines)), shell > 0 else {
        throw Failure("no second shell")
    }
    _ = try d.exec("\(ctl) workspace switch Default")
    guard d.wait(for: { (try? d.focusedPaneId()) == first }, timeout: 10) else { throw Failure("default did not return") }
    try d.quitNormally()
    try retainOnlyPane(first, removing: second, in: d)
    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    let recordPath = library.appendingPathComponent("Application Support/\(d.bundleID)/SessionRecords/\(id.uuidString).session")
    guard var record = try JSONSerialization.jsonObject(with: Data(contentsOf: recordPath)) as? [String: Any] else { throw Failure("no session record") }
    record.removeValue(forKey: "workspaceID")
    record.removeValue(forKey: "windowTabIdentifiers")
    try JSONSerialization.data(withJSONObject: record).write(to: recordPath)
    try d.launch(config: config, settleTerminal: false)
    guard d.wait(for: { d.hasText(containing: "Session Recovery") }, timeout: 20) else { throw Failure("no recovery dialog") }
    try d.clickButton(titled: "Restore")
    guard d.wait(for: { d.hasText(containing: "Choose Workspace") }, timeout: 10) else {
        throw Failure("unknown legacy workspace was assigned without asking")
    }
    try d.clickButton(titled: "Next")
    guard d.wait(for: { d.hasText(containing: "Choose Workspace") }, timeout: 5) else { throw Failure("no second workspace choice") }
    try d.clickButton(titled: "Use This")
    guard d.wait(for: { d.hasText(containing: "Choose Window") }, timeout: 10) else { throw Failure("unknown window was assigned without asking") }
    try d.clickButton(titled: "Use This")
    guard d.wait(for: {
        guard let raw = try? d.exec("\(ctl) workspace list --json"), let data = raw.data(using: .utf8),
              let outer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = outer["result"] as? [String: Any], let workspaces = result["workspaces"] as? [[String: Any]],
              let target = workspaces.first(where: { $0["name"] as? String == "LegacyDestination" }) else { return false }
        guard !(target["tabs"] as? [String] ?? []).isEmpty,
              let tree = try? d.exec("\(ctl) tree --json") else { return false }
        return tree.lowercased().contains(second.lowercased())
    }, timeout: 20), (try? d.focusedPaneId()) == first, kill(shell, 0) == 0 else {
        throw Failure("legacy recovery lost its selected workspace or shell")
    }
    _ = try d.exec("\(ctl) workspace switch LegacyDestination")
    guard d.wait(for: { (try? d.focusedPaneId()) == second }, timeout: 10), kill(shell, 0) == 0 else {
        throw Failure("the recovered session did not reappear in the chosen workspace")
    }
}
