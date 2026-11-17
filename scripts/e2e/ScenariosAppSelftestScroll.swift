/*
 * tako — Run the app's scroll self-test through the private fixture driver
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */
import Foundation
import CoreFoundation

/// Explicit only: the app generates its own NSEvents; this is not a HID
/// journey. No command is typed into the shell. Driver supplies the private
/// shell environment, verified app cleanup and failure evidence retention.
func runAppSelftestScrollScenario(_ d: Driver) throws {
    let previous = d.environment
    d.environment["TAKO_SELFTEST_DIR"] = d.work.path
    defer { d.environment = previous }
    let quietChild = ProcessInfo.processInfo.environment["TAKO_DIAG_QUIET_SCROLL_CHILD"] == "1"
    print("scroll child mode: \(quietChild ? "quiet" : "baseline")")
    if quietChild {
        // Set the private zsh startup file after the driver's bootstrap.
        // The scroll scenario feeds its own history directly to the engine.
        let startup = d.work.appendingPathComponent("h/.zshenv")
        try "exec /bin/sleep 600\n".write(to: startup, atomically: true, encoding: .utf8)
    }
    try d.launch(config: "window-save-state = never\nauto-update = off\nremote-control = on\n"
                 + "session-persistence = false\nactivity-alert = never\n",
                 settleTerminal: false, arguments: ["--selftest-scroll"])

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
    print("scroll self-test: one pane, persistentSession false")

    let reportPath = d.path("tako-scrolltest.txt")
    guard d.wait(for: {
        guard let report = try? String(contentsOfFile: reportPath, encoding: .utf8) else { return false }
        return report.split(whereSeparator: \.isNewline).contains("complete")
    }, timeout: 25) else { throw Failure("the app scroll self-test did not complete") }
    let report = try String(contentsOfFile: reportPath, encoding: .utf8)
    print(report)
    let pid = (panes[0]["pid"] as? NSNumber)?.int32Value ?? 0
    let command = pid > 0 ? (try? d.exec("ps -p \(pid) -o comm=").trimmingCharacters(in: .whitespacesAndNewlines)) : nil
    print("scroll child witness: \(command ?? "unavailable")")
    let screen = d.screenText()
    if let lastLine = screen.range(of: "history line 399", options: .backwards) {
        let tail = screen[lastLine.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        print("scroll output after synthetic history: \(String(reflecting: String(tail.prefix(600))))")
    } else {
        print("scroll output after synthetic history: unavailable (last line not in AX text)")
    }
    guard !report.split(whereSeparator: \.isNewline).contains(where: { $0.hasPrefix("FAIL") }) else {
        throw Failure("the app scroll self-test reported a failed assertion")
    }
    guard report.contains("fraction retained through display"), report.contains("reverse before display"),
          report.range(of: "(?m)^frames submitted=[1-9][0-9]* ", options: .regularExpression) != nil else {
        throw Failure("the scroll report did not cover both display checks and a submitted frame")
    }
}
