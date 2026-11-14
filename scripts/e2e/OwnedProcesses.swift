/*
 * tako — Processes a scenario started itself, and their fail-closed cleanup
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Darwin
import Foundation

/// What a PID is right now: a process born at a given time, no process at
/// all, or something that could not be told (never taken as gone).
enum ProcessIdentity: Equatable {
    case running(birth: String)
    case gone
    case unknown(String)
}

/// The processes a scenario started, each known by PID and start time.
/// Cleanup signals only a process that is still the same one, and anything
/// it cannot confirm gone -- a changed or unknown identity, a failed signal,
/// a survivor -- is a problem that fails the scenario.
struct OwnedProcesses {
    var identity: (Int32) -> ProcessIdentity = OwnedProcesses.liveIdentity
    /// 0, or the errno of a failed SIGTERM.
    var signal: (Int32) -> Int32 = { kill($0, SIGTERM) == 0 ? 0 : errno }
    var settle: () -> Void = { usleep(300_000) }
    private(set) var owned: [(pid: Int32, birth: String)] = []

    /// Records a process the scenario started; `text` is the PID it wrote.
    @discardableResult
    mutating func adopt(_ text: String, what: String) throws -> Int32 {
        guard let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else {
            throw Failure("\(what): not a PID: \(text)")
        }
        guard case .running(let birth) = identity(pid) else {
            throw Failure("\(what) (pid \(pid)) is not running: \(identity(pid))")
        }
        owned.append((pid, birth))
        return pid
    }

    func birth(of pid: Int32) -> String? { owned.first { $0.pid == pid }?.birth }

    /// Ends every owned process that is still the same one; the problems
    /// left, none when all are confirmed gone.
    func cleanUp() -> [String] {
        var problems: [String] = []
        for process in owned {
            switch identity(process.pid) {
            case .gone:
                continue
            case .unknown(let why):
                problems.append("pid \(process.pid): identity unknown (\(why)); not signalled")
            case .running(let birth) where birth != process.birth:
                problems.append("pid \(process.pid) is another process now (born \(birth), ours \(process.birth)); not signalled")
            case .running:
                let failed = signal(process.pid)
                if failed != 0 && failed != ESRCH { problems.append("pid \(process.pid): SIGTERM failed, errno \(failed)") }
            }
        }
        settle()
        for process in owned {
            switch identity(process.pid) {
            case .gone:
                continue
            case .running(let birth) where birth == process.birth:
                problems.append("pid \(process.pid) still running")
            case .running:
                continue   // reported above when it changed before the signal; a new process now is not ours
            case .unknown(let why):
                problems.append("pid \(process.pid): cannot confirm it is gone (\(why))")
            }
        }
        return problems
    }

    /// The error a scenario ends with: its own failure first, else the cleanup's.
    static func outcome(failure: Error?, problems: [String]) -> Error? {
        if !problems.isEmpty { print("owned-process cleanup problems: \(problems)") }
        if let failure { return failure }
        return problems.isEmpty ? nil : Failure("owned-process cleanup: \(problems.joined(separator: "; "))")
    }

    static func liveIdentity(_ pid: Int32) -> ProcessIdentity {
        if kill(pid, 0) != 0 {
            return errno == ESRCH ? .gone : .unknown("kill(0) errno \(errno)")
        }
        let ps = Process(), out = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "lstart=", "-p", String(pid)]
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        do { try ps.run() } catch { return .unknown("ps: \(error)") }
        ps.waitUntilExit()
        let birth = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if ps.terminationStatus == 0, !birth.isEmpty { return .running(birth: birth) }
        if kill(pid, 0) != 0, errno == ESRCH { return .gone }
        return .unknown("ps status \(ps.terminationStatus)")
    }
}

/// Every branch of the cleanup on stubs, and one real process of its own:
/// no fixture or other process is ever signalled.
func runOwnedProcessesSelfTest() throws {
    func expect(_ ok: Bool, _ what: String) throws { if !ok { throw Failure("owned processes: \(what)") }; print("  ok: \(what)") }
    var signalled: [Int32] = []
    func stubbed(_ table: @escaping (Int32, Int) -> ProcessIdentity, signal: Int32 = 0) -> OwnedProcesses {
        var calls: [Int32: Int] = [:]
        var p = OwnedProcesses()
        p.identity = { pid in calls[pid, default: 0] += 1; return table(pid, calls[pid]!) }
        p.signal = { pid in signalled.append(pid); return signal }
        p.settle = {}
        return p
    }
    // Adopted as born "A"; then the PID is a process born "B": refused, not signalled.
    var reused = stubbed { _, n in n == 1 ? .running(birth: "A") : .running(birth: "B") }
    try reused.adopt("4242", what: "fixture")
    let reusedProblems = reused.cleanUp()
    try expect(signalled.isEmpty && reusedProblems.contains { $0.contains("another process") }, "a reused PID is not signalled")
    // Unknown identity: refused, and never taken as gone.
    var unknown = stubbed { _, n in n == 1 ? .running(birth: "A") : .unknown("EPERM") }
    try unknown.adopt("4243", what: "fixture")
    let unknownProblems = unknown.cleanUp()
    try expect(signalled.isEmpty && unknownProblems.count == 2, "an unknown identity is not signalled and not called gone")
    // The signal fails, and the process survives.
    var stuck = stubbed({ _, _ in .running(birth: "A") }, signal: EPERM)
    try stuck.adopt("4244", what: "fixture")
    let stuckProblems = stuck.cleanUp()
    try expect(signalled == [4244] && stuckProblems.contains { $0.contains("SIGTERM failed") }
               && stuckProblems.contains { $0.contains("still running") }, "a failed signal and a survivor are problems")
    // Already gone: nothing to do, no problem.
    var gone = stubbed { _, n in n == 1 ? .running(birth: "A") : .gone }
    try gone.adopt("4245", what: "fixture")
    try expect(gone.cleanUp().isEmpty && signalled == [4244], "a process already gone is fine and not signalled")
    // Bad PID text is refused at adoption.
    var bad = OwnedProcesses()
    try expect((try? bad.adopt("x1", what: "fixture")) == nil && (try? bad.adopt("1", what: "fixture")) == nil, "a non-PID is refused")
    // Outcomes: an earlier failure is kept; cleanup problems fail an otherwise passing run.
    let earlier = Failure("scenario failed")
    try expect((OwnedProcesses.outcome(failure: earlier, problems: ["p"]) as? Failure)?.description == earlier.description,
               "an earlier failure is preserved")
    try expect(OwnedProcesses.outcome(failure: nil, problems: ["p"]) != nil, "cleanup problems fail a passing run")
    try expect(OwnedProcesses.outcome(failure: nil, problems: []) == nil, "a clean run passes")
    // One real process of its own, ended and confirmed gone.
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["60"]
    try sleeper.run()
    var real = OwnedProcesses()
    real.settle = { sleeper.waitUntilExit() }
    try real.adopt(String(sleeper.processIdentifier), what: "own sleep")
    let realProblems = real.cleanUp()
    try expect(realProblems.isEmpty && OwnedProcesses.liveIdentity(sleeper.processIdentifier) == .gone,
               "its own sleep is ended and confirmed gone: \(realProblems)")
}
