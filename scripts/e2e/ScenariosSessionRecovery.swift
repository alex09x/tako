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
    guard d.wait(for: { d.onScreenWindows().count == 1 }, timeout: 8) else {
        throw Failure("windows belonging to an inactive workspace are visible after restore")
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
    guard let originalPane = try d.focusedPaneId() else { throw Failure("no original recovery pane") }
    try d.run("sh -c 'echo $PPID' > \(d.path("orphan-shell-pid")); printf 'orphan-ready-\(originalPane)\\n'")
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
    try d.launch(config: config, settleTerminal: false)
    usleep(3_000_000)
    guard kill(shell, 0) == 0 else { throw Failure("a live session was killed when its layout was missing") }
    let after = try d.exec("\(ctl) workspace current --json")
    guard after.contains(tab.lowercased()) || after.contains(tab.uppercased()) else {
        throw Failure("missing layout discarded the previous workspace tab association")
    }
    guard d.wait(for: { d.hasText(containing: "Session Recovery") }, timeout: 15) else {
        throw Failure("no session recovery dialog for the unplaced session")
    }
    try d.clickButton(titled: "Restore")
    guard d.wait(for: { (try? d.focusedPaneId())?.lowercased() == originalPane.lowercased() }, timeout: 15) else {
        throw Failure("recovery did not return the original pane")
    }
    guard d.wait(for: { d.screenText().contains("orphan-ready-\(originalPane)") }, timeout: 15) else {
        throw Failure("the original session did not finish reconnecting")
    }
    try d.run("sh -c 'echo $PPID' > \(d.path("orphan-shell-after"))")
    guard try d.file("orphan-shell-after").trimmingCharacters(in: .whitespacesAndNewlines) == String(shell) else {
        throw Failure("recovery replaced the shell instead of reconnecting to it")
    }
}

func runDamagedSessionRecordScenario(_ d: Driver, retainLayout: Bool = false) throws {
    d.quit()
    forgetLayout(d)
    let config = "session-persistence = true\nwindow-save-state = always\nremote-control = on\n"
    try d.launch(config: config)
    guard let pane = try d.focusedPaneId(), let id = UUID(uuidString: pane) else {
        throw Failure("no recoverable pane ID")
    }
    try d.run("sh -c 'echo $PPID' > \(d.path("damaged-shell-before")); printf 'adopt-ready-\(id.uuidString)\\n'")
    let originalPID = try d.file("damaged-shell-before").trimmingCharacters(in: .whitespacesAndNewlines)
    try d.quitNormally()
    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    let records = library.appendingPathComponent("Application Support/\(d.bundleID)/SessionRecords")
    let record = records.appendingPathComponent("\(id.uuidString).session")
    let damaged = Data("deliberately damaged test record".utf8)
    try damaged.write(to: record)
    if !retainLayout { forgetLayout(d) }
    try d.launch(config: config, settleTerminal: false)
    guard d.wait(for: { d.hasText(containing: "Session Recovery") }, timeout: 15) else {
        throw Failure("no recovery dialog for damaged record")
    }
    try d.clickButton(titled: "Restore")
    guard d.wait(for: { d.hasText(containing: "Unverified Session") }, timeout: 10) else {
        throw Failure("no confirmation to adopt the unverified session")
    }
    try d.clickButton(titled: "Adopt")
    guard d.wait(for: { (try? d.focusedPaneId())?.lowercased() == pane.lowercased() }, timeout: 15) else {
        throw Failure("adoption did not return the original pane")
    }
    guard d.wait(for: { d.screenText().contains("adopt-ready-\(id.uuidString)") }, timeout: 15) else {
        throw Failure("the adopted session did not finish reconnecting")
    }
    try d.run("sh -c 'echo $PPID' > \(d.path("damaged-shell-after"))")
    guard try d.file("damaged-shell-after").trimmingCharacters(in: .whitespacesAndNewlines) == originalPID else {
        throw Failure("adoption replaced the original shell")
    }
    let history = records.appendingPathComponent("History")
    let files = try FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)
    guard files.contains(where: { (try? Data(contentsOf: $0)) == damaged }) else {
        throw Failure("the damaged record was not preserved")
    }
}

