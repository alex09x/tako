/*
 * tako — Run the app's own self-tests through the private fixture driver
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */
import Foundation
import CoreFoundation

/// Explicit only, one case per mode of the app's `--selftest-*` flags (what
/// scripts/selftest-macapp.sh ran by hand before). The app generates its own
/// NSEvents; nothing is typed by the driver. The driver supplies the private
/// shell environment, verified app cleanup and failure evidence retention.
/// Every check below is the old wrapper's, with its deadline and message.
private let selftestConfig = "window-save-state = never\nauto-update = off\nremote-control = on\n"
    + "session-persistence = false\nactivity-alert = never\n"

/// Launch with FLAG, require exactly one nonpersistent pane, record the pane's
/// shell, and return the report once READY accepts it within TIMEOUT seconds.
/// No report at all fails as the old wrapper did.
private func runAppSelftest(_ d: Driver, flag: String, report name: String, timeout: TimeInterval, quietChild: Bool = false,
                            ready: @escaping (String) -> Bool) throws -> String {
    let previous = d.environment
    d.environment["TAKO_SELFTEST_DIR"] = d.work.path
    defer { d.environment = previous }
    if quietChild {
        // The driver has already proved its shell is private. Keep zsh from
        // appending a startup prompt to the scroll test's synthetic history.
        try "exec /bin/sleep 600\n".write(to: d.work.appendingPathComponent("h/.zshenv"),
                                          atomically: true, encoding: .utf8)
    }
    try d.launch(config: selftestConfig, settleTerminal: false, arguments: [flag])

    func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let ctl = quoted(d.appURL.appendingPathComponent("Contents/MacOS/takoctl").path)
        + " --bundle-id " + quoted(d.bundleID)
    var panes = [[String: Any]]()
    func collect(_ value: Any) throws {
        if let dictionary = value as? [String: Any] {
            if let raw = dictionary["panes"] {
                guard let list = raw as? [[String: Any]] else { throw Failure("malformed pane list") }
                panes += list
            }
            try dictionary.values.forEach(collect)
        } else if let list = value as? [Any] { try list.forEach(collect) }
    }
    var lastReply = "no control reply"
    guard d.wait(for: {
        do {
            let raw = try d.exec("\(ctl) tree --json")
            lastReply = String(raw.prefix(1200))
            panes.removeAll()
            try collect(JSONSerialization.jsonObject(with: Data(raw.utf8)))
            return panes.count == 1
        } catch {
            lastReply = String(describing: error)
            return false
        }
    }, timeout: 10) else { throw Failure("one self-test pane was not ready: \(lastReply)") }
    guard panes.count == 1, let persistent = panes[0]["persistentSession"] as? NSNumber,
          CFGetTypeID(persistent) == CFBooleanGetTypeID(), !persistent.boolValue else {
        throw Failure("the self-test must have exactly one nonpersistent pane")
    }
    // Recorded, not asserted: TAKO_SELFTEST_DIR makes the app start /bin/zsh
    // (PTY.loginShell), unlike the driver's ordinary launches.
    let shellPID = (panes[0]["pid"] as? NSNumber)?.int32Value
    let shell = shellPID.flatMap { try? d.exec("ps -o comm= -p \($0)").trimmingCharacters(in: .whitespacesAndNewlines) }
    print("\(flag): one pane, persistentSession false; shell pid \(shellPID.map(String.init) ?? "none") \(shell ?? "unknown")")

    // As before: wait up to the deadline, then judge whatever report exists.
    let path = d.path(name)
    _ = d.wait(for: { (try? String(contentsOfFile: path, encoding: .utf8)).map(ready) ?? false }, timeout: timeout)
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        throw Failure("the app produced no report at all")
    }
    print(text)
    if quietChild {
        let command = shellPID.flatMap { try? d.exec("ps -o comm= -p \($0)").trimmingCharacters(in: .whitespacesAndNewlines) }
        guard command == "/bin/sleep" else { throw Failure("scroll fixture child was \(command ?? "unavailable"), expected /bin/sleep") }
        print("scroll fixture child: /bin/sleep")
    }
    return text
}

