/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Darwin
import Foundation
import Testing
@testable import Tako

extension RuntimeCommandTests {
    @Test func aHelperThatIgnoresSIGTERMIsEndedWithinBounds() throws {
        let h = try helper("trap '' TERM\nwhile :; do sleep 1; done")
        defer { try? FileManager.default.removeItem(at: h) }
        let started = Date()
        #expect(RuntimeCommand.run(h, [], environment: [:], timeout: 0.5) == nil)
        // The timeout, a second of grace, then SIGKILL and reaping.
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test func anAnswerLongerThanTheCapIsNoAnswer() throws {
        let h = try helper("head -c \(RuntimeCommand.outputLimit + 4096) /dev/zero | tr '\\\\0' 'x'")
        defer { try? FileManager.default.removeItem(at: h) }
        #expect(RuntimeCommand.run(h, [], environment: [:], timeout: 5) == nil)
    }

    @Test func aCompleteAnswerIsReturnedWithItsStatus() throws {
        let h = try helper("printf 'name=abc\\tpid=12\\n'; exit 3")
        defer { try? FileManager.default.removeItem(at: h) }
        let result = try #require(RuntimeCommand.run(h, ["list"], environment: [:], timeout: 5))
        #expect(result.status == 3)
        #expect(result.output == "name=abc\tpid=12\n")
    }

    @Test func listingIsExactAndUnknownWhenTheHelperFails() throws {
        let listed = try helper("printf 'name=abcd\\tpid=1\\nname=abc\\tpid=2\\n'")
        let failing = try helper("exit 1")
        defer {
            try? FileManager.default.removeItem(at: listed)
            try? FileManager.default.removeItem(at: failing)
        }
        #expect(RuntimeCommand.isListed(listed, name: "abc", environment: [:]) == true)
        #expect(RuntimeCommand.isListed(listed, name: "ab", environment: [:]) == false)
        #expect(RuntimeCommand.isListed(failing, name: "abc", environment: [:]) == nil)
    }
}

/// Ending a closed terminal's session, against stand-in runtimes.
@Suite
struct SessionEndingTests {
    private func setUp(listing: String) throws -> (Ending, SessionRecordStore, URL, SessionNamespace) {
        let root = URL(fileURLWithPath: "/tmp/tke-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runtime = root.appendingPathComponent("zmx")
        // `kill` does nothing; `list` prints what the case says.
        try Data("#!/bin/sh\n[ \"$1\" = list ] && printf '\(listing)'\nexit 0\n".utf8).write(to: runtime)
        chmod(runtime.path, 0o755)
        let ns = try SessionNamespace.open(runtimeID: "0.8.1-cc9574e03dfb2480", home: root)
        let records = SessionRecordStore(directory: root.appendingPathComponent("records"))
        let id = UUID()
        try records.write(SessionRecord(id: id, runtimeID: "0.8.1-cc9574e03dfb2480", generation: "gen1",
                                        state: .attached, createdAt: Date()))
        let owner = try SessionOwnerLock(namespace: ns, name: "abc")
        let ending = Ending(runtime: runtime, name: "abc", environment: [:], records: records, id: id,
                            generation: "gen1", owner: owner)
        return (ending, records, root, ns)
    }

    @Test func aSessionConfirmedGoneTakesItsRecordWithIt() throws {
        let (ending, records, root, _) = try setUp(listing: "")
        defer { try? FileManager.default.removeItem(at: root) }
        ending.run(reportFailure: false)
        #expect(records.read(ending.id) == .none)
    }

    @Test func aSessionStillListedKeepsItsRecordMarked() throws {
        let (ending, records, root, _) = try setUp(listing: "name=abc\\tpid=1\\n")
        defer { try? FileManager.default.removeItem(at: root) }
        ending.run(reportFailure: false)
        guard case .record(let r) = records.read(ending.id) else { Issue.record("record gone"); return }
        #expect(r.state == .error(Ending.closedButRunning))
    }

    @Test func aSessionAnotherGenerationMadeIsNotEnded() throws {
        let (ending, records, root, _) = try setUp(listing: "")
        defer { try? FileManager.default.removeItem(at: root) }
        guard case .record(var r) = records.read(ending.id) else { return }
        r.generation = "gen2"
        try records.write(r)
        ending.run(reportFailure: false)
        #expect(records.read(ending.id) == .record(r))
    }

    @Test func theOwnerLockIsHeldUntilTheEndingIsDone() throws {
        let (ending, _, root, ns) = try setUp(listing: "")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: SessionOwnerLock.Failure.heldElsewhere) { try SessionOwnerLock(namespace: ns, name: "abc") }
        _ = ending
    }

