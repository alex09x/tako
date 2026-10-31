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

func runAgentConversationRecoveryScenario(_ d: Driver) throws {
    d.quit()
    forgetLayout(d)
    let config = "session-persistence = true\nwindow-save-state = always\nremote-control = on\n"
    try d.launch(config: config)
    guard let pane = try d.focusedPaneId() else { throw Failure("no pane") }
    let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
    _ = try d.exec("\(ctl) session note-agent codex synthetic-thread-123 --target \(pane)")
    try d.quitNormally()
    try d.launch(config: config)
    guard d.pressMenu(title: "Agent Conversations…") else { throw Failure("agent conversations menu unavailable") }
    guard d.wait(for: { d.hasText(containing: "synthetic-thread-123") }, timeout: 10) else {
        throw Failure("observed conversation missing after relaunch: \(d.staticTexts())")
    }
    try d.clickButton(titled: "Close")
    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    let directory = library.appendingPathComponent("Application Support/\(d.bundleID)/AgentConversations")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
    _ = try d.exec("\(ctl) session note-agent codex another-thread --target \(pane) || true")
    guard d.wait(for: { d.hasText(containing: "Agent Conversation Not Saved") }, timeout: 10) else {
        throw Failure("storage failure was not shown to the user")
    }
    try d.clickButton(titled: "OK")
}