func runMissingLayoutAcrossWorkspacesScenario(_ d: Driver) throws {
    d.quit()
    forgetLayout(d)
    let config = "session-persistence = true\nwindow-save-state = always\nremote-control = on\n"
    try d.launch(config: config)
    let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
    _ = try d.exec("\(ctl) workspace switch Default")
    guard let firstPane = try d.focusedPaneId() else { throw Failure("no first workspace pane") }
    try d.run("sh -c 'echo $PPID' > \(d.path("lost-workspace-one"))")
    let firstPID = try d.file("lost-workspace-one")
    let workspace = "Lost-\(UUID().uuidString)"
    _ = try d.exec("\(ctl) workspace create \(workspace)")
    _ = try d.exec("\(ctl) workspace switch \(workspace)")
    guard d.wait(for: { guard let focused = try? d.focusedPaneId() else { return false }; return focused != firstPane }, timeout: 8),
          let secondPane = try d.focusedPaneId() else { throw Failure("no second workspace pane") }
    try d.run("sh -c 'echo $PPID' > \(d.path("lost-workspace-two"))")
    let secondPID = try d.file("lost-workspace-two")
    guard firstPID != secondPID else { throw Failure("workspaces did not have separate shells") }
    try d.quitNormally()
    forgetLayout(d)
    try d.launch(config: config, settleTerminal: false)
    guard d.wait(for: { d.hasText(containing: "Session Recovery") }, timeout: 15) else {
        throw Failure("no recovery dialog after losing both workspaces' layout")
    }
    try d.clickButton(titled: "Restore")
    _ = try d.exec("\(ctl) workspace switch Default")
    guard d.wait(for: { (try? d.focusedPaneId())?.lowercased() == firstPane.lowercased() }, timeout: 15) else {
        throw Failure("first workspace did not regain its pane")
    }
    try d.run("sh -c 'echo $PPID' > \(d.path("lost-workspace-one-after"))")
    guard try d.file("lost-workspace-one-after") == firstPID else { throw Failure("first workspace got a new shell") }
    _ = try d.exec("\(ctl) workspace switch \(workspace)")
    guard d.wait(for: { (try? d.focusedPaneId())?.lowercased() == secondPane.lowercased() }, timeout: 15) else {
        throw Failure("second workspace did not regain its pane")
    }
    try d.run("sh -c 'echo $PPID' > \(d.path("lost-workspace-two-after"))")
    guard try d.file("lost-workspace-two-after") == secondPID else { throw Failure("second workspace got a new shell") }
}

func runWorkspaceArchiveFailureScenario(_ d: Driver) throws {
    d.quit()
    let config = "session-persistence = true\nwindow-save-state = always\nremote-control = on\n"
    try d.launch(config: config)
    let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
    guard let pane = try d.focusedPaneId(), let paneID = UUID(uuidString: pane) else { throw Failure("no workspace pane") }
    _ = try d.exec("\(ctl) workspace create Original")
    _ = try d.exec("\(ctl) workspace assign --workspace Original --target \(pane)")
    try d.quitNormally()
    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    let directory = library.appendingPathComponent("Application Support/\(d.bundleID)/Workspaces")
    let file = directory.appendingPathComponent("workspaces.json")
    let original = try Data(contentsOf: file)
    let record = library.appendingPathComponent("Application Support/\(d.bundleID)/SessionRecords/\(paneID.uuidString).session")
    guard let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any],
          let originalWorkspace = saved["workspaceID"] as? String else { throw Failure("no recorded workspace placement") }
    let history = directory.appendingPathComponent("History")
    if FileManager.default.fileExists(atPath: history.path) {
        try FileManager.default.moveItem(at: history, to: directory.appendingPathComponent("History-test-backup"))
    }
    try Data("block the archive".utf8).write(to: history)
    try d.launch(config: config, settleTerminal: false)
    guard d.wait(for: { d.hasText(containing: "Workspaces Not Saved") }, timeout: 20) else {
        throw Failure("workspace archive failure was not shown; visible text: \(d.staticTexts())")
    }
    try d.clickButton(titled: "OK")
    _ = try d.exec("\(ctl) workspace create MustNotPersist")
    _ = try d.exec("\(ctl) workspace assign --workspace MustNotPersist --target \(pane)")
    usleep(1_000_000)
    guard try Data(contentsOf: file) == original else { throw Failure("unarchived workspace file was overwritten") }
    guard let after = try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any],
          after["workspaceID"] as? String == originalWorkspace else {
        throw Failure("unavailable workspace data overwrote the session's prior placement")
    }
}

