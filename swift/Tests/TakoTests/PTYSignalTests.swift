import Foundation
import Testing
@testable import Tako

/// The terminal's shell starts with default signal handling, whatever the
/// app itself ignores. It inherited the app's "ignore" instead: started from
/// an ssh session, or under nohup, the app ignored SIGHUP, so closing a
/// terminal left its shell running -- and closing the pty then blocked the
/// main thread waiting for that shell to let go.
struct PTYSignalTests {
    @Test func aHangupEndsTheShellEvenWhenTheAppIgnoresHangups() throws {
        let previous = signal(SIGHUP, SIG_IGN)
        defer { signal(SIGHUP, previous) }

        let pty = try #require(PTY(cols: 80, rows: 24, workingDirectory: NSHomeDirectory()))
        // An exiting pty child waits for its output to be read.
        pty.readLoop(targetQueue: .global(), onData: { _ in }, onExit: {})
        // Let the shell get going before hanging up on it.
        usleep(500_000)
        kill(pty.child, SIGHUP)

        var status: Int32 = 0
        var exited = false
        let deadline = Date().addingTimeInterval(10)
        while !exited, Date() < deadline {
            exited = waitpid(pty.child, &status, WNOHANG) == pty.child
            if !exited { usleep(20_000) }
        }
        pty.terminate()
        #expect(exited, "the shell ignored SIGHUP")
    }

    /// Terminating twice -- a surface's close() and then its deinit -- once
    /// closed the master's number twice. With the close done off the main
    /// thread, the number could by then belong to another file.
    @Test func terminatingTwiceClosesTheMasterOnce() throws {
        let pty = try #require(PTY(cols: 80, rows: 24, workingDirectory: NSHomeDirectory()))
        let master = pty.master
        pty.terminate()
        // Wait for the close, then take the number back for another file.
        var closed = false
        for _ in 0..<100 where !closed {
            closed = fcntl(master, F_GETFD) == -1
            if !closed { usleep(20_000) }
        }
        #expect(closed)
        var pipeFDs: [Int32] = [0, 0]
        #expect(pipe(&pipeFDs) == 0)
        defer { close(pipeFDs[0]); close(pipeFDs[1]) }

        pty.terminate()
        usleep(200_000)

        #expect(fcntl(pipeFDs[0], F_GETFD) != -1, "the second terminate closed someone else's file")
        #expect(fcntl(pipeFDs[1], F_GETFD) != -1)
    }
}
