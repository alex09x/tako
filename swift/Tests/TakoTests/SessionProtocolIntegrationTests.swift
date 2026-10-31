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

@Suite struct SessionProtocolIntegrationTests {

    private struct Binaries {
        let newZmx: URL
        let oldZmx: URL
    }

    private func locateBinaries() -> Binaries? {
        let env = ProcessInfo.processInfo.environment
        guard let newPath = env["TAKO_TEST_NEW_ZMX"],
              let oldPath = env["TAKO_TEST_OLD_ZMX"],
              FileManager.default.isExecutableFile(atPath: newPath),
              FileManager.default.isExecutableFile(atPath: oldPath) else {
            return nil
        }
        return Binaries(
            newZmx: URL(fileURLWithPath: newPath),
            oldZmx: URL(fileURLWithPath: oldPath)
        )
    }

    private func startDetachedDaemon(
        runtime: URL,
        name: String,
        generation: String,
        command: [String] = ["/bin/sh", "-c", "sleep 30"],
        environment: [String: String]
    ) throws {
        let pty = try #require(
            PTY(
                cols: 80,
                rows: 24,
                workingDirectory: "/tmp",
                program: [runtime.path, "attach", "--labels", "tako-gen=\(generation)", name] + command,
                environment: environment,
                removing: SessionNamespace.inheritedVariablesToDrop
            )
        )
        defer { pty.terminate() }
        let ready = waitUntil(timeout: 5) {
            guard let get = RuntimeCommand.run(runtime, ["get", name], environment: environment),
                  get.status == 0 else { return false }
            return Reattach.labels(from: get.output)?["tako-gen"] == generation
        }
        #expect(ready)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TAKO_TEST_NEW_ZMX"] != nil && ProcessInfo.processInfo.environment["TAKO_TEST_OLD_ZMX"] != nil)) func newDaemonEnforcesAtomicGenerationOnKillAndAttachAndResistsReplacementRaces() throws {
        let bins = try #require(locateBinaries())
        let home = Home()
        defer { home.tearDown() }
        let ns = try SessionNamespace.open(runtimeID: runtimeID, home: home.url)
        let env = ns.environment
        let name = SessionNamespace.sessionName(for: UUID())
        defer {
            _ = RuntimeCommand.run(bins.newZmx, ["kill", name, "--force"], environment: env, timeout: 2)
        }

