/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing
@testable import Tako

/// The terminal's shell starts with default signal handling, whatever the
/// app itself ignores. It inherited the app's "ignore" instead: started from
/// an ssh session, or under nohup, the app ignored SIGHUP, so closing a
/// terminal left its shell running -- and closing the pty then blocked the
/// main thread waiting for that shell to let go.
struct PTYSignalTests {
    @Test func thePtyMasterClosesOnExec() throws {
        let pty = try #require(PTY(cols: 80, rows: 24, workingDirectory: NSHomeDirectory(),
                                   program: ["/bin/sleep", "30"]))
        defer { pty.terminate() }
        try #require(pty.startError == nil)
        let flags = fcntl(pty.master, F_GETFD)
        try #require(flags >= 0)
        #expect(flags & FD_CLOEXEC != 0, "an unrelated child must not keep this terminal's master open")
    }

    @Test func aHangupEndsTheShellEvenWhenTheAppIgnoresHangups() throws {
        let previous = signal(SIGHUP, SIG_IGN)
        defer { signal(SIGHUP, previous) }

        let pty = try #require(PTY(cols: 80, rows: 24, workingDirectory: NSHomeDirectory()))
        // An exiting pty child waits for its output to be read.
        pty.readLoop(targetQueue: .global(), onData: { _ in }, onExit: {})
        // Let the shell get going before hanging up on it.
        usleep(500_000)
        kill(pty.child, SIGHUP)

        // Tako collects the child when its terminal ends, with how it ended
        // (a shell may catch the hangup and exit on its own: any status).
        var status: Int32?
        let deadline = Date().addingTimeInterval(10)
        while status == nil, Date() < deadline {
            status = pty.exitStatus
            if status == nil { usleep(20_000) }
        }
        pty.terminate()
        #expect(status != nil, "the shell ignored SIGHUP")
    }

    /// Terminating twice -- a surface's close() and then its deinit -- once
    /// closed the master's number twice. With the close done off the main
    /// thread, the number could by then belong to another file.
    @Test func terminatingTwiceClosesTheMasterOnce() throws {
        let pty = try #require(PTY(cols: 80, rows: 24, workingDirectory: NSHomeDirectory()))
        let closeMaster = try #require(pty.terminate())
        // The kernel may recycle the descriptor before our next observation.
        #expect(closeMaster.wait(timeout: .now() + 2) == .success, "the scheduled master close did not complete")
        #expect(pty.terminate() == nil, "the second terminate scheduled another close")
    }
}
