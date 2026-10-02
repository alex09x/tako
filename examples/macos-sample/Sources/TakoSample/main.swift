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
    /// Input waiting for the program, at most this much; a paste beyond it
    /// is cut rather than letting memory grow without bound.
    static let maxPending = 8 << 20

    let master: Int32
    let pid: pid_t
    private let reader: DispatchSourceRead
    private let writer: DispatchSourceWrite
    /// Writes happen here, never on the main thread: a program that is not
    /// reading must not freeze the window.
    private let io = DispatchQueue(label: "TakoSample.pty-write")
    private var pending = Data()
    private var writerRunning = false

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
        reader = DispatchSource.makeReadSource(fileDescriptor: master, queue: .main)
        reader.setEventHandler { [master] in
            var buffer = [UInt8](repeating: 0, count: 65536)
            let n = read(master, &buffer, buffer.count)
            if n > 0 {
                onOutput(Data(buffer[0..<n]))
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                onExit()
            }
        }
        writer = DispatchSource.makeWriteSource(fileDescriptor: master, queue: io)
        writer.setEventHandler { [weak self] in self?.flush() }
        reader.resume()
    }

    /// Queues `data` for the program and returns at once.
    func write(_ data: Data) {
        io.async { [self] in
            pending.append(data.prefix(max(0, Self.maxPending - pending.count)))
            flush()
        }
    }

    /// On `io`: writes what the pty takes now, and waits for room for the rest.
    private func flush() {
        while !pending.isEmpty {
            let n = pending.withUnsafeBytes { Darwin.write(master, $0.baseAddress!, $0.count) }
            if n > 0 {
                pending.removeFirst(n)
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

    /// Bytes still waiting for the program.
    func pendingBytes() -> Int { io.sync { pending.count } }

    func resize(cols: Int, rows: Int) {
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    deinit {
        reader.cancel()
        io.sync {
            // A dispatch source must be resumed to be cancelled cleanly.
            if !writerRunning { writer.resume() }
            writer.cancel()
        }
        kill(pid, SIGHUP)
        close(master)
    }
}

/// `TakoSample --selftest`: a large paste into a program that reads nothing
/// must not block the caller. No window needed.
func selfTest() -> Int32 {
    do {
        let shell = try Shell(program: ["/bin/sleep", "30"], cols: 80, rows: 24, onOutput: { _ in }, onExit: {})
        // Raw, as a full-screen program sets it: a canonical-mode line
        // discipline would quietly drop what does not fit, and nothing would
        // ever wait.
        var mode = termios()
        tcgetattr(shell.master, &mode)
        cfmakeraw(&mode)
        tcsetattr(shell.master, TCSANOW, &mode)
        let start = Date()
        for _ in 0..<64 { shell.write(Data(repeating: 0x61, count: 256 << 10)) }
        let took = Date().timeIntervalSince(start)
        // The writer must still answer -- a blocking write would hang it --
        // and hold no more than its cap.
        let answered = DispatchSemaphore(value: 0)
        var waiting = -1
        DispatchQueue.global().async { waiting = shell.pendingBytes(); answered.signal() }
        let alive = answered.wait(timeout: .now() + 2) == .success
        print("queued 16 MiB in \(Int(took * 1000)) ms; writer answering: \(alive); waiting: \(waiting) bytes")
        return took < 0.5 && alive && waiting > 0 && waiting <= Shell.maxPending ? 0 : 1
    } catch {
        print("could not start: \(error)")
        return 1
    }
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
    func terminalView(_ view: TakoTerminalNSView, sendInputData data: Data) { shell?.write(data) }
    // Answers to the program's queries (cursor position, device attributes).
    func terminalView(_ view: TakoTerminalNSView, sendDeviceReplyData data: Data) { shell?.write(data) }
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
