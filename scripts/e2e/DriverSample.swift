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
/// outside a scenario's clocks; the timed blocks a sample must cover are
/// recorded, and a sample that did not cover them is incomplete.
final class OwnedAppSample {
    static let executable = "/usr/bin/sample"
    static var all: [OwnedAppSample] = []

    let label: String
    let seconds: Int
    let file: String
    private(set) var readyAt: TimeInterval?
    private(set) var endedAt: TimeInterval?
    private(set) var blocks: [(name: String, start: TimeInterval, end: TimeInterval)] = []
    private(set) var problems: [String] = []
    private(set) var cleanup: [String] = []
    private var process: Process?
    private var child = OwnedProcesses()
    private var finished = false
    private let output = NSLock()
    private var text = ""

    init(label: String, seconds: Int, file: String) {
        self.label = label; self.seconds = seconds; self.file = file
    }

    /// A timed interval (systemUptime) the sample has to cover.
    func cover(_ name: String, from start: TimeInterval, to end: TimeInterval) {
        blocks.append((name, start, end))
    }

    func start(pid: pid_t) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.executable)
        // Module and symbol names only: no -fullPaths, no environment.
        process.arguments = ["\(pid)", "\(seconds)", "1", "-mayDie", "-file", file]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.output.lock(); self.text += String(decoding: data, as: UTF8.self); self.output.unlock()
        }
        do { try process.run() } catch {
            problems.append("sampler did not start: \(error)")
            return
        }
        self.process = process
        guard case .running(let birth) = Driver.appIdentity(process.processIdentifier, expecting: Self.executable) else {
            problems.append("sampler child could not be identified")
            return
        }
        child.identity = { Driver.appIdentity($0, expecting: Self.executable) }
        child.adopt(pid: process.processIdentifier, birth: birth)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline, process.isRunning {
            if said("Sampling process \(pid)") { readyAt = ProcessInfo.processInfo.systemUptime; return }
            usleep(10_000)
        }
        problems.append("sampler never reported it was sampling (denied or missing readiness): \(said())")
    }

    private func said(_ phrase: String? = nil) -> Bool { phrase.map { said().contains($0) } ?? false }
    private func said() -> String { output.lock(); defer { output.unlock() }; return text }

    /// Waits for the sampler's own end, stops only a re-identified child that
    /// outlives its duration, and judges completeness. Idempotent.
    func finish() {
        guard !finished else { return }
        finished = true
        if let process {
            let deadline = (readyAt ?? ProcessInfo.processInfo.systemUptime) + Double(seconds) + 10
            while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { usleep(50_000) }
            if process.isRunning {
                cleanup = child.cleanUp()
                problems.append("sampler outlived \(seconds) s and was stopped")
            } else {
                endedAt = ProcessInfo.processInfo.systemUptime
                if process.terminationStatus != 0 { problems.append("sampler exit status \(process.terminationStatus)") }
            }
            (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        }
        problems += Self.coverageProblems(ready: readyAt, ended: endedAt, seconds: Double(seconds), blocks: blocks,
                                          completed: said().contains("Sampling completed"),
                                          written: (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? Int) ?? 0)
        problems += cleanup
    }

    /// Pure: which required blocks this sample's interval does not cover.
    static func coverageProblems(ready: TimeInterval?, ended: TimeInterval?, seconds: Double,
                                 blocks: [(name: String, start: TimeInterval, end: TimeInterval)],
                                 completed: Bool, written: Int) -> [String] {
        var found: [String] = []
        guard let ready else { return ["no sampling interval (never ready)"] }
        if blocks.isEmpty { found.append("no timed block was recorded for this sample") }
        if !completed { found.append("sampler did not report completion") }
        if written <= 0 { found.append("no sample file was written") }
        let windowEnd = min(ready + seconds, ended ?? ready + seconds)
        for block in blocks where block.start < ready || block.end > windowEnd {
            found.append(String(format: "%@ [%.3f, %.3f] outside the sampled [%.3f, %.3f]",
                                block.name, block.start, block.end, ready, windowEnd))
        }
        return found
    }

    var record: [String: Any] {
        ["label": label, "seconds": seconds, "file": file, "ready": readyAt ?? NSNull(), "ended": endedAt ?? NSNull(),
         "blocks": blocks.map { ["name": $0.name, "start": $0.start, "end": $0.end] },
         "complete": finished && problems.isEmpty, "problems": problems]
    }
}

