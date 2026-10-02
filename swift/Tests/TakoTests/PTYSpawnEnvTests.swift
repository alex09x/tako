import Foundation
import Testing
@testable import Tako

/// End-to-end coverage for the fork-safety rewrite of `PTY.init`: argv, envp
/// and the working-directory C string are now built once in the parent
/// before `forkpty`, and the child only calls `chdir`/`execve`/`_exit`. This
/// asks a real login shell what its own environment and working directory
/// look like, so a regression that drops an override or the inherited
/// environment would show up here rather than only in a unit test of the
/// pure helper functions (see `AppReloadTests`).
private func waitUntil(
    timeout: TimeInterval = 8,
    _ condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return condition() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    return true
}

struct PTYSpawnEnvTests {
    @Test func childSeesIdentityRemovedVarAndRequestedWorkingDirectory() throws {
        let rawWorkDir = NSTemporaryDirectory() + "tako-pty-spawn-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: rawWorkDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: rawWorkDir) }
        let resolvedWorkDir = URL(fileURLWithPath: rawWorkDir).resolvingSymlinksInPath().path

        // NO_COLOR is a launcher preference the terminal must not leak into
        // the shell it starts; setting it here proves the removal happens
        // against the real inherited environment, not just in a unit test of
        // `variablesRemovedFromChild` in isolation.
        setenv("NO_COLOR", "1", 1)
        defer { unsetenv("NO_COLOR") }

        let pty = try #require(PTY(cols: 80, rows: 24, workingDirectory: rawWorkDir))
        defer { pty.terminate() }

        // The read loop delivers on another queue; guard the buffer.
        let lock = NSLock()
        var collected = Data()
        pty.readLoop(targetQueue: .global(), onData: { chunk in
            lock.lock(); collected.append(chunk); lock.unlock()
        }, onExit: {})
        func text() -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: collected, as: UTF8.self) }

        // The end marker is produced by printf, so the terminal's echo of the
        // typed line ("END_%s_TEST") cannot satisfy the wait before the
        // command has run. Works in sh and fish alike.
        pty.write(Data("env; pwd -P; printf 'END_%s_TEST\\n' TAKO\n".utf8))

        let sawMarker = waitUntil(timeout: 8) { text().contains("END_TAKO_TEST") }
        #expect(sawMarker)

        let output = text()
        #expect(output.contains("TERM_PROGRAM=tako"))
        #expect(output.contains("COLORTERM=truecolor"))
        #expect(!output.contains("NO_COLOR="))
        #expect(output.contains(resolvedWorkDir))
    }

    @Test func aPTYNamesTheTerminalDeviceItsShellRunsOn() throws {
        let pty = try #require(PTY(cols: 80, rows: 24, workingDirectory: NSTemporaryDirectory()))
        defer { pty.terminate() }
        let name = try #require(pty.ttyName)
        #expect(name.hasPrefix("/dev/tty"))
        #expect(FileManager.default.fileExists(atPath: name))
    }

    @Test func aProgramsExitStatusIsCollectedAsAShellReportsIt() throws {
        for (script, want) in [("exit 3", Int32(3)), ("kill -9 $$", Int32(128 + 9))] {
            let pty = try #require(PTY(cols: 80, rows: 24, workingDirectory: NSTemporaryDirectory(),
                                       program: ["/bin/sh", "-c", script]))
            pty.readLoop(targetQueue: .global(), onData: { _ in }, onExit: {})
            #expect(waitUntil { pty.exitStatus != nil && !pty.alive })
            #expect(pty.exitStatus == want, "\(script)")
            pty.terminate()
        }
    }

    @Test func aProgramThatCannotStartSaysWhyInsteadOfExiting127() throws {
        let pty = try #require(PTY(cols: 80, rows: 24, workingDirectory: NSTemporaryDirectory(),
                                   program: ["/nonexistent/tako-test-program"]))
        defer { pty.terminate() }
        #expect(pty.startError == ENOENT)
    }

    @Test func aProgramThatClosesItsTerminalAndRunsOnIsStillWaitedFor() throws {
        // Lets go of the terminal and exits only seconds later: the status is
        // its own, collected when it really exits, however long after.
        let pty = try #require(PTY(cols: 80, rows: 24, workingDirectory: NSTemporaryDirectory(),
                                   program: ["/bin/sh", "-c", "exec </dev/null >/dev/null 2>&1; sleep 2; exit 5"]))
        defer { pty.terminate() }
        pty.readLoop(targetQueue: .global(), onData: { _ in }, onExit: {})
        #expect(waitUntil(timeout: 8) { pty.exitStatus != nil })
        #expect(pty.exitStatus == 5)
    }
}

