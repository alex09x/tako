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
    /// A scenario's own variables, over `privateDefaults` at every launch.
    var environment: [String: String] = [:]
    /// What every app this driver starts runs in unless a scenario says
    /// otherwise: a private HOME, XDG dirs, history, session and hooks
    /// namespace under `work`, so even the first shell of a run never
    /// touches the owner's. Empty when the driver was made with
    /// `privateShell: false`.
    let privateDefaults: [String: String]
    let source = CGEventSource(stateID: .hidSystemState)
    /// The app processes this driver started, by PID and identity (start
    /// time and executable); cleanup signals only one still the same.
    var ownedApps: [(pid: pid_t, birth: String)] = []
    /// What cleanup could not confirm: a reused or unknown PID, a refused
    /// signal, a survivor. A run with any of these has not passed.
    var cleanupProblems: [String] = []
    /// Set only by a scenario that passed with a proven cleanup: then the
    /// work directory, which is otherwise the evidence, goes at the end.
    var removeWorkWhenDone = false
    /// Swapped by the self-test; the real ones look and signal.
    var identify: (pid_t) -> ProcessIdentity = { _ in .unknown("not set up") }
    var signalKill: (pid_t) -> Int32 = { kill($0, SIGKILL) == 0 ? 0 : errno }
    var settleGone: (pid_t) -> Void = { dying in
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, kill(dying, 0) == 0 { usleep(100_000) }
    }

    static let defaultConfig = "window-save-state = never\nauto-update = off\nremote-control = on\n"

    /// `sessionsHome`: an owned persistence fixture's session namespace
    /// (scripts/e2e-persist.sh makes one per case); nil gives a private one.
    init(app: URL, bundleID: String? = nil, sessionsHome: String? = nil, privateShell: Bool = true) throws {
        self.appURL = app
        self.bundleID = bundleID
            ?? ProcessInfo.processInfo.environment["TAKO_BUNDLE_ID"]
            ?? "com.tako-core.terminal.e2e"
        let work = try makeDriverWorkDirectory()
        self.work = work
        // Short names: the session namespace holds Unix sockets.
        let home = work.appendingPathComponent("h").path, hooks = work.appendingPathComponent("k").path
        // Agent hook and provider homes are private for every launch, as they
        // always were -- also when the shell itself is the configured one.
        try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
        var defaults: [String: String] = ["TAKO_AGENT_HOOKS_HOME": hooks, "CODEX_HOME": hooks + "/.codex"]
        if privateShell {
            for dir in [home, home + "/.config", home + "/.local/share", home + "/.cache"] {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            // ZDOTDIR too: Tako's zsh integration restores an inherited one
            // (TAKO_ZSH_ZDOTDIR) and reads its startup files from there, so a
            // private HOME alone would not keep zsh away from them.
            defaults.merge(["HOME": home, "XDG_CONFIG_HOME": home + "/.config", "XDG_DATA_HOME": home + "/.local/share",
                            "XDG_CACHE_HOME": home + "/.cache", "HISTFILE": home + "/.shell_history",
                            "ZDOTDIR": home]) { _, new in new }
        }
        if let sessionsHome {
            defaults["TAKO_SESSIONS_HOME"] = sessionsHome
        } else if privateShell {
            // Short, as scripts/e2e-persist.sh's /tmp/tkp.*: it holds Unix
            // sockets, whose paths may not exceed 104 bytes.
            var template = Array("/tmp/tkd.XXXXXX".utf8CString)
            guard mkdtemp(&template) != nil else { throw Failure("no private session namespace: errno \(errno)") }
            let sessions = String(cString: template)
            ownedSessions = sessions
            try sessions.write(to: work.appendingPathComponent("sessions-path"), atomically: true, encoding: .utf8)
            defaults["TAKO_SESSIONS_HOME"] = sessions
        }
        self.privateDefaults = defaults
        let exe = Driver.expectedExecutable(of: app)
        self.expectedExecutable = exe
        identify = { Driver.appIdentity($0, expecting: exe) }
    }

    /// The full path of the app's own executable: the only one this driver
    /// admits as its app, at launch and again before every signal.
    let expectedExecutable: String

    static func expectedExecutable(of app: URL) -> String {
        let exe = Bundle(url: app)?.executableURL ?? app.appendingPathComponent("Contents/MacOS/Tako")
        guard let real = realpath(exe.path, nil) else { return exe.standardizedFileURL.path }
        defer { free(real) }
        return String(cString: real)
    }

    /// The private session namespace this driver made, kept and removed with `work`.
    private(set) var ownedSessions: String?

    deinit {
        quit()
        // A failed scenario's or an unproven cleanup's files are the evidence.
        if removeWorkWhenDone && cleanupProblems.isEmpty {
            try? FileManager.default.removeItem(at: work)
            if let ownedSessions { try? FileManager.default.removeItem(atPath: ownedSessions) }
        } else {
            print("work kept: \(work.path)\(ownedSessions.map { ", sessions \($0)" } ?? "")")
        }
    }

    /// The variables an app this driver starts gets: the private defaults,
    /// then the scenario's own, then what the driver itself always sets.
    func launchEnvironment() -> [String: String] {
        var env = privateDefaults.merging(environment) { _, scenario in scenario }
        env["TAKO_NO_UPDATE"] = "1"
        env["TAKO_NO_LAUNCH_NOTICES"] = "1"
        return env
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

    func launch(config: String = Driver.defaultConfig, settleTerminal: Bool = true, arguments: [String] = []) throws {
        var timing = DriverLaunchClock()
        quit()
        timing.mark("quit")
        // The session sidebar's visibility is kept in the app's defaults: a run
        // that stopped with it open would start the next one with it open, and
        // a scenario's Cmd+Opt+S would close it. Every launch starts it closed.
        let forget = Process()
        forget.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        forget.arguments = ["delete", bundleID, "tako.session_sidebar_is_showing"]
        forget.standardError = FileHandle.nullDevice
        forget.standardOutput = FileHandle.nullDevice
        try? forget.run()
        forget.waitUntilExit()
        timing.mark("defaults")
        let configURL = work.appendingPathComponent("config")
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        let before = Set(running().map(\.processIdentifier))
        let env = launchEnvironment()

        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", "--env", "TAKO_CONFIG_PATH=\(configURL.path)"]
            + env.flatMap { ["--env", "\($0.key)=\($0.value)"] }
            + [appURL.path, "--args", "--no-update", "--no-launch-notices"] + arguments
        timing.mark("prepare")
        try open.run()
        open.waitUntilExit()
        timing.mark("open")

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let app = running().first(where: { !before.contains($0.processIdentifier) }) {
                pid = app.processIdentifier
                break
            }
            // NSWorkspace updates its application list through the run loop.
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard pid != 0 else { throw Failure("Tako did not start") }
        try own(pid, what: "the app")
        timing.mark("pid-identity")

        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
        timing.mark("activate")
        guard wait(for: { !self.windows().isEmpty }, timeout: 15) else {
            let application = NSRunningApplication(processIdentifier: pid)
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
            throw Failure("Tako started but opened no window: pid \(pid), terminated \(String(describing: application?.isTerminated)), active \(String(describing: application?.isActive)), hidden \(String(describing: application?.isHidden)), policy \(application?.activationPolicy.rawValue ?? -1), AX status \(status.rawValue), raw windows \((value as? [AXUIElement])?.count ?? -1)")
        }
        if let window = self.windows().first {
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        timing.mark("window")
        if settleTerminal {
            // The first command also proves where the shell runs: in this
            // launch's environment, never the owner's.
            let witness = ShellBootstrapWitness()
            let file = witness.fileName
            let command = try witness.writeCommand(in: work)
            try run("source '\(command.path)'")
            timing.mark("bootstrap-typed")
            let want = ["HOME", "XDG_DATA_HOME", "HISTFILE", "TAKO_SESSIONS_HOME", "ZDOTDIR"].map { env[$0] ?? "" }.joined(separator: "|")
            var seen: String?
            guard wait(for: {
                guard let text = try? String(contentsOf: self.work.appendingPathComponent(file), encoding: .utf8),
                      let receipt = witness.receipt(from: text) else { return false }
                seen = receipt
                return true
            }, timeout: 10), let seen else {
                throw Failure("this launch did not write its fresh shell bootstrap witness. Screen: [\(screenText().suffix(500))]")
            }
            usleep(150_000)
            guard env["HOME"] == nil || seen == want else {
                throw Failure("the first shell does not run in this launch's environment: \(seen), want \(want)")
            }
            print("first shell (HOME|XDG_DATA_HOME|HISTFILE|TAKO_SESSIONS_HOME|ZDOTDIR): \(seen)")
            timing.mark("bootstrap-receipt")
        }
        usleep(300_000)
        timing.mark("settle")
    }

    /// The owner's shell histories by size and modification time; their
    /// contents are never read.
    static func ownerHistoryStamp() -> [String] {
        let owner = NSHomeDirectory()
        return [".local/share/fish/fish_history", ".bash_history", ".zsh_history"].map { name in
            let path = owner + "/" + name
            guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return "absent \(path)" }
            return "\(a[.size] ?? 0) \((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) \(path)"
        }
    }

    /// Records a process this driver started by its identity now.
    func own(_ pid: pid_t, what: String) throws {
        let identity = identify(pid)
        guard case .running(let birth) = identity else {
            throw Failure("\(what) (pid \(pid)) is not admitted: \(identity)")
        }
        ownedApps.append((pid, birth))
    }

    /// The start time and executable of a PID, read once, fresh. A process
    /// running anything but `expected` is not this driver's: unknown, so it
    /// is neither admitted nor ever signalled.
    static func appIdentity(_ pid: pid_t, expecting expected: String) -> ProcessIdentity {
        let live = OwnedProcesses.liveIdentity(pid)
        guard case .running(let birth) = live else { return live }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else {
            return kill(pid, 0) != 0 && errno == ESRCH ? .gone : .unknown("proc_pidpath errno \(errno)")
        }
        let exe = String(cString: buffer)
        guard exe == expected else { return .unknown("pid \(pid) runs \(exe), not \(expected)") }
        return .running(birth: "\(birth) \(exe)")
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

    /// Ends the current app: SIGKILL, but only after its identity, read
    /// again right now, is still the one recorded at launch.
    func quit() {
        guard pid != 0 else { return }
        let dying = pid
        pid = 0
        end([dying])
    }

    /// Ends every app this driver started that is still running, the main
    /// one and any `launchAnother` started; what is left unproven stays in
    /// `cleanupProblems`.
    func endAll() {
        pid = 0
        end(ownedApps.map(\.pid))
    }

    private func end(_ pids: [pid_t]) {
        var processes = OwnedProcesses()
        processes.identity = identify
        processes.signal = signalKill
        processes.settle = { [settleGone] in pids.forEach(settleGone) }
        for target in pids {
            guard let birth = ownedApps.first(where: { $0.pid == target })?.birth else {
                cleanupProblems.append("pid \(target): not started by this driver; not signalled")
                continue
            }
            processes.adopt(pid: target, birth: birth)
        }
        cleanupProblems += processes.cleanUp()
        ownedApps.removeAll { pids.contains($0.pid) }
    }

    func launchAnother(config: String) throws -> pid_t {
        let configURL = work.appendingPathComponent("config-another")
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        let before = Set(running().map(\.processIdentifier))
        let env = launchEnvironment()
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
                try own(app.processIdentifier, what: "the second instance")
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
