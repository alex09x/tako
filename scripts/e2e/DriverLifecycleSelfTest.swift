/*
 * tako — The driver's own app lifecycle: private first launch, identity-checked cleanup, kept evidence
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Darwin
import Foundation

/// Every branch of the driver's app cleanup on stand-ins: no app is
/// launched and nothing but this test's own `sleep` is ever signalled.
func runDriverLifecycleSelfTest(app: URL) throws {
    func expect(_ ok: Bool, _ what: String) throws { if !ok { throw Failure("driver lifecycle: \(what)") }; print("  ok: \(what)") }
    var signalled: [pid_t] = []
    // This test's own drivers: their problems are the point, so whatever
    // happens their scratch goes when the test ends.
    var made: [Driver] = []
    defer { for d in made { d.cleanupProblems = []; d.removeWorkWhenDone = true } }
    func driver(sessionsHome: String? = nil) throws -> Driver {
        let d = try Driver(app: app, bundleID: "selftest.invalid", sessionsHome: sessionsHome)
        made.append(d)
        return d
    }
    /// A driver whose "app" is a fake PID with scripted identities.
    func stubbed(_ table: @escaping (Int) -> ProcessIdentity, signal: Int32 = 0) throws -> Driver {
        var calls = 0
        let d = try driver()
        d.identify = { _ in calls += 1; return table(calls) }
        d.signalKill = { pid in signalled.append(pid); return signal }
        d.settleGone = { _ in }
        return d
    }

    // Launch records the identity; the PID is someone else's at cleanup: not signalled.
    let reused = try stubbed { $0 == 1 ? .running(birth: "A /x/Tako") : .running(birth: "B /x/Other") }
    try reused.own(4242, what: "app"); reused.pid = 4242
    reused.quit()
    try expect(signalled.isEmpty && reused.cleanupProblems.contains { $0.contains("another process") },
               "a reused app PID is not signalled and fails the run")
    // Unknown at cleanup: not signalled, not called gone.
    let unknown = try stubbed { $0 == 1 ? .running(birth: "A /x/Tako") : .unknown("EPERM") }
    try unknown.own(4243, what: "app"); unknown.pid = 4243
    unknown.quit()
    try expect(signalled.isEmpty && unknown.cleanupProblems.count == 2, "an unknown app identity is not signalled and not called gone")
    // The signal is refused and the app survives.
    let stuck = try stubbed({ _ in .running(birth: "A /x/Tako") }, signal: EPERM)
    try stuck.own(4244, what: "app"); stuck.pid = 4244
    stuck.quit()
    try expect(signalled == [4244] && stuck.cleanupProblems.contains { $0.contains("failed, errno \(EPERM)") }
               && stuck.cleanupProblems.contains { $0.contains("still running") }, "a refused signal and a survivor fail the run")
    // A PID the driver never started is never signalled.
    let foreign = try stubbed { _ in .running(birth: "A /x/Tako") }
    foreign.pid = 4245
    foreign.quit()
    try expect(signalled == [4244] && foreign.cleanupProblems.contains { $0.contains("not started by this driver") },
               "a PID the driver did not start is not signalled")
    // An app that cannot be identified at launch is refused there.
    let unidentified = try stubbed { _ in .unknown("ps failed") }
    try expect((try? unidentified.own(4246, what: "app")) == nil && unidentified.ownedApps.isEmpty,
               "an app that cannot be identified at launch is not owned")
    // The same app, gone after its signal: clean.
    let clean = try stubbed { $0 <= 2 ? .running(birth: "A /x/Tako") : .gone }
    try clean.own(4247, what: "app"); clean.pid = 4247
    clean.quit()
    try expect(signalled == [4244, 4247] && clean.cleanupProblems.isEmpty && clean.ownedApps.isEmpty, "its own app is ended and confirmed gone")
    // Outcomes keep an earlier failure; cleanup problems fail a passing run.
    let earlier = Failure("scenario failed")
    try expect((OwnedProcesses.outcome(failure: earlier, problems: stuck.cleanupProblems) as? Failure)?.description == earlier.description,
               "an earlier failure is preserved")
    try expect(OwnedProcesses.outcome(failure: nil, problems: stuck.cleanupProblems) != nil, "a cleanup problem fails a passing run")

    // Evidence: a driver that is not marked done keeps its work after deinit;
    // one marked done with a clean cleanup removes it; problems keep it.
    func workSurvives(_ configure: (Driver) -> Void) throws -> Bool {
        var d: Driver? = try Driver(app: app, bundleID: "selftest.invalid")
        let work = d!.work, sessions = d!.ownedSessions ?? ""
        try "evidence".write(to: work.appendingPathComponent("evidence.txt"), atomically: true, encoding: .utf8)
        configure(d!)
        d = nil
        let kept = FileManager.default.fileExists(atPath: work.appendingPathComponent("evidence.txt").path)
        guard kept == FileManager.default.fileExists(atPath: sessions) else {
            throw Failure("driver lifecycle: the session namespace was not kept or removed with the work")
        }
        if kept { try? FileManager.default.removeItem(at: work); try? FileManager.default.removeItem(atPath: sessions) }   // this test's own scratch
        return kept
    }
    try expect(try workSurvives { _ in }, "a failed scenario's work survives the driver")
    try expect(try workSurvives { $0.removeWorkWhenDone = true; $0.cleanupProblems = ["survivor"] }, "an unproven cleanup keeps the work")
    try expect(!(try workSurvives { $0.removeWorkWhenDone = true }), "a passed scenario with a proven cleanup removes its work")

    // The private launch environment: every default under work, short, and a
    // scenario's own value wins; an owned persistence namespace is kept.
    let d = try driver()
    let env = d.launchEnvironment()
    try expect(["HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "HISTFILE", "ZDOTDIR", "TAKO_AGENT_HOOKS_HOME", "CODEX_HOME"]
                .allSatisfy { env[$0]?.hasPrefix(d.work.path + "/") == true },
               "every shell, history, zsh dotdir and hooks default is under the driver's work: \(env)")
    try expect(env["ZDOTDIR"] == env["HOME"], "zsh's dotdir is the private HOME")
    // An external dotdir in the runner's own environment (a stand-in path)
    // does not reach the launch: the private one is passed explicitly.
    setenv("ZDOTDIR", "/tmp/fake-external-dotdir", 1)
    let withExternal = d.launchEnvironment()["ZDOTDIR"]
    unsetenv("ZDOTDIR")
    try expect(withExternal == env["HOME"], "an inherited external ZDOTDIR is replaced by the private one: \(withExternal ?? "nil")")
    let sessions = env["TAKO_SESSIONS_HOME"] ?? ""
    try expect(sessions == d.ownedSessions && sessions.hasPrefix("/tmp/tkd.") && FileManager.default.fileExists(atPath: sessions),
               "the session namespace is the driver's own: \(sessions)")
    try expect(sessions.utf8.count + 64 < 104, "the private session namespace leaves room for its sockets: \(sessions)")
    d.environment["HOME"] = "/tmp/scenario-home"
    d.environment["ZDOTDIR"] = "/tmp/scenario-home/zsh"
    try expect(d.launchEnvironment()["HOME"] == "/tmp/scenario-home" && d.launchEnvironment()["ZDOTDIR"] == "/tmp/scenario-home/zsh",
               "a scenario's own values win over the defaults")
    let persist = try driver(sessionsHome: "/tmp/owned-sessions")
    try expect(persist.launchEnvironment()["TAKO_SESSIONS_HOME"] == "/tmp/owned-sessions" && persist.ownedSessions == nil,
               "an owned persistence namespace is used as it is, not replaced or removed")
    // The configured shell (the showcase): HOME, history and dotdir are the
    // owner's on purpose, the agent hook and provider homes still private.
    let configured = try Driver(app: app, bundleID: "selftest.invalid", sessionsHome: "/tmp/owned-sessions", privateShell: false)
    made.append(configured)
    let shown = configured.launchEnvironment()
    try expect(shown["HOME"] == nil && shown["HISTFILE"] == nil && shown["ZDOTDIR"] == nil && shown["XDG_DATA_HOME"] == nil,
               "privateShell: false leaves the shell's HOME, history and dotdir alone: \(shown)")
    try expect(shown["TAKO_AGENT_HOOKS_HOME"]?.hasPrefix(configured.work.path + "/") == true
               && shown["CODEX_HOME"]?.hasPrefix(configured.work.path + "/") == true,
               "privateShell: false still keeps the hook and provider homes private")
    try expect(shown["TAKO_SESSIONS_HOME"] == "/tmp/owned-sessions" && configured.ownedSessions == nil,
               "privateShell: false keeps its owned session namespace")

    // One real process of this test's own, identified with its executable,
    // ended through the driver's own cleanup and confirmed gone.
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["60"]
    try sleeper.run()
    // A driver for the real Tako refuses it at admission: the wrong
    // executable is never adopted, so it can never be signalled.
    let tako = try driver()
    try expect(tako.expectedExecutable.hasSuffix(".app/Contents/MacOS/" + (Bundle(url: app)?.executableURL?.lastPathComponent ?? "Tako")),
               "the expected executable is the app's own: \(tako.expectedExecutable)")
    try expect((try? tako.own(sleeper.processIdentifier, what: "a process running another executable")) == nil
               && tako.ownedApps.isEmpty && OwnedProcesses.liveIdentity(sleeper.processIdentifier) != .gone,
               "a PID running another executable is refused at admission and left alone")
    // This test's own sleep, admitted as what it is.
    let real = try driver()
    real.identify = { Driver.appIdentity($0, expecting: "/bin/sleep") }
    real.settleGone = { _ in sleeper.waitUntilExit() }
    try real.own(sleeper.processIdentifier, what: "own sleep")
    try expect(real.ownedApps.first?.birth.hasSuffix("/bin/sleep") == true, "identity holds the executable: \(real.ownedApps)")
    real.pid = sleeper.processIdentifier
    real.quit()
    try expect(real.cleanupProblems.isEmpty && OwnedProcesses.liveIdentity(sleeper.processIdentifier) == .gone,
               "its own process is ended and confirmed gone: \(real.cleanupProblems)")
}
