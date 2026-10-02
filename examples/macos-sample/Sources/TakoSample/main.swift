import AppKit
import Darwin
import TakoCoreUI

/// A NULL-terminated C string array, built and owned by the parent so the
/// child after fork touches nothing but these raw pointers.
private func cStringArray(_ strings: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
    let array = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
    for (i, s) in strings.enumerated() { array[i] = strdup(s) }
    array[strings.count] = nil
    return array
}

private func freeCStringArray(_ array: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) {
    var i = 0
    while let s = array[i] { free(s); i += 1 }
    array.deallocate()
}

/// The host's half of a terminal: a pseudo-terminal with a program on the
/// other side. TakoCoreUI draws and parses; starting and talking to the
/// program is the host's job, because only the host knows what it may run.
final class Shell {
    /// Input not yet taken by the program, at most this much.
    static let maxPending = 8 << 20

    let master: Int32
    let pid: pid_t
    private let channel: Channel

    init(
        program: [String], cols: Int, rows: Int,
        onOutput: @escaping (Data) -> Void, onExit: @escaping () -> Void
    ) throws {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        // Every pointer the child uses is made here, before fork. After it,
        // the child may only make async-signal-safe calls until exec: no
        // allocation, no Swift bridging.
        let path = strdup(program[0])!
        let argv = cStringArray(program)
        let envp = cStringArray(env.map { "\($0.key)=\($0.value)" })
        defer { free(path); freeCStringArray(argv); freeCStringArray(envp) }

        // forkpty gives the child a new session with the pty as its
        // controlling terminal: job control works and Ctrl-C reaches what
        // runs in it.
        var master: Int32 = -1
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        let pid = forkpty(&master, nil, nil, &size)
        if pid < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if pid == 0 {
            execve(path, argv, envp)
            _exit(127)
        }

        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        self.master = master
        self.pid = pid
        channel = Channel(fd: master, onOutput: onOutput, onExit: onExit)
    }

    /// Queues `data` -- one key, one paste, one reply -- for the program and
    /// returns at once. All of it or none: false when it does not fit, so a
    /// paste is never cut between its start and end markers.
    @discardableResult
    func write(_ data: Data) -> Bool {
        channel.write(data)
    }

    /// Bytes accepted and not yet taken by the program.
    var pendingBytes: Int { channel.reservedBytes }

    func resize(cols: Int, rows: Int) {
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    deinit {
        // Never waits on the writer's queue: this may run on it, when queued
        // work held the last reference.
        channel.close()
        kill(pid, SIGHUP)
    }
}

/// The pty's two directions. Everything mutable here belongs to `io`, and
/// work queued there holds the channel, never the `Shell` -- so releasing a
/// `Shell` from any thread is safe, and the descriptor is closed only after
/// both dispatch sources are cancelled.
private final class Channel: @unchecked Sendable {
    private let fd: Int32
    private let io = DispatchQueue(label: "TakoSample.pty-write")
    private let reader: DispatchSourceRead
    private let writer: DispatchSourceWrite
    private var pending = Data()            // on io
    private var writerRunning = false       // on io
    private var closed = false              // on io
    /// Bytes accepted by `write` and not yet written: queued closures
    /// included, so the cap bounds everything held.
    private let lock = NSLock()
    private var reserved = 0                // under lock

    init(fd: Int32, onOutput: @escaping (Data) -> Void, onExit: @escaping () -> Void) {
        self.fd = fd
        reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        writer = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: io)
        // The descriptor outlives both sources: closed by whichever
        // cancellation comes second.
        let cancelled = DispatchGroup()
        cancelled.enter(); cancelled.enter()
        reader.setCancelHandler { cancelled.leave() }
        writer.setCancelHandler { cancelled.leave() }
        cancelled.notify(queue: .global()) { Darwin.close(fd) }
        reader.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                onOutput(Data(buffer[0..<n]))
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                onExit()
            }
        }
        writer.setEventHandler { [weak self] in self?.flush() }
        reader.resume()
    }

    var reservedBytes: Int { lock.withLock { reserved } }

    func write(_ data: Data) -> Bool {
        let accepted = lock.withLock {
            guard reserved + data.count <= Shell.maxPending else { return false }
            reserved += data.count
            return true
        }
        guard accepted else { return false }
        io.async { [self] in
            guard !closed else { return }
            pending.append(data)
            flush()
        }
        return true
    }

    /// On `io`: writes what the pty takes now, and waits for room for the rest.
    private func flush() {
        while !pending.isEmpty {
            let n = pending.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
            if n > 0 {
                pending.removeFirst(n)
                lock.withLock { reserved -= n }
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break   // EAGAIN: full; or the program is gone
            }
        }
        if pending.isEmpty, writerRunning {
            writer.suspend()
            writerRunning = false
        } else if !pending.isEmpty, !writerRunning {
            writer.resume()
            writerRunning = true
        }
    }

    /// From any thread, any number of times.
    func close() {
        io.async { [self] in
            guard !closed else { return }
            closed = true
            pending = Data()
            lock.withLock { reserved = 0 }
            reader.cancel()
            // A suspended source must be resumed to be cancelled.
            if !writerRunning { writer.resume() }
            writer.cancel()
        }
    }
}