func runSessionNameCollisionScenario(_ d: Driver) throws {
    d.quit()
    forgetLayout(d)
    let config = "session-persistence = true\nwindow-save-state = always\nremote-control = on\n"
    try d.launch(config: config)
    guard let pane = try d.focusedPaneId(), let id = UUID(uuidString: pane) else { throw Failure("no pane") }
    try d.run("sh -c 'echo $PPID' > \(d.path("collision-shell-before")); printf 'collision-ready-\(id.uuidString)\\n'")
    let originalPID = try d.file("collision-shell-before").trimmingCharacters(in: .whitespacesAndNewlines)
    try d.quitNormally()
    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    let support = library.appendingPathComponent("Application Support/\(d.bundleID)")
    let recordURL = support.appendingPathComponent("SessionRecords/\(id.uuidString).session")
    let recordData = try Data(contentsOf: recordURL)
    guard let record = try JSONSerialization.jsonObject(with: recordData) as? [String: Any],
          let runtimeID = record["runtimeID"] as? String, let generation = record["generation"] as? String,
          let home = ProcessInfo.processInfo.environment["TAKO_SESSIONS_HOME"] else { throw Failure("no isolated session record") }
    let otherRuntime = "0.8.1-0000000000000000"
    guard otherRuntime < runtimeID else { throw Failure("unexpected test runtime ordering") }
    let otherNamespace = URL(fileURLWithPath: home).appendingPathComponent(".tako-sessions/\(otherRuntime)")
    try FileManager.default.createDirectory(at: otherNamespace, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    try Data("\(otherRuntime)\n".utf8).write(to: otherNamespace.appendingPathComponent("runtime-id"))
    let sameName = id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let other = Process()
    other.executableURL = URL(fileURLWithPath: "/usr/bin/script")
    other.arguments = ["-q", "/dev/null", d.appURL.appendingPathComponent("Contents/Helpers/zmx").path,
                       "attach", "--create-only", "--labels", "tako-gen=ffffffffffffffffffffffffffffffff",
                       sameName, "/bin/sh", "-c", "echo $$ > \(d.path("other-runtime-pid")); exec /bin/sh -i"]
    var otherEnv = ProcessInfo.processInfo.environment
    for key in ["ZMX_SESSION", "ZMX_SESSION_PREFIX", "ZMX_DIR"] { otherEnv.removeValue(forKey: key) }
    otherEnv["ZMX_DIR"] = otherNamespace.path
    otherEnv["ZMX_TRACK_ENV"] = ""
    other.environment = otherEnv
    let input = Pipe()
    other.standardInput = input
    other.standardOutput = FileHandle.nullDevice
    other.standardError = FileHandle.nullDevice
    try other.run()
    defer { if other.isRunning { other.terminate() } }
    guard let otherPID = Int32(try d.file("other-runtime-pid").trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw Failure("the second synthetic session did not start")
    }
    let layout = support.appendingPathComponent("layout")
    let launch = try JSONSerialization.jsonObject(with: Data(contentsOf: layout.appendingPathComponent("launch.json")))
    guard let launch = launch as? [String: Any], let number = launch["journalGeneration"] as? NSNumber else {
        throw Failure("no layout generation")
    }
    let journal = layout.appendingPathComponent("journal-\(number.uint64Value).json")
    let original = try JSONSerialization.jsonObject(with: Data(contentsOf: journal))
    var removed = false
    func withoutPersistentFlag(_ value: Any) -> Any {
        if var object = value as? [String: Any] {
            if let raw = object["id"] as? String, UUID(uuidString: raw) == id, object["persistent"] != nil {
                object.removeValue(forKey: "persistent")
                removed = true
            }
            return object.mapValues(withoutPersistentFlag)
        }
        if let array = value as? [Any] { return array.map(withoutPersistentFlag) }
        return value
    }
    let modified = withoutPersistentFlag(original)
    guard removed else { throw Failure("the test layout had no persistent pane flag") }
    try JSONSerialization.data(withJSONObject: modified).write(to: journal)
    try FileManager.default.removeItem(at: recordURL)
    try d.launch(config: config, settleTerminal: false)
    guard d.wait(for: { d.screenText().contains("session") && d.screenText().contains("Return") }, timeout: 15) else {
        throw Failure("the colliding session was not left for recovery")
    }
    guard !FileManager.default.fileExists(atPath: recordURL.path) else {
        throw Failure("a replacement record was created despite an existing session")
    }
    let namespace = URL(fileURLWithPath: home).appendingPathComponent(".tako-sessions/\(runtimeID)")
    let name = id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    func readLabels() throws -> String {
        let get = Process()
        get.executableURL = d.appURL.appendingPathComponent("Contents/Helpers/zmx")
        get.arguments = ["get", name]
        var env = ProcessInfo.processInfo.environment
        for key in ["ZMX_SESSION", "ZMX_SESSION_PREFIX", "ZMX_DIR"] { env.removeValue(forKey: key) }
        env["ZMX_DIR"] = namespace.path
        env["ZMX_TRACK_ENV"] = ""
        get.environment = env
        let output = Pipe()
        get.standardOutput = output
        get.standardError = FileHandle.nullDevice
        try get.run()
        guard d.wait(for: { !get.isRunning }, timeout: 5) else {
            get.terminate()
            throw Failure("the isolated runtime did not answer")
        }
        guard get.terminationStatus == 0 else { throw Failure("the isolated runtime refused the query") }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
    let labels = try readLabels()
    guard labels.contains("tako-gen=\(generation)"), !labels.contains("tako-attempt=") else {
        throw Failure("create-only changed the existing session identity")
    }
    if !d.hasText(containing: "Session Recovery") {
        guard d.pressMenu(title: "Recover Sessions…") else { throw Failure("recovery menu was not available") }
    }
    guard d.wait(for: { d.hasText(containing: "Session Recovery") }, timeout: 15) else {
        throw Failure("no recovery dialog for the collision")
    }
    try d.clickButton(titled: "Restore")
    guard d.wait(for: { d.hasText(containing: "Unverified Session") }, timeout: 10) else {
        throw Failure("no confirmation for the conflicting generation")
    }
    guard d.hasText(containing: otherRuntime) else { throw Failure("the first candidate was not the second runtime") }
    try d.clickButton(titled: "Leave Running")
    guard d.wait(for: { d.hasText(containing: runtimeID) }, timeout: 10) else {
        throw Failure("leaving the first session running skipped the other candidate")
    }
    try d.clickButton(titled: "Adopt")
    guard d.wait(for: { (try? readLabels().contains("tako-attempt=")) == true }, timeout: 15) else {
        throw Failure("the original session did not complete its guarded handshake; visible text: \(d.staticTexts())")
    }
    let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
    func containsOriginalPID(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            if let raw = object["id"] as? String, UUID(uuidString: raw) == id,
               let pid = object["pid"] as? NSNumber, pid.stringValue == originalPID { return true }
            return object.values.contains(where: containsOriginalPID)
        }
        return (value as? [Any])?.contains(where: containsOriginalPID) ?? false
    }
    guard d.wait(for: {
        guard let json = try? d.exec("\(ctl) tree --json"), let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else { return false }
        return containsOriginalPID(value)
    }, timeout: 15) else { throw Failure("the original shell was not confirmed by the restored pane") }
    try d.run("sh -c 'echo $PPID' > \(d.path("collision-shell-after"))")
    guard try d.file("collision-shell-after").trimmingCharacters(in: .whitespacesAndNewlines) == originalPID else {
        throw Failure("the colliding session was replaced")
    }
    guard kill(otherPID, 0) == 0 else { throw Failure("the skipped second runtime session was terminated") }
    guard d.pressMenu(title: "Recover Sessions…") else { throw Failure("recovery menu was not available again") }
    guard d.wait(for: { d.hasText(containing: "Session Recovery") }, timeout: 10) else {
        throw Failure("the other runtime became hidden after opening the original pane")
    }
    try d.clickButton(titled: "Restore")
    guard d.wait(for: { d.hasText(containing: otherRuntime) }, timeout: 10) else {
        throw Failure("the live session in the other runtime was not offered")
    }
    try d.clickButton(titled: "Adopt")
    guard d.wait(for: { d.hasText(containing: "Session Not Adopted") }, timeout: 10) else {
        throw Failure("adoption did not protect the already open pane")
    }
    try d.clickButton(titled: "OK")
    guard let originalProcess = Int32(originalPID), originalProcess > 0,
          kill(otherPID, 0) == 0, kill(originalProcess, 0) == 0 else {
        throw Failure("reviewing the second runtime terminated a session")
    }
    let restoredData = try Data(contentsOf: recordURL)
    guard let restored = try JSONSerialization.jsonObject(with: restoredData) as? [String: Any],
          restored["runtimeID"] as? String == runtimeID,
          restored["generation"] as? String == generation else { throw Failure("the original identity was not restored") }
}