func runPersistentCrashScenario(_ d: Driver) throws {
    d.quit()
    forgetLayout(d)
    let config = "session-persistence = true\nwindow-save-state = always\nremote-control = on\n"
    try d.launch(config: config)
    guard let pane = try d.focusedPaneId() else { throw Failure("no pane before crash") }
    try d.run("sh -c 'echo $PPID' > \(d.path("crash-shell-before")); printf 'crash-ready-\(pane)\\n'")
    let originalPID = try d.file("crash-shell-before")
    guard d.wait(for: { d.screenText().contains("crash-ready-\(pane)") }, timeout: 10) else {
        throw Failure("the original shell did not print its marker")
    }
    // Let the layout journal capture this pane, then kill only the isolated test app.
    usleep(1_000_000)
    d.quit()
    guard let shell = Int32(originalPID.trimmingCharacters(in: .whitespacesAndNewlines)), kill(shell, 0) == 0 else {
        throw Failure("the shell did not survive the app crash")
    }
    try d.launch(config: config, settleTerminal: false)
    guard d.wait(for: {
        (try? d.focusedPaneId())?.lowercased() == pane.lowercased() && d.screenText().contains("crash-ready-\(pane)")
    }, timeout: 15) else { throw Failure("the crashed app did not reconnect the original pane") }
    try d.run("sh -c 'echo $PPID' > \(d.path("crash-shell-after"))")
    guard try d.file("crash-shell-after") == originalPID else { throw Failure("crash recovery started a replacement shell") }
}

func runSnapshotArchiveFailureScenario(_ d: Driver) throws {
    d.quit()
    forgetLayout(d)
    let config = "session-persistence = true\nwindow-save-state = always\nremote-control = on\n"
    try d.launch(config: config)
    guard let pane = try d.focusedPaneId(), let id = UUID(uuidString: pane) else { throw Failure("no snapshot pane") }
    try d.run("printf 'snapshot-before-failure\\n'")
    guard d.wait(for: { d.screenText().contains("snapshot-before-failure") }, timeout: 10) else {
        throw Failure("the original screen was not printed")
    }
    try d.quitNormally()
    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    let directory = library.appendingPathComponent("Application Support/\(d.bundleID)/Sessions")
    let snapshot = directory.appendingPathComponent("\(id.uuidString).snapshot")
    let original = try Data(contentsOf: snapshot)
    let history = directory.appendingPathComponent("History")
    if FileManager.default.fileExists(atPath: history.path) {
        try FileManager.default.moveItem(at: history, to: directory.appendingPathComponent("History-test-backup"))
    }
    try Data("block the archive".utf8).write(to: history)
    try d.launch(config: config, settleTerminal: false)
    guard d.wait(for: { d.screenText().contains("snapshot-before-failure") }, timeout: 15) else {
        throw Failure("the live session did not reconnect")
    }
    try d.run("printf 'snapshot-after-failure\\n'")
    guard d.wait(for: { d.hasText(containing: "Saved Screens Not Updating") }, timeout: 45) else {
        throw Failure("snapshot archive failure was not shown")
    }
    guard try Data(contentsOf: snapshot) == original else { throw Failure("the unarchived snapshot was overwritten") }
    try d.clickButton(titled: "OK")
}

func runLayoutArchiveFailureScenario(_ d: Driver) throws {
    d.quit()
    forgetLayout(d)
    let config = "session-persistence = true\nwindow-save-state = always\nremote-control = on\n"
    try d.launch(config: config)
    guard let pane = try d.focusedPaneId() else { throw Failure("no pane before layout archive test") }
    try d.quitNormally()
    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    let layout = library.appendingPathComponent("Application Support/\(d.bundleID)/layout")
    let launchData = try Data(contentsOf: layout.appendingPathComponent("launch.json"))
    guard let launch = try JSONSerialization.jsonObject(with: launchData) as? [String: Any],
          let generation = launch["journalGeneration"] as? NSNumber else { throw Failure("no layout generation") }
    let journal = layout.appendingPathComponent("journal-\(generation.uint64Value).json")
    let original = try Data(contentsOf: journal)
    let conflict = layout.appendingPathComponent("recovery-\(generation.uint64Value).json")
    try Data("deliberate conflict".utf8).write(to: conflict)
    try d.launch(config: config, settleTerminal: false)
    guard d.wait(for: { d.hasText(containing: "Window Layout Not Saved") }, timeout: 20) else {
        throw Failure("layout archive failure was not shown")
    }
    guard try Data(contentsOf: journal) == original else { throw Failure("the previous layout was overwritten") }
    try d.clickButton(titled: "OK")
    guard d.wait(for: { (try? d.focusedPaneId())?.lowercased() == pane.lowercased() }, timeout: 15) else {
        throw Failure("the valid layout was not restored after archive failure")
    }
}

