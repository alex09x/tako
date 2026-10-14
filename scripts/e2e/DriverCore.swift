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

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func hex(_ s: String) -> String {
    "\"\(s)\" [" + s.utf8.map { String(format: "%02x", $0) }.joined(separator: " ") + "]"
}

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

final class Driver {
    var pid: pid_t = 0
    let appURL: URL
    let bundleID: String
    let work: URL
    var environment: [String: String] = [:]
    let source = CGEventSource(stateID: .hidSystemState)

    static let defaultConfig = "window-save-state = never\nauto-update = off\nremote-control = on\n"

    init(app: URL, bundleID: String? = nil) throws {
        self.appURL = app
        self.bundleID = bundleID
            ?? ProcessInfo.processInfo.environment["TAKO_BUNDLE_ID"]
            ?? "com.tako-core.terminal.e2e"
        self.work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tako-driver-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    deinit {
        quit()
        try? FileManager.default.removeItem(at: work)
    }

    func path(_ name: String) -> String {
        work.appendingPathComponent(name).path
    }

    func running() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.executableURL?.path.hasPrefix(appURL.path) == true
        }
    }

    var isRunning: Bool {
        pid != 0 && NSRunningApplication(processIdentifier: pid)?.isTerminated == false
    }

    func wait(for condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(100_000)
        }
        return condition()
    }

    func launch(config: String = Driver.defaultConfig) throws {
        quit()
        let configURL = work.appendingPathComponent("config")
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        let before = Set(running().map(\.processIdentifier))
        let hooksHome = work.appendingPathComponent("agent-hooks-home")
        try? FileManager.default.createDirectory(at: hooksHome, withIntermediateDirectories: true)
        var env = environment
        if let home = ProcessInfo.processInfo.environment["TAKO_SESSIONS_HOME"] { env["TAKO_SESSIONS_HOME"] = home }
        if env["TAKO_AGENT_HOOKS_HOME"] == nil { env["TAKO_AGENT_HOOKS_HOME"] = hooksHome.path }
        if env["CODEX_HOME"] == nil { env["CODEX_HOME"] = hooksHome.appendingPathComponent(".codex").path }
        env["TAKO_NO_UPDATE"] = "1"
        env["TAKO_NO_LAUNCH_NOTICES"] = "1"

        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", "--env", "TAKO_CONFIG_PATH=\(configURL.path)"]
            + env.flatMap { ["--env", "\($0.key)=\($0.value)"] }
            + [appURL.path, "--args", "--no-update", "--no-launch-notices"]
        try open.run()
        open.waitUntilExit()

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let app = running().first(where: { !before.contains($0.processIdentifier) }) {
                pid = app.processIdentifier
                break
            }
            usleep(100_000)
        }
        guard pid != 0 else { throw Failure("Tako did not start") }

        guard wait(for: { !self.windows().isEmpty }, timeout: 15) else {
            throw Failure("Tako started but opened no window")
        }

        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
        if let window = self.windows().first {
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        try run("true")
        usleep(300_000)
    }

    func activate() {
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        if let window = self.windows().first {
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        usleep(100_000)
    }

    func quit() {
        guard pid != 0 else { return }
        let dying = pid
        kill(dying, SIGKILL)
        _ = wait(for: { NSRunningApplication(processIdentifier: dying) == nil }, timeout: 5)
        pid = 0
    }

    func launchAnother(config: String) throws -> pid_t {
        let configURL = work.appendingPathComponent("config-another")
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        let before = Set(running().map(\.processIdentifier))
        var env = environment
        if let home = ProcessInfo.processInfo.environment["TAKO_SESSIONS_HOME"] { env["TAKO_SESSIONS_HOME"] = home }
        env["TAKO_NO_UPDATE"] = "1"
        env["TAKO_NO_LAUNCH_NOTICES"] = "1"
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", "-g", "--env", "TAKO_CONFIG_PATH=\(configURL.path)"]
            + env.flatMap { ["--env", "\($0.key)=\($0.value)"] }
            + [appURL.path, "--args", "--no-update", "--no-launch-notices"]
        try open.run()
        open.waitUntilExit()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let app = running().first(where: { !before.contains($0.processIdentifier) }) {
                return app.processIdentifier
            }
            usleep(100_000)
        }
        throw Failure("the second instance did not start")
    }

    func interrupt() {
        key(Key.c, .maskControl)
        try? type("\u{03}")
    }

    func closeTab() {
        key(Key.w, .maskCommand)
    }

    func newTab() {
        key(Key.t, .maskCommand)
    }

    func quitNormally() throws {
        guard pid != 0 else { return }
        let quitting = pid
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", appURL.path]
        try? open.run()
        open.waitUntilExit()
        _ = wait(for: { NSWorkspace.shared.frontmostApplication?.processIdentifier == quitting }, timeout: 2)

        key(Key.q, .maskCommand)
        if wait(for: { NSRunningApplication(processIdentifier: quitting) == nil }, timeout: 3) {
            pid = 0
            return
        }
        _ = pressQuitMenuItem()
        guard wait(for: { NSRunningApplication(processIdentifier: quitting) == nil }, timeout: 15) else {
            let texts = staticTexts()
            let screen = screenText()
            throw Failure("Cmd+Q did not quit Tako. StaticTexts: \(texts), Screen: [\(screen.suffix(300))]")
        }
        pid = 0
    }

    static func sharedGitRevision() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["rev-parse", "HEAD"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return "unknown" }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
