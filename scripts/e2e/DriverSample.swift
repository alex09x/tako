/*
 * tako — Diagnostic main-thread samples of the driver's own app (off by default)
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */
import Darwin
import Foundation

/// Diagnosis only, never acceptance: sampling at 1 ms slows the app it
/// watches. Enabled only by TAKO_E2E_SAMPLE_DIR (an absolute directory);
/// without it every call is a no-op and the scenarios run exactly as before.
/// `/usr/bin/sample` watches only this driver's current app, re-identified
/// first; the sampler child is signalled only after its own birth and
/// executable are read again and match. Every start, wait and finish happens
/// outside a scenario's clocks. A sample's handle belongs to the scenario
/// that took it; finishing writes its record atomically, also on error.
final class OwnedAppSample {
    static let executable = "/usr/bin/sample"

    let label: String
    let seconds: Int
    let file: String
    let recordFile: String
    private(set) var blocks: [(name: String, start: TimeInterval, end: TimeInterval)] = []
    private(set) var problems: [String] = []
    private(set) var recordWritten = false
    private var process: Process?
    private var child = OwnedProcesses()
    private var adopted = false
    private var finished = false
    private let lock = NSLock()
    private var text = ""
    // Monotonic (systemUptime), recorded where they happen, not when finish looks.
    private var launchedAt: TimeInterval?
    private var readyAt: TimeInterval?
    private var terminatedAt: TimeInterval?

    init(label: String, seconds: Int, directory: String) {
        self.label = label; self.seconds = seconds
        file = directory + "/\(label).txt"
        recordFile = directory + "/\(label).json"
    }

    /// A timed interval (systemUptime) the sample has to cover.
    func cover(_ name: String, from start: TimeInterval, to end: TimeInterval) {
        blocks.append((name, start, end))
    }

    func refuse(_ reason: String) { problems.append(reason) }