func runLegacyUpgradeScenario(_ d: Driver) throws {
    guard let oldRuntime = ProcessInfo.processInfo.environment["TAKO_TEST_OLD_ZMX"],
          FileManager.default.isExecutableFile(atPath: oldRuntime),
          let home = ProcessInfo.processInfo.environment["TAKO_SESSIONS_HOME"] else {
        throw Failure("legacy upgrade test requires an explicit old runtime and isolated session home")
    }
    d.quit()
    forgetLayout(d)
    let config = "session-persistence = true\nwindow-save-state = always\nremote-control = on\n"
    try d.launch(config: config)
    guard let pane = try d.focusedPaneId(), let id = UUID(uuidString: pane) else { throw Failure("no pane") }
    try d.run("sh -c 'echo $PPID' > \(d.path("new-shell-before-legacy"))")
    guard let otherShell = Int32(try d.file("new-shell-before-legacy").trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw Failure("no other test shell")
    }
    try d.quitNormally()
    let runtimeID = "0.8.1-0000000000000000"
    let namespace = URL(fileURLWithPath: home).appendingPathComponent(".tako-sessions/\(runtimeID)")
    try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    try Data("\(runtimeID)\n".utf8).write(to: namespace.appendingPathComponent("runtime-id"))
    let name = id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let generation = "0123456789abcdef0123456789abcdef"
    let marker = "legacy-ready-\(id.uuidString)"
    let script = Process()
    script.executableURL = URL(fileURLWithPath: "/usr/bin/script")
    script.arguments = ["-q", "/dev/null", oldRuntime, "attach", "--labels", "tako-gen=\(generation)",
                        name, "/bin/sh", "-c", "echo $$ > \(d.path("legacy-shell-before")); printf '\(marker)\\n'; exec /bin/sh -i"]
    var env = ProcessInfo.processInfo.environment
    for key in ["ZMX_SESSION", "ZMX_SESSION_PREFIX", "ZMX_DIR"] { env.removeValue(forKey: key) }
    env["ZMX_DIR"] = namespace.path
    env["HOME"] = home
    env["ZMX_TRACK_ENV"] = ""
    env["ZMX_DIR_MODE"] = "0700"
    env["ZMX_LOG_MODE"] = "0600"
    script.environment = env
    let input = Pipe()
    script.standardInput = input
    script.standardOutput = FileHandle.nullDevice
    script.standardError = FileHandle.nullDevice
    try script.run()
    defer { if script.isRunning { script.terminate() } }
    let oldPID = try d.file("legacy-shell-before").trimmingCharacters(in: .whitespacesAndNewlines)
    if script.isRunning { script.terminate() }
    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    let records = library.appendingPathComponent("Application Support/\(d.bundleID)/SessionRecords")
    let record: [String: Any] = ["id": id.uuidString, "runtimeID": runtimeID, "generation": generation,
                                 "state": ["detached": [String: String]()], "createdAt": 0]
    try JSONSerialization.data(withJSONObject: record).write(to: records.appendingPathComponent("\(id.uuidString).session"))
    try d.launch(config: config, settleTerminal: false)
    guard d.wait(for: { d.screenText().contains(marker) }, timeout: 20) else {
        throw Failure("the old daemon did not reconnect through the new client")
    }
    try d.run("sh -c 'echo $PPID' > \(d.path("legacy-shell-after"))")
    guard try d.file("legacy-shell-after").trimmingCharacters(in: .whitespacesAndNewlines) == oldPID else {
        throw Failure("legacy upgrade started a replacement shell")
    }
    guard kill(otherShell, 0) == 0 else { throw Failure("an unrelated session was terminated") }
}