extension Driver {
    /// A sample of this driver's current app, or nil when diagnosis is off.
    func sampleOwnedApp(label: String, seconds: Int) -> OwnedAppSample? {
        guard let directory = ProcessInfo.processInfo.environment["TAKO_E2E_SAMPLE_DIR"], directory.hasPrefix("/") else {
            return nil
        }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let sample = OwnedAppSample(label: label, seconds: seconds, file: directory + "/\(label).txt")
        OwnedAppSample.all.append(sample)
        guard let owned = ownedApps.last(where: { $0.pid == pid }),
              case .running(let current) = identify(pid), current == owned.birth else {
            sample.finish()
            return sample
        }
        sample.start(pid: pid)
        return sample
    }

    /// After a scenario's own assertions: every sample finished, written to
    /// samples.json, and complete -- or the diagnostic fails.
    func requireCompleteSamples() throws {
        guard let directory = ProcessInfo.processInfo.environment["TAKO_E2E_SAMPLE_DIR"] else { return }
        // This scenario's samples only; the next scenario starts a new list.
        let mine = OwnedAppSample.all
        OwnedAppSample.all = []
        mine.forEach { $0.finish() }
        guard let first = mine.first else { throw Failure("diagnostic sampling was on but this scenario took no sample") }
        if let data = try? JSONSerialization.data(withJSONObject: mine.map(\.record), options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: directory + "/samples-\(first.label).json"))
        }
        let incomplete = mine.filter { !$0.problems.isEmpty }
        guard incomplete.isEmpty else {
            throw Failure("diagnostic samples incomplete: " + incomplete.map { "\($0.label): \($0.problems.joined(separator: ", "))" }.joined(separator: "; "))
        }
        print("diagnostic samples complete: \(mine.map(\.label).joined(separator: ", "))")
    }
}

/// Pure checks of coverage and of the sampler's stop authorization.
func runSampleSelfTest() throws {
    func expect(_ ok: Bool, _ what: String) throws { if !ok { throw Failure("sample: \(what)") }; print("  ok: \(what)") }
    let block = [(name: "click", start: 10.2, end: 10.4)]
    try expect(OwnedAppSample.coverageProblems(ready: 10, ended: 13.1, seconds: 3, blocks: block, completed: true, written: 9).isEmpty,
               "a block inside the sampled interval is covered")
    try expect(!OwnedAppSample.coverageProblems(ready: 10.3, ended: 13.1, seconds: 3, blocks: block, completed: true, written: 9).isEmpty,
               "a block that began before sampling is not covered")
    try expect(!OwnedAppSample.coverageProblems(ready: 10, ended: 10.3, seconds: 3, blocks: block, completed: true, written: 9).isEmpty,
               "a sampler that ended early does not cover the rest")
    try expect(!OwnedAppSample.coverageProblems(ready: nil, ended: nil, seconds: 3, blocks: block, completed: false, written: 0).isEmpty,
               "a sampler that never became ready is incomplete")
    try expect(!OwnedAppSample.coverageProblems(ready: 10, ended: 13.1, seconds: 3, blocks: block, completed: false, written: 9).isEmpty,
               "a sampler without its completion line is incomplete")
    try expect(!OwnedAppSample.coverageProblems(ready: 10, ended: 13.1, seconds: 3, blocks: [], completed: true, written: 9).isEmpty,
               "a sample with no recorded timed block is incomplete")
    // Stop authorization: only a child whose birth and executable match is signalled.
    var signals: [Int32] = []
    var changed = OwnedProcesses()
    changed.identity = { _ in .unknown("pid 4242 runs /bin/sh, not \(OwnedAppSample.executable)") }
    changed.signal = { signals.append($0); return 0 }
    changed.settle = {}
    changed.adopt(pid: 4242, birth: "1 \(OwnedAppSample.executable)")
    try expect(!changed.cleanUp().isEmpty && signals.isEmpty, "an unknown or reused sampler pid is never signalled and is a problem")
    var same = OwnedProcesses()
    var alive = true
    same.identity = { _ in alive ? .running(birth: "1 \(OwnedAppSample.executable)") : .gone }
    same.signal = { signals.append($0); alive = false; return 0 }
    same.settle = {}
    same.adopt(pid: 4243, birth: "1 \(OwnedAppSample.executable)")
    try expect(same.cleanUp().isEmpty && signals == [4243], "the same sampler child is signalled once and confirmed gone")
}
