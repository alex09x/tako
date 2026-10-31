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

func runPersistentWorkspacesScenario(_ d: Driver) throws {
    d.quit()
    forgetLayout(d)
    let config = "session-persistence = true\nwindow-save-state = always\nremote-control = on\n"
    try d.launch(config: config)
    let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
    guard let original = try d.focusedPaneId() else { throw Failure("no original pane") }
    try d.run("sh -c 'echo $PPID' > \(d.path("recovery-default-before"))")
    let defaultPID = try d.file("recovery-default-before")
    let name = "Recovery-\(UUID().uuidString)"
    _ = try d.exec("\(ctl) workspace create \(name)")
    _ = try d.exec("\(ctl) workspace switch \(name)")
    guard d.wait(for: { (try? d.focusedPaneId()) != nil && (try? d.focusedPaneId()) != original }, timeout: 8) else {
        throw Failure("second workspace did not focus its new pane")
    }
    guard let other = try d.focusedPaneId() else { throw Failure("no second pane") }
    try d.run("sh -c 'echo $PPID' > \(d.path("recovery-other-before"))")
    let otherPID = try d.file("recovery-other-before")
    guard defaultPID != otherPID else { throw Failure("workspace did not create a different shell") }
    try d.quitNormally()
    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    let layout = library.appendingPathComponent("Application Support/\(d.bundleID)/layout")
    let launchData = try Data(contentsOf: layout.appendingPathComponent("launch.json"))
    guard let launch = try JSONSerialization.jsonObject(with: launchData) as? [String: Any],
          let generation = launch["journalGeneration"] as? NSNumber else { throw Failure("no saved layout generation") }
    try d.launch(config: config)
    let archived = try String(contentsOf: layout.appendingPathComponent("recovery-\(generation.uint64Value).json"), encoding: .utf8).lowercased()
    guard archived.contains(original.lowercased()), archived.contains(other.lowercased()) else {
        throw Failure("pre-launch recovery copy omitted a workspace pane")
    }
    guard d.wait(for: { ((try? d.exec("\(ctl) workspace current --json")) ?? "").contains(name) }, timeout: 8) else {
        throw Failure("active workspace was not restored")
    }
    try d.run("sh -c 'echo $PPID' > \(d.path("recovery-other-after"))")
    guard try d.file("recovery-other-after") == otherPID else { throw Failure("active workspace shell was not reattached") }
    _ = try d.exec("\(ctl) workspace switch Default")
    try d.run("sh -c 'echo $PPID' > \(d.path("recovery-default-after"))")
    guard try d.file("recovery-default-after") == defaultPID else { throw Failure("hidden workspace shell was not reattached") }
}

func runMissingLayoutSafetyScenario(_ d: Driver) throws {
    d.quit()
    forgetLayout(d)
    let config = "session-persistence = true\nwindow-save-state = always\nremote-control = on\n"
    try d.launch(config: config)
    let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
    try d.run("sh -c 'echo $PPID' > \(d.path("orphan-shell-pid"))")
    guard let shell = Int32(try d.file("orphan-shell-pid").trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw Failure("no shell PID")
    }
    let before = try d.exec("\(ctl) workspace current --json")
    let data = Data(before.utf8)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let result = object["result"] as? [String: Any], let tab = result["active_tab"] as? String else {
        throw Failure("no active tab in workspace response")
    }
    try d.quitNormally()
    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    let workspaces = library.appendingPathComponent("Application Support/\(d.bundleID)/Workspaces/workspaces.json")
    let afterQuit = (try? String(contentsOf: workspaces, encoding: .utf8)) ?? ""
    guard afterQuit.lowercased().contains(tab.lowercased()) else {
        throw Failure("normal quit removed the workspace tab association before relaunch")
    }
    forgetLayout(d)
    try d.launch(config: config)
    usleep(3_000_000)
    guard kill(shell, 0) == 0 else { throw Failure("a live session was killed when its layout was missing") }
    let after = try d.exec("\(ctl) workspace current --json")
    guard after.contains(tab.lowercased()) || after.contains(tab.uppercased()) else {
        throw Failure("missing layout discarded the previous workspace tab association")
    }
}