    func start(pid: pid_t) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.executable)
        // Module and symbol names only: no -fullPaths, no environment.
        process.arguments = ["\(pid)", "\(seconds)", "1", "-mayDie", "-file", file]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let phrase = "Sampling process \(pid)"
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.lock.lock()
            self.text += String(decoding: data, as: UTF8.self)
            if self.readyAt == nil, self.text.contains(phrase) { self.readyAt = now }
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] _ in
            let now = ProcessInfo.processInfo.systemUptime
            guard let self else { return }
            self.lock.lock(); self.terminatedAt = now; self.lock.unlock()
        }
        launchedAt = ProcessInfo.processInfo.systemUptime
        do { try process.run() } catch {
            problems.append("sampler did not start: \(error)")
            return
        }
        self.process = process
        if case .running(let birth) = Driver.appIdentity(process.processIdentifier, expecting: Self.executable) {
            child.identity = { Driver.appIdentity($0, expecting: Self.executable) }
            child.adopt(pid: process.processIdentifier, birth: birth)
            adopted = true
        } else {
            problems.append("sampler child could not be identified")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline, process.isRunning, snapshot().ready == nil { usleep(10_000) }
        if snapshot().ready == nil {
            problems.append("sampler never reported it was sampling (denied or missing readiness): \(snapshot().text)")
        }
    }

    private func snapshot() -> (text: String, ready: TimeInterval?, terminated: TimeInterval?) {
        lock.lock(); defer { lock.unlock() }
        return (text, readyAt, terminatedAt)
    }

    /// Waits for the sampler's own end; a child that outlives its duration is
    /// stopped only when re-identified as the same /usr/bin/sample, else it
    /// is an unverified survivor and is never signalled. Judges coverage and
    /// writes the record. Idempotent; safe from a defer on any path.
    func finish() {
        guard !finished else { return }
        finished = true
        if let process {
            let planned = (launchedAt ?? ProcessInfo.processInfo.systemUptime) + Double(seconds)
            while process.isRunning, ProcessInfo.processInfo.systemUptime < planned + 10 { usleep(50_000) }
            if process.isRunning {
                let child = self.child
                problems.append(Self.survivor(pid: process.processIdentifier, seconds: seconds, adopted: adopted) { child.cleanUp() })
            } else {
                // The termination handler records the time; give it a moment.
                let until = ProcessInfo.processInfo.systemUptime + 1
                while snapshot().terminated == nil, ProcessInfo.processInfo.systemUptime < until { usleep(10_000) }
                if process.terminationStatus != 0 { problems.append("sampler exit status \(process.terminationStatus)") }
            }
            (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        }
        let seen = snapshot()
        let written = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? Int) ?? 0
        problems += Self.coverageProblems(launched: launchedAt, ready: seen.ready, terminated: seen.terminated,
                                          seconds: Double(seconds), blocks: blocks,
                                          completed: seen.text.contains("Sampling completed"), written: written)
        persist(seen)
    }

    /// Pure. The sampled window is estimated conservatively: from when the
    /// sampler said it was sampling to the earlier of its planned end (launch
    /// plus duration) and its termination. When finish noticed the end plays
    /// no part. Returns why the required blocks are not covered.
    static func coverageProblems(launched: TimeInterval?, ready: TimeInterval?, terminated: TimeInterval?, seconds: Double,
                                 blocks: [(name: String, start: TimeInterval, end: TimeInterval)],
                                 completed: Bool, written: Int) -> [String] {
        guard let launched, let ready else { return ["no sampling window (never ready)"] }
        var found: [String] = []
        if blocks.isEmpty { found.append("no timed block was recorded for this sample") }
        if !completed { found.append("sampler did not report completion") }
        if written <= 0 { found.append("no sample file was written") }
        let end = window(launched: launched, ready: ready, terminated: terminated, seconds: seconds).end
        for block in blocks where block.start < ready || block.end > end {
            found.append(String(format: "%@ [%.3f, %.3f] outside the estimated sampled window [%.3f, %.3f]",
                                block.name, block.start, block.end, ready, end))
        }
        return found
    }

    /// Pure: what a sampler still running after its deadline gets. An
    /// unidentified child is never signalled; an identified one only through
    /// the fail-closed cleanup, which re-reads its birth and executable.
    static func survivor(pid: pid_t, seconds: Int, adopted: Bool, cleanUp: () -> [String]) -> String {
        guard adopted else { return "sampler survivor pid \(pid) unverified; not signalled" }
        let cleanup = cleanUp()
        return cleanup.isEmpty ? "sampler outlived \(seconds) s; stopped after re-identification"
                               : "sampler outlived \(seconds) s: \(cleanup.joined(separator: "; "))"
    }

    static func window(launched: TimeInterval, ready: TimeInterval, terminated: TimeInterval?, seconds: Double)
        -> (start: TimeInterval, end: TimeInterval) {
        (ready, min(launched + seconds, terminated ?? .infinity))
    }

    /// Writes the record next to the sample, atomically; a failed write is a problem.
    private func persist(_ seen: (text: String, ready: TimeInterval?, terminated: TimeInterval?)) {
        var record: [String: Any] = [
            "label": label, "seconds": seconds, "file": file,
            "launched_uptime": launchedAt ?? NSNull(), "ready_uptime": seen.ready ?? NSNull(),
            "terminated_uptime": seen.terminated ?? NSNull(),
            "blocks": blocks.map { ["name": $0.name, "start_uptime": $0.start, "end_uptime": $0.end] },
        ]
        if let launched = launchedAt, let ready = seen.ready {
            let w = Self.window(launched: launched, ready: ready, terminated: seen.terminated, seconds: Double(seconds))
            record["sampling_window_estimate"] = ["start_uptime": w.start, "end_uptime": w.end,
                                                  "note": "conservative estimate: readiness as observed to the earlier of planned end and termination"]
        }
        record["problems"] = problems
        record["complete"] = problems.isEmpty
        do {
            let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: recordFile), options: .atomic)
            recordWritten = true
        } catch {
            problems.append("sample record not written: \(error)")
        }
    }

    var complete: Bool { finished && recordWritten && problems.isEmpty }
}

extension Driver {
    /// A sample of this driver's current app, or nil when diagnosis is off.
    /// The caller owns the handle and must finish it (a defer does).
    func sampleOwnedApp(label: String, seconds: Int) -> OwnedAppSample? {
        guard let directory = ProcessInfo.processInfo.environment["TAKO_E2E_SAMPLE_DIR"], directory.hasPrefix("/") else {
            return nil
        }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let sample = OwnedAppSample(label: label, seconds: seconds, directory: directory)
        if let owned = ownedApps.last(where: { $0.pid == pid }), case .running(let current) = identify(pid), current == owned.birth {
            sample.start(pid: pid)
        } else {
            sample.refuse("the driver's current app could not be re-identified; not sampled")
        }
        return sample
    }
}

