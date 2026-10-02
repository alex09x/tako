import AppKit
import Darwin
import TakoCoreUI

/// The host's half of a terminal: a pseudo-terminal with a shell on the other
/// side. TakoCoreUI draws and parses; starting and talking to the program is
/// the host's job, because only the host knows what it may run.
final class Shell {
    let master: Int32
    let pid: pid_t
    private let reader: DispatchSourceRead

    init(cols: Int, rows: Int, onOutput: @escaping (Data) -> Void, onExit: @escaping () -> Void) throws {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        // Everything the child needs is built before fork: after it, the
        // child may only call async-signal-safe functions until exec.
        let args: [String] = [shell, "-l"]
        let argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        // forkpty gives the child a new session with the pty as its
        // controlling terminal: job control works and Ctrl-C reaches what
        // runs in the shell.
        var master: Int32 = -1
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        let pid = forkpty(&master, nil, nil, &size)
        if pid < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if pid == 0 {
            execve(shell, argv, envp)
            _exit(127)
        }

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
        reader.resume()
    }

    func write(_ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(master, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    deinit {
        reader.cancel()
        kill(pid, SIGHUP)
        close(master)
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
            shell = try Shell(
                cols: 80, rows: 24,
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

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
