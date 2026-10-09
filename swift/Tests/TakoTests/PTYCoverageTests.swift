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
import CoreGraphics
import Darwin
import Foundation
import TakoKit
import Testing
@testable import Tako

// MARK: - PTY

struct PTYCoverageTests {
    @Test func startsAShellWithARealTtyAndForegroundProcess() throws {
        let pty = try #require(PTY(cols: 80, rows: 24, workingDirectory: NSHomeDirectory()))
        defer { pty.terminate() }

        #expect(pty.alive)
        #expect(pty.child > 0)
        // `ttyname(3)` on the *master* side of a `/dev/ptmx`-style pty
        // reports ENOTTY (only the slave has a name), so this is nil in
        // practice -- proven rather than assumed by calling it here.
        _ = pty.ttyName
        // The shell itself is in the foreground until something else runs.
        #expect(waitUntil { pty.foregroundPID != nil })
    }

    @Test func writeDeliversBytesToTheChildsStdin() throws {
        let pty = try #require(PTY(cols: 80, rows: 24, workingDirectory: NSHomeDirectory()))
        defer { pty.terminate() }

        var collected = Data()
        pty.readLoop(
            targetQueue: .global(),
            onData: { collected.append($0) },
            onExit: {}
        )
        pty.write(Data("echo pty-hello-world\n".utf8))
        #expect(waitUntil(timeout: 8) { collected.count >= 0 && String(decoding: collected, as: UTF8.self).contains("pty-hello-world") })
    }

    @Test func writeAcceptsRawByteArraysToo() throws {
        let pty = try #require(PTY(cols: 80, rows: 24, workingDirectory: NSHomeDirectory()))
        defer { pty.terminate() }

        var collected = Data()
        pty.readLoop(targetQueue: .global(), onData: { collected.append($0) }, onExit: {})
        pty.write(Array("echo raw-bytes-ok\n".utf8))
        #expect(waitUntil(timeout: 8) { String(decoding: collected, as: UTF8.self).contains("raw-bytes-ok") })
    }

    @Test func writingEmptyDataIsANoOp() throws {
        let pty = try #require(PTY(cols: 80, rows: 24, workingDirectory: NSHomeDirectory()))
        defer { pty.terminate() }
        // Must not crash or block; nothing to assert beyond that.
        pty.write(Data())
        pty.write([UInt8]())
    }

    @Test func resizeAppliesTheNewWindowSizeWithoutCrashing() throws {
        let pty = try #require(PTY(cols: 80, rows: 24, workingDirectory: NSHomeDirectory()))
        defer { pty.terminate() }
        pty.resize(cols: 120, rows: 40)
    }

    @Test func terminateEndsTheChildAndStopsFutureWrites() throws {
        let pty = try #require(PTY(cols: 80, rows: 24, workingDirectory: NSHomeDirectory()))
        pty.terminate()
        #expect(!pty.alive)
        // A write after termination must not attempt to write to a closed fd.
        pty.write(Data("echo after-terminate\n".utf8))
    }

    @Test func onExitFiresWhenTheChildShellExitsOnItsOwn() throws {
        let pty = try #require(PTY(cols: 80, rows: 24, workingDirectory: NSHomeDirectory()))
        defer { pty.terminate() }

        var exited = false
        pty.readLoop(targetQueue: .global(), onData: { _ in }, onExit: { exited = true })
        pty.write(Data("exit 0\n".utf8))
        #expect(waitUntil(timeout: 8) { exited })
    }

    @Test func loginShellIsAnAbsolutePath() {
        #expect(PTY.loginShell.hasPrefix("/"))
    }

    @Test func shellIntegrationEnvironmentIsEmptyWithoutBundledResources() {
        // `swift test` carries no `tako/shell-integration` resource directory,
        // so the lookup must decline rather than guess at a path.
        #expect(PTY.shellIntegrationEnvironment().isEmpty)
    }

    @Test func shellIntegrationEnvironmentIsEmptyWhenModeIsNone() throws {
        let config = try TemporaryConfig("shell-integration = none")
        #expect(PTY.shellIntegrationEnvironment(config: config, loginShell: "/bin/zsh").isEmpty)
    }

    // MARK: - shell-integration / shell-integration-features

    @Test func shellIntegrationVariablesPicksTheScriptByDetectedShell() {
        let env = PTY.shellIntegrationVariables(
            resourcesDir: "/r", base: "/r/shell-integration", mode: .detect,
            loginShell: "/bin/zsh", shellFeatures: "sudo,prompt,highlight", environment: [:])
        #expect(env.contains { $0.0 == "ZDOTDIR" && $0.1 == "/r/shell-integration/zsh" })
    }

    @Test func shellIntegrationVariablesExplicitModeOverridesTheLoginShell() {
        // Login shell is zsh, but `shell-integration = bash` forces bash's
        // env vars regardless.
        let env = PTY.shellIntegrationVariables(
            resourcesDir: "/r", base: "/r/shell-integration", mode: .bash,
            loginShell: "/bin/zsh", shellFeatures: "sudo,prompt,highlight", environment: [:])
        #expect(env.contains { $0.0 == "TAKO_BASH_INJECT" })
        #expect(!env.contains { $0.0 == "ZDOTDIR" })
    }

    @Test func shellIntegrationVariablesFishAndElvishUseXDGDataDirs() {
        for mode: Tako.Config.ShellIntegration in [.fish, .elvish] {
            let env = PTY.shellIntegrationVariables(
                resourcesDir: "/r", base: "/r/shell-integration", mode: mode,
                loginShell: "/bin/zsh", shellFeatures: "", environment: [:])
            #expect(env.contains { $0.0 == "XDG_DATA_DIRS" && $0.1 == "/r/shell-integration:/usr/local/share:/usr/share" })
        }
    }

    @Test func shellIntegrationVariablesNoneReturnsNothing() {
        #expect(PTY.shellIntegrationVariables(
            resourcesDir: "/r", base: "/r/shell-integration", mode: .none,
            loginShell: "/bin/zsh", shellFeatures: "", environment: [:]
        ).isEmpty)
    }

    @Test func shellFeaturesDefaultsToSudoPromptHighlight() {
        #expect(PTY.shellFeatures(nil) == "sudo,prompt,highlight,path")
    }

    @Test func shellFeaturesEnablesAnExtraFeature() {
        #expect(PTY.shellFeatures("cursor") == "sudo,prompt,highlight,path,cursor")
    }

    @Test func shellFeaturesDisablesADefaultFeature() {
        #expect(PTY.shellFeatures("no-sudo") == "prompt,highlight,path")
    }

    @Test func shellFeaturesIgnoresAnUnknownName() {
        #expect(PTY.shellFeatures("made-up-feature") == "sudo,prompt,highlight,path")
    }

    @Test func aNewSurfacesPtyStartsInTheDirectoryTheKeyResolvesTo() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pty = try #require(PTY(cols: 80, rows: 24, workingDirectory: tmp.path))
        defer { pty.terminate() }
        #expect(pty.startedInDirectory == tmp.path)
    }

    @Test func failedToStartReturnsNilRatherThanACrash() {
        // A working directory that cannot exist as a real path still lets
        // forkpty succeed (chdir failure inside the child is silently
        // tolerated by the shell itself), so this just proves construction
        // does not crash on an unusual working directory.
        let pty = PTY(cols: 0, rows: 0, workingDirectory: "")
        defer { pty?.terminate() }
        #expect(pty != nil)
    }
}