private func lines(_ text: String) -> [String] {
    var all = text.components(separatedBy: "\n")
    if all.last == "" { all.removeLast() }
    return all
}

private func matches(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
}

private func finish(_ problems: [String]) throws {
    guard problems.isEmpty else { throw Failure(problems.joined(separator: "; ")) }
}

/// keys: an NSEvent must produce the bytes it stands for.
func runAppSelftestKeysScenario(_ d: Driver) throws {
    let report = try runAppSelftest(d, flag: "--selftest-keys", report: "tako-keytest.txt", timeout: 20) { _ in true }
    var problems: [String] = []
    // Each line reads "label chars=X -> hh (c)". An unwired input path still
    // prints every line, with nothing between the arrow and the parenthesis.
    if matches(report, #"->\s+\("#) {
        problems.append("a keystroke produced no bytes -- input is not reaching the shell")
    }
    for expect in ["chars=a -> 61", "chars=A -> 41", "chars=1 -> 31", "chars=! -> 21"] where !report.contains(expect) {
        problems.append("missing \(expect)")
    }
    // The space bar, by label (what it types is invisible in the chars column).
    for (label, bytes) in [("space", "20"), ("space2", "20"), ("shift+spc", "20"), ("ctrl+spc", "00"), ("opt+spc", "20")] {
        let pattern = "(?m)^" + NSRegularExpression.escapedPattern(for: label) + " +chars=.* -> " + bytes + #" \("#
        if !matches(report, pattern) { problems.append("\(label) should send \(bytes)") }
    }
    try finish(problems)
}

/// input: typing must reach the real shell and come back on screen.
func runAppSelftestInputScenario(_ d: Driver) throws {
    let report = try runAppSelftest(d, flag: "--selftest-input", report: "tako-inputtest.txt", timeout: 30) { _ in true }
    var problems: [String] = []
    if !(lines(report).last ?? "").contains("hello world") {
        problems.append("what was typed never appeared on screen")
    }
    if !lines(report).contains(where: { $0.hasPrefix("focused at launch: yes") }) {
        problems.append("a new window does not give the terminal the keyboard")
    }
    try finish(problems)
}

/// scroll: a precise delta must move the grid by a fraction of a row.
func runAppSelftestScrollScenario(_ d: Driver) throws {
    let report = try runAppSelftest(d, flag: "--selftest-scroll", report: "tako-scrolltest.txt", timeout: 25, quietChild: true) {
        lines($0).contains("complete")
    }
    var problems: [String] = []
    if !lines(report).contains("complete") { problems.append("display checks did not complete") }
    if lines(report).contains(where: { $0.hasPrefix("FAIL") }) { problems.append("the app scroll self-test reported a failed assertion") }
    // A run that scrolled without ever handing a frame over would report every
    // position correctly and still show nothing moving.
    if !matches(report, "submitted=[1-9]") { problems.append("no frame was handed to the display while scrolling") }
    if !report.contains("fraction retained through display") || !report.contains("reverse before display")
        || !matches(report, "(?m)^frames submitted=[1-9][0-9]* ") {
        problems.append("the scroll report did not cover both display checks and a submitted frame")
    }
    try finish(problems)
}

/// frame: the pixels on screen put the grid inside its padding. The PNG is
/// kept for a person (target/selftest-frame.png) before the work is removed.
func runAppSelftestFrameScenario(_ d: Driver) throws {
    let report = try runAppSelftest(d, flag: "--selftest-frame", report: "tako-frametest.txt", timeout: 25) { _ in true }
    let png = d.path("tako-frame.png")
    if FileManager.default.fileExists(atPath: png) {
        let target = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("target/selftest-frame.png")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = target.deletingLastPathComponent().appendingPathComponent(".selftest-frame-\(getpid()).png")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.copyItem(atPath: png, toPath: staging.path)
        // rename(2) replaces an older frame atomically.
        guard rename(staging.path, target.path) == 0 else { throw Failure("could not keep the frame PNG: errno \(errno)") }
        print("  frame saved to target/selftest-frame.png")
    }
    try finish(lines(report).contains(where: { $0.hasPrefix("FAIL") }) ? ["the frame self-test reported a failed assertion"] : [])
}