        // 1. Attach-only against a missing session fails closed without creating a daemon or socket.
        let missingArgs = [bins.newZmx.path] + RuntimeCommand.attachOnlyIfGenerationArguments(
            name: name,
            generation: "gen1",
            attempt: "att0"
        )
        let missingCheck = try #require(
            PTY(
                cols: 80,
                rows: 24,
                workingDirectory: "/tmp",
                program: missingArgs,
                environment: env,
                removing: SessionNamespace.inheritedVariablesToDrop
            )
        )
        defer { missingCheck.terminate() }
        #expect(waitUntil(timeout: 3) { missingCheck.exitStatus == 1 })
        #expect(RuntimeCommand.isListed(bins.newZmx, name: name, environment: env) == false)

        // 2. Create-only atomically binds `name` with `gen1`, and a second create-only on the same `name`
        // fails closed (`exitStatus == 1`) without attaching or overwriting `tako-gen=gen1` with `gen-intruder`.
        let created1 = try #require(
            PTY(
                cols: 80,
                rows: 24,
                workingDirectory: "/tmp",
                program: [bins.newZmx.path] + RuntimeCommand.createOnlyWithGenerationArguments(
                    name: name,
                    generation: "gen1",
                    attempt: "att1",
                    command: ["/bin/sh", "-c", "while true; do printf 'NOISY_LINE\\n'; sleep 0.01; done"]
                ),
                environment: env,
                removing: SessionNamespace.inheritedVariablesToDrop
            )
        )
        defer { created1.terminate() }
        #expect(waitUntil(timeout: 5) {
            guard let get = RuntimeCommand.run(bins.newZmx, ["get", name], environment: env),
                  get.status == 0 else { return false }
            let labels = Reattach.labels(from: get.output)
            return labels?["tako-gen"] == "gen1" && labels?["tako-attempt"] == "att1"
        })
        // Repeated `zmx get` probes under continuous output never fail with Unexpected.
        for _ in 0..<5 {
            let probe = try #require(RuntimeCommand.run(bins.newZmx, ["get", name], environment: env))
            #expect(probe.status == 0)
            #expect(Reattach.labels(from: probe.output)?["tako-gen"] == "gen1")
        }

        let collidingCreate = try #require(
            PTY(
                cols: 80,
                rows: 24,
                workingDirectory: "/tmp",
                program: [bins.newZmx.path] + RuntimeCommand.createOnlyWithGenerationArguments(
                    name: name,
                    generation: "gen-intruder",
                    attempt: "att-intruder",
                    command: ["/bin/sh", "-c", "sleep 30"]
                ),
                environment: env,
                removing: SessionNamespace.inheritedVariablesToDrop
            )
        )
        defer { collidingCreate.terminate() }
        #expect(waitUntil(timeout: 3) { collidingCreate.exitStatus == 1 })
        let labelsAfterCollision = try #require(RuntimeCommand.run(bins.newZmx, ["get", name], environment: env))
        #expect(Reattach.labels(from: labelsAfterCollision.output) == ["tako-gen": "gen1", "tako-attempt": "att1"])

        // 3. Simulate external socket replacement on `name` with `gen2` BEFORE `gen1` exits:
        //    When `gen1` subsequently exits (via its still-connected client `created1`), its shutdown
        //    closes only its own listen descriptor without unlinking `name` by pathname, so `gen2`'s
        //    replaced socket on `name` is never deleted.
        let sockURL = ns.directory.appendingPathComponent(name)
        try FileManager.default.removeItem(at: sockURL)
        try startDetachedDaemon(runtime: bins.newZmx, name: name, generation: "gen2", environment: env)
        let gen2PID = try #require(RuntimeCommand.sessionPID(bins.newZmx, name: name, environment: env))

        created1.write(Array("\u{03}exit\r".utf8))
        created1.terminate()
        usleep(100_000)

        #expect(FileManager.default.fileExists(atPath: sockURL.path) == true)
        #expect(RuntimeCommand.isListed(bins.newZmx, name: name, environment: env) == true)
        #expect(RuntimeCommand.sessionPID(bins.newZmx, name: name, environment: env) == gen2PID)

        // Stale caller holding `gen1` cannot kill `gen2`.
        #expect(RuntimeCommand.killIfGeneration(bins.newZmx, name: name, generation: "gen1", environment: env) != .killed)
        #expect(RuntimeCommand.isListed(bins.newZmx, name: name, environment: env) == true)

        // Stale caller holding `gen1` cannot attach-only or mutate labels (`tako-attempt`) on `gen2`.
        let wrongAttach = try #require(
            PTY(
                cols: 80,
                rows: 24,
                workingDirectory: "/tmp",
                program: [bins.newZmx.path] + RuntimeCommand.attachOnlyIfGenerationArguments(
                    name: name,
                    generation: "gen1",
                    attempt: "wrong-att"
                ),
                environment: env,
                removing: SessionNamespace.inheritedVariablesToDrop
            )
        )
        defer { wrongAttach.terminate() }
        #expect(waitUntil(timeout: 3) { wrongAttach.exitStatus == 1 })
        let getAfterWrong = try #require(RuntimeCommand.run(bins.newZmx, ["get", name], environment: env))
        #expect(Reattach.labels(from: getAfterWrong.output) == ["tako-gen": "gen2"])

        // Matching caller holding `gen2` atomically sets `tako-attempt=ok-att` and attaches.
        let rightAttach = try #require(
            PTY(
                cols: 80,
                rows: 24,
                workingDirectory: "/tmp",
                program: [bins.newZmx.path] + RuntimeCommand.attachOnlyIfGenerationArguments(
                    name: name,
                    generation: "gen2",
                    attempt: "ok-att"
                ),
                environment: env,
                removing: SessionNamespace.inheritedVariablesToDrop
            )
        )
        defer { rightAttach.terminate() }
        #expect(waitUntil(timeout: 3) {
            guard let get = RuntimeCommand.run(bins.newZmx, ["get", name], environment: env),
                  get.status == 0 else { return false }
            let labels = Reattach.labels(from: get.output)
            return labels?["tako-gen"] == "gen2" && labels?["tako-attempt"] == "ok-att"
        })
        #expect(rightAttach.exitStatus == nil)
        rightAttach.terminate()

        // Matching conditional kill ends `gen2`, leaving the stale socket entry on disk (`isListed == false`)
        // without unlinking by pathname during daemon shutdown or `zmx list`.
        #expect(RuntimeCommand.killIfGeneration(bins.newZmx, name: name, generation: "gen2", environment: env) == .killed)
        #expect(RuntimeCommand.isListed(bins.newZmx, name: name, environment: env) == false)
        #expect(FileManager.default.fileExists(atPath: sockURL.path) == true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TAKO_TEST_NEW_ZMX"] != nil && ProcessInfo.processInfo.environment["TAKO_TEST_OLD_ZMX"] != nil)) func oldDaemonFailsClosedAgainstNewClientAndOldClientWorksAgainstNewDaemon() throws {
        let bins = try #require(locateBinaries())
        let home = Home()
        defer { home.tearDown() }
        let ns = try SessionNamespace.open(runtimeID: runtimeID, home: home.url)
        let env = ns.environment
        let oldName = SessionNamespace.sessionName(for: UUID())
        let newName = SessionNamespace.sessionName(for: UUID())
        defer {
            _ = RuntimeCommand.run(bins.oldZmx, ["kill", oldName, "--force"], environment: env, timeout: 2)
            _ = RuntimeCommand.run(bins.newZmx, ["kill", oldName, "--force"], environment: env, timeout: 2)
            _ = RuntimeCommand.run(bins.newZmx, ["kill", newName, "--force"], environment: env, timeout: 2)
        }

        // A. Old daemon + New client:
        // 1. Conditional kill (`Tag.KillIfLabel`) against an old daemon still fails closed without killing it.
        try startDetachedDaemon(
            runtime: bins.oldZmx,
            name: oldName,
            generation: "gen-old",
            command: ["/bin/sh"],
            environment: env
        )
        let origOldPID = try #require(RuntimeCommand.sessionPID(bins.newZmx, name: oldName, environment: env))

        let killOld = RuntimeCommand.killIfGeneration(
            bins.newZmx,
            name: oldName,
            generation: "gen-old",
            environment: env,
            timeout: 3
        )
        #expect(killOld != .killed)
        #expect(RuntimeCommand.sessionPID(bins.newZmx, name: oldName, environment: env) == origOldPID)

        // 2. Mismatched generation on `--attach-only --if-label` against an old daemon fails closed without
        // sending `.Init`, mutating labels, or killing the old daemon.
        let mismatchAttachOld = try #require(
            PTY(
                cols: 80,
                rows: 24,
                workingDirectory: "/tmp",
                program: [bins.newZmx.path] + RuntimeCommand.attachOnlyIfGenerationArguments(
                    name: oldName,
                    generation: "wrong-gen",
                    attempt: "att-intruder"
                ),
                environment: env,
                removing: SessionNamespace.inheritedVariablesToDrop
            )
        )
        defer { mismatchAttachOld.terminate() }
        #expect(waitUntil(timeout: 3) { mismatchAttachOld.exitStatus == 1 })
        #expect(RuntimeCommand.sessionPID(bins.newZmx, name: oldName, environment: env) == origOldPID)
        let oldLabelsAfterMismatch = try #require(RuntimeCommand.run(bins.newZmx, ["get", oldName], environment: env))
        #expect(Reattach.labels(from: oldLabelsAfterMismatch.output) == ["tako-gen": "gen-old"])

        // 3. Matching generation on `--attach-only --if-label` against an old daemon succeeds via the
        // single-socket legacy fallback, preserving the exact same shell PID, updating `tako-attempt`,
        // and delivering terminal output.
        let matchAttachOld = try #require(
            PTY(
                cols: 80,
                rows: 24,
                workingDirectory: "/tmp",
                program: [bins.newZmx.path] + RuntimeCommand.attachOnlyIfGenerationArguments(
                    name: oldName,
                    generation: "gen-old",
                    attempt: "att-old-1"
                ),
                environment: env,
                removing: SessionNamespace.inheritedVariablesToDrop
            )
        )
        defer { matchAttachOld.terminate() }
        #expect(waitUntil(timeout: 3) {
            guard let get = RuntimeCommand.run(bins.newZmx, ["get", oldName], environment: env),
                  get.status == 0 else { return false }
            let labels = Reattach.labels(from: get.output)
            return labels?["tako-gen"] == "gen-old" && labels?["tako-attempt"] == "att-old-1"
        })
        #expect(matchAttachOld.exitStatus == nil)
        matchAttachOld.write(Array("printf 'LEGACY_REATTACH_ALIVE\\n'\r".utf8))
        #expect(waitUntil(timeout: 3) {
            RuntimeCommand.run(bins.newZmx, ["history", oldName], environment: env)?.output.contains("LEGACY_REATTACH_ALIVE") == true
        })
        #expect(RuntimeCommand.sessionPID(bins.newZmx, name: oldName, environment: env) == origOldPID)
        matchAttachOld.terminate()

        // 4. Deterministic replacement race on an old daemon between initial `.LabelData` probe and `.LabelSet`/`.Init`:
        // Using `ZMX_TEST_LEGACY_ATTACH_PROBE_READY_FILE` and `ZMX_TEST_LEGACY_ATTACH_RESUME_FILE` inside the isolated
        // socket directory, the client connects to the old daemon, verifies `gen-old` on the initial `.LabelGet`, signals
        // `readyFile`, and pauses until `resumeFile` is created after the old daemon is killed and replaced on `oldName`
        // by a new daemon with `gen-replacement`. Because the client stays bound to the original kernel socket descriptor,
        // it fails closed with EOF (`exitStatus == 1`) and never touches the replacement daemon or its labels.
        let readyFileURL = ns.directory.appendingPathComponent("legacy-attach-probe-ready")
        let resumeFileURL = ns.directory.appendingPathComponent("legacy-attach-probe-resume")
        try? FileManager.default.removeItem(at: readyFileURL)
        try? FileManager.default.removeItem(at: resumeFileURL)

        var delayedEnv = env
        delayedEnv["ZMX_TEST_LEGACY_ATTACH_DELAY_MS"] = "5000"
        delayedEnv["ZMX_TEST_LEGACY_ATTACH_PROBE_READY_FILE"] = readyFileURL.path
        delayedEnv["ZMX_TEST_LEGACY_ATTACH_RESUME_FILE"] = resumeFileURL.path
        let racingLegacyAttach = try #require(
            PTY(
                cols: 80,
                rows: 24,
                workingDirectory: "/tmp",
                program: [bins.newZmx.path] + RuntimeCommand.attachOnlyIfGenerationArguments(
                    name: oldName,
                    generation: "gen-old",
                    attempt: "att-stale-race"
                ),
                environment: delayedEnv,
                removing: SessionNamespace.inheritedVariablesToDrop
            )
        )
        defer { racingLegacyAttach.terminate() }

        #expect(waitUntil(timeout: 3) {
            FileManager.default.fileExists(atPath: readyFileURL.path)
        })

        _ = RuntimeCommand.run(bins.oldZmx, ["kill", oldName], environment: env, timeout: 2)
        let replacementPty = try #require(
            PTY(
                cols: 80,
                rows: 24,
                workingDirectory: "/tmp",
                program: [bins.newZmx.path] + RuntimeCommand.createOnlyWithGenerationArguments(
                    name: oldName,
                    generation: "gen-replacement",
                    attempt: "att-fresh",
                    command: ["/bin/sh", "-c", "sleep 30"]
                ),
                environment: env,
                removing: SessionNamespace.inheritedVariablesToDrop
            )
        )
        defer { replacementPty.terminate() }
        #expect(waitUntil(timeout: 3) {
            guard let get = RuntimeCommand.run(bins.newZmx, ["get", oldName], environment: env),
                  get.status == 0 else { return false }
            return Reattach.labels(from: get.output)?["tako-gen"] == "gen-replacement"
        })
        let replacementPID = try #require(RuntimeCommand.sessionPID(bins.newZmx, name: oldName, environment: env))
        #expect(replacementPID != origOldPID)

        try Data("resume\n".utf8).write(to: resumeFileURL)

        #expect(waitUntil(timeout: 3) { racingLegacyAttach.exitStatus == 1 })
        #expect(RuntimeCommand.sessionPID(bins.newZmx, name: oldName, environment: env) == replacementPID)
        let replacementLabels = try #require(RuntimeCommand.run(bins.newZmx, ["get", oldName], environment: env))
        #expect(Reattach.labels(from: replacementLabels.output) == [
            "tako-gen": "gen-replacement",
            "tako-attempt": "att-fresh"
        ])
        replacementPty.terminate()
        #expect(RuntimeCommand.killIfGeneration(bins.newZmx, name: oldName, generation: "gen-replacement", environment: env) == .killed)

        // B. New daemon + Old client: standard wire commands (`list`, `get`, `set`, `kill`) stay compatible.
        try startDetachedDaemon(runtime: bins.newZmx, name: newName, generation: "gen-new", environment: env)
        #expect(RuntimeCommand.isListed(bins.oldZmx, name: newName, environment: env) == true)
        let getViaOld = try #require(RuntimeCommand.run(bins.oldZmx, ["get", newName], environment: env))
        #expect(Reattach.labels(from: getViaOld.output) == ["tako-gen": "gen-new"])
        let setViaOld = try #require(RuntimeCommand.run(bins.oldZmx, ["set", newName, "role=legacy"], environment: env))
        #expect(setViaOld.status == 0)
        let killViaOld = try #require(RuntimeCommand.run(bins.oldZmx, ["kill", newName], environment: env))
        #expect(killViaOld.status == 0)
        #expect(RuntimeCommand.isListed(bins.newZmx, name: newName, environment: env) == false)
    }
}