/// After a scenario's own assertions: exactly these samples, all finished,
/// recorded and complete -- or the diagnostic fails. Off: nothing to check.
func requireCompleteSamples(_ samples: [OwnedAppSample?], expected: Int = 1) throws {
    guard ProcessInfo.processInfo.environment["TAKO_E2E_SAMPLE_DIR"] != nil else { return }
    let taken = samples.compactMap { $0 }
    guard taken.count == expected, samples.count == expected else {
        throw Failure("diagnostic sampling was on but \(taken.count) of \(expected) required samples were taken")
    }
    taken.forEach { $0.finish() }
    let incomplete = taken.filter { !$0.complete }
    guard incomplete.isEmpty else {
        throw Failure("diagnostic samples incomplete: " + incomplete.map { "\($0.label): \($0.problems.joined(separator: ", "))" }.joined(separator: "; "))
    }
    print("diagnostic samples complete: \(taken.map(\.label).joined(separator: ", "))")
}

/// Pure checks of the window estimate, coverage and stop authorization.
func runSampleSelfTest() throws {
    func expect(_ ok: Bool, _ what: String) throws { if !ok { throw Failure("sample: \(what)") }; print("  ok: \(what)") }
    typealias Block = (name: String, start: TimeInterval, end: TimeInterval)
    let click: [Block] = [(name: "click", start: 10.2, end: 10.4)]
    func problems(launched: TimeInterval = 9.9, ready: TimeInterval? = 10, terminated: TimeInterval? = 12.95,
                  blocks: [Block] = click, completed: Bool = true, written: Int = 9) -> [String] {
        OwnedAppSample.coverageProblems(launched: launched, ready: ready, terminated: terminated, seconds: 3,
                                        blocks: blocks, completed: completed, written: written)
    }
    try expect(problems().isEmpty, "a block inside the estimated window is covered")
    try expect(!problems(ready: 10.3).isEmpty, "a late readiness does not cover a block that began before it")
    try expect(!problems(terminated: 10.3).isEmpty, "a sampler that ended early does not cover the rest")
    try expect(!problems(ready: nil, terminated: nil, completed: false, written: 0).isEmpty, "never ready is incomplete")
    try expect(!problems(completed: false).isEmpty, "no completion line is incomplete")
    try expect(!problems(blocks: []).isEmpty, "no recorded timed block is incomplete")
    // Delayed finish: when finish noticed the end is not an input; the planned
    // end (launch + duration) bounds the window even if termination came late.
    let late: [Block] = [(name: "late click", start: 12.95, end: 13.2)]
    try expect(!problems(terminated: 40, blocks: late).isEmpty, "a late termination does not stretch the window past launch + duration")
    try expect(OwnedAppSample.window(launched: 9.9, ready: 10, terminated: nil, seconds: 3).end == 12.9,
               "with no termination time the window ends at the planned end")
    // Survivors: an unidentified child is never signalled.
    var cleaned = 0
    let unverified = OwnedAppSample.survivor(pid: 4242, seconds: 3, adopted: false) { cleaned += 1; return [] }
    try expect(unverified.contains("unverified; not signalled") && cleaned == 0, "an unidentified survivor is not signalled")
    // Stop authorization: only a child whose birth and executable match is signalled.
    var signals: [Int32] = []
    var changed = OwnedProcesses()
    changed.identity = { _ in .unknown("pid 4242 runs /bin/sh, not \(OwnedAppSample.executable)") }
    changed.signal = { signals.append($0); return 0 }
    changed.settle = {}
    changed.adopt(pid: 4242, birth: "1 \(OwnedAppSample.executable)")
    let reused = OwnedAppSample.survivor(pid: 4242, seconds: 3, adopted: true) { changed.cleanUp() }
    try expect(reused.contains("not signalled") && signals.isEmpty, "a reused sampler pid is never signalled and is a problem")
    var same = OwnedProcesses()
    var alive = true
    same.identity = { _ in alive ? .running(birth: "1 \(OwnedAppSample.executable)") : .gone }
    same.signal = { signals.append($0); alive = false; return 0 }
    same.settle = {}
    same.adopt(pid: 4243, birth: "1 \(OwnedAppSample.executable)")
    let stopped = OwnedAppSample.survivor(pid: 4243, seconds: 3, adopted: true) { same.cleanUp() }
    try expect(stopped.contains("stopped after re-identification") && signals == [4243],
               "the same sampler child is signalled once, confirmed gone, and still marks the sample incomplete")
}