/// `TakoSample --selftest`: input to a program is accepted whole or not at
/// all, arrives intact once there is room, never blocks the caller, and a
/// Shell can be released with input still queued. No window needed.
func selfTest() -> Int32 {
    func raw(_ fd: Int32) {
        // As a full-screen program sets it: a canonical-mode line discipline
        // would quietly drop what does not fit, and nothing would ever wait.
        var mode = termios()
        tcgetattr(fd, &mode)
        cfmakeraw(&mode)
        tcsetattr(fd, TCSANOW, &mode)
    }
    var failures = 0
    func check(_ ok: Bool, _ what: String) {
        print("\(ok ? "ok  " : "FAIL") \(what)")
        if !ok { failures += 1 }
    }
    do {
        // 1. A program that reads nothing: the caller never blocks, items
        //    past the cap are refused whole.
        let idle = try Shell(program: ["/bin/sleep", "30"], cols: 80, rows: 24, onOutput: { _ in }, onExit: {})
        raw(idle.master)
        let item = Data(repeating: 0x61, count: 3 << 20)
        let start = Date()
        let results = (0..<5).map { _ in idle.write(item) }
        check(Date().timeIntervalSince(start) < 0.5, "writing 15 MiB returns at once")
        check(results == [true, true, false, false, false], "items past 8 MiB are refused whole: \(results)")
        check(idle.pendingBytes <= Shell.maxPending, "held input stays within the cap: \(idle.pendingBytes)")

        // 2. A bracketed paste larger than the pty's buffer reaches a
        //    program that starts reading late, complete and in order.
        let out = NSTemporaryDirectory() + "tako-sample-\(getpid()).out"
        let reader = try Shell(
            program: ["/bin/sh", "-c", "sleep 1; head -c 2097164 > \(out)"], cols: 80, rows: 24,
            onOutput: { _ in }, onExit: {})
        raw(reader.master)
        let paste = Data("\u{1b}[200~".utf8) + Data(repeating: 0x62, count: 2 << 20) + Data("\u{1b}[201~".utf8)
        check(reader.write(paste), "a 2 MiB bracketed paste is accepted")
        var got = Data()
        for _ in 0..<100 {
            got = FileManager.default.contents(atPath: out) ?? Data()
            if got.count >= paste.count { break }
            usleep(100_000)
        }
        check(got == paste, "it arrives whole, end marker included (\(got.count) of \(paste.count) bytes)")
        try? FileManager.default.removeItem(atPath: out)

        // 3. Released with input still queued: nothing waits on the writer's
        //    queue, and the program is told to go.
        var dropped: Shell? = try Shell(program: ["/bin/sleep", "30"], cols: 80, rows: 24, onOutput: { _ in }, onExit: {})
        raw(dropped!.master)
        let child = dropped!.pid
        dropped!.write(Data(repeating: 0x63, count: 4 << 20))
        dropped = nil
        var gone = false
        for _ in 0..<50 {
            if waitpid(child, nil, WNOHANG) == child { gone = true; break }
            usleep(100_000)
        }
        check(gone, "releasing a Shell with queued input ends its program")
    } catch {
        print("FAIL could not start: \(error)")
        return 1
    }
    return failures == 0 ? 0 : 1
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, TakoTerminalNSViewDelegate {
    var window: NSWindow!
    var terminal: TakoTerminalNSView!
    var shell: Shell?

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminal = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        terminal.delegate = self
        window = NSWindow(
            contentRect: terminal.frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "TakoCore sample"
        window.contentView = terminal
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminal)
        NSApp.activate(ignoringOtherApps: true)

        do {
            let login = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            shell = try Shell(
                program: [login, "-l"], cols: 80, rows: 24,
                onOutput: { [weak self] data in self?.terminal.feed(data: data) },
                onExit: { NSApp.terminate(nil) })
        } catch {
            terminal.feed(data: Data("could not start a shell: \(error)\r\n".utf8))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Keys, paste and mouse reports the view produced: the program's input.
    // Input that does not fit is refused whole; say so rather than send part.
    func terminalView(_ view: TakoTerminalNSView, sendInputData data: Data) {
        if shell?.write(data) == false { NSSound.beep() }
    }
    // Answers to the program's queries (cursor position, device attributes).
    func terminalView(_ view: TakoTerminalNSView, sendDeviceReplyData data: Data) {
        if shell?.write(data) == false { NSSound.beep() }
    }
    func terminalView(_ view: TakoTerminalNSView, didResizeCols cols: Int, rows: Int) {
        shell?.resize(cols: cols, rows: rows)
    }
    func terminalView(_ view: TakoTerminalNSView, didChangeTitle title: String) {
        window.title = title.isEmpty ? "TakoCore sample" : title
    }
}

if CommandLine.arguments.contains("--selftest") { exit(selfTest()) }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