    @Test func aFailedEndingStaysPendingUntilLeftRunning() throws {
        let (ending, records, root, _) = try setUp(listing: "name=abc\\tpid=1\\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let before = Ending.pendingCount
        ending.start(reportFailure: false)
        Ending.settleBeforeQuit(within: 6)
        // Not settled: still pending, and its record says so.
        #expect(Ending.pendingCount == before + 1)
        guard case .record(let r) = records.read(ending.id) else { Issue.record("record gone"); return }
        #expect(r.state == .error(Ending.closedButRunning))
        ending.leaveRunning()
        #expect(Ending.pendingCount == before)
        #expect(records.read(ending.id) == .none)
    }

    @Test func quittingWaitsForAnEndingUnderWay() throws {
        // `kill` takes a second; the ending must be waited for and settle.
        let root = URL(fileURLWithPath: "/tmp/tke-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("zmx")
        try Data("#!/bin/sh\n[ \"$1\" = kill ] && sleep 1\nexit 0\n".utf8).write(to: runtime)
        chmod(runtime.path, 0o755)
        let ns = try SessionNamespace.open(runtimeID: "0.8.1-cc9574e03dfb2480", home: root)
        let records = SessionRecordStore(directory: root.appendingPathComponent("records"))
        let id = UUID()
        try records.write(SessionRecord(id: id, runtimeID: "0.8.1-cc9574e03dfb2480", generation: "g",
                                        state: .attached, createdAt: Date()))
        let ending = Ending(runtime: runtime, name: "abc", environment: [:], records: records, id: id,
                            generation: "g", owner: try SessionOwnerLock(namespace: ns, name: "abc"))
        let before = Ending.pendingCount
        ending.start(reportFailure: false)
        Ending.settleBeforeQuit(within: 6)
        #expect(Ending.pendingCount == before)
        #expect(records.read(id) == .none)
    }
    @Test func aRetryIsWaitedForIfQuitHappensConcurrently() throws {
        let root = URL(fileURLWithPath: "/tmp/tke-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("zmx")
        // If flag file 'f' exists, the script sleeps 1 sec and then succeeds (closing the session)
        // Otherwise, it fails immediately to simulate the first failed attempt.
        try Data("#!/bin/sh\nif [ \"$1\" = list ]; then\n  if [ -f \"$T/f\" ]; then\n    exit 0\n  else\n    printf \"name=abc\\tpid=1\\n\"\n    exit 0\n  fi\nelif [ \"$1\" = kill ]; then\n  if [ -f \"$T/f\" ]; then\n    sleep 1\n    exit 0\n  else\n    echo \"kill failed\" >&2\n    exit 1\n  fi\nfi\n".utf8).write(to: runtime)
        chmod(runtime.path, 0o755)
        
        let ns = try SessionNamespace.open(runtimeID: "0.8.1", home: root)
        let records = SessionRecordStore(directory: root.appendingPathComponent("records"))
        let id = UUID()
        try records.write(SessionRecord(id: id, runtimeID: "0.8.1", generation: "g", state: .attached, createdAt: Date()))
        let ending = Ending(runtime: runtime, name: "abc", environment: ["T": root.path], records: records, id: id, generation: "g", owner: try SessionOwnerLock(namespace: ns, name: "abc"))
        
        // 1. Fail first attempt
        let before = Ending.pendingCount
        ending.start(reportFailure: false)
        // Since reportFailure is false, run() returns false when it fails, and it's kept in pending, marked closedButRunning
        Ending.settleBeforeQuit(within: 2) // wait for first attempt to fail
        #expect(Ending.pendingCount == before + 1)
        
        // 2. Setup retry to succeed slowly
        try Data().write(to: root.appendingPathComponent("f"))
        
        // 3. Start retry and concurrently quit
        // We have to emulate what `askAgain` returning true does: drain the signal and async run
        _ = ending.attemptFinished.wait(timeout: .now())
        DispatchQueue.global(qos: .utility).async { _ = ending.run(reportFailure: false) }
        
        // Give the global queue a tiny head start so `run()` executes, but we want to make sure settleBeforeQuit WAITS for it
        Thread.sleep(forTimeInterval: 0.1)
        
        Ending.settleBeforeQuit(within: 6)
        
        // The retry should have successfully cleared the session record and removed it from pending
        #expect(Ending.pendingCount == before)
        #expect(records.read(id) == .none)
    }

    @Test func leftoversAreFoundByTheirRecordState() throws {
        let root = URL(fileURLWithPath: "/tmp/tke-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let records = SessionRecordStore(directory: root.appendingPathComponent("records"))
        let left = SessionRecord(id: UUID(), runtimeID: "0.8.1-cc9574e03dfb2480", generation: "a",
                                 state: .error(Ending.closedButRunning), createdAt: Date())
        let other = SessionRecord(id: UUID(), runtimeID: "0.8.1-cc9574e03dfb2480", generation: "b",
                                  state: .detached, createdAt: Date())
        try records.write(left)
        try records.write(other)
        #expect(Set(records.all().map(\.id)) == [left.id, other.id])
        #expect(records.all().filter { $0.state == .error(Ending.closedButRunning) }.map(\.id) == [left.id])
    }
}

@Suite
@MainActor
struct SessionPersistenceScopeTests {
    /// The quick terminal is never restored, so even with the setting on
    /// its shell is not put in a session that would outlive Tako.
    @Test func aTerminalThatIsNeverRestoredGetsNoSession() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tako")
        try "session-persistence = true\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let app = Tako.App(configPath: url.path)
        var config = Tako.SurfaceConfiguration()
        config.allowsSessionPersistence = false
        let surface = Tako.SurfaceView(app, baseConfig: config)
        defer { surface.close() }

        #expect(surface.persistence == nil)
        #expect(!surface.hadPersistentSession)
        #expect(surface.pty != nil)
    }
}

extension SessionPersistenceScopeTests {
    /// Every way the quick terminal makes a surface goes through one policy.
    @Test func everyQuickTerminalSurfaceIsKeptOutOfPersistence() {
        #expect(!QuickTerminalController.surfaceConfiguration(nil).allowsSessionPersistence)
        var split = Tako.SurfaceConfiguration()
        split.workingDirectory = "/tmp"
        let made = QuickTerminalController.surfaceConfiguration(split)
        #expect(!made.allowsSessionPersistence)
        #expect(made.workingDirectory == "/tmp")
        #expect(made.environmentVariables["TAKO_QUICK_TERMINAL"] == "1")
    }
}
