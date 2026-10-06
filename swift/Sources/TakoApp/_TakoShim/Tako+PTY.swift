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
import Darwin


/// Internal UNIX pseudo-terminal pair management for Tako.SurfaceView.
final class PTY {
    let master: Int32
    let child: pid_t
    /// False once the process was told to end or its terminal reached EOF.
    /// Read from any thread.
    var alive: Bool { aliveLock.withLock { _alive } }
    private var _alive = true
    private let aliveLock = NSLock()
    private func markEnded() { aliveLock.withLock { _alive = false } }

    /// How the process ended, once it has: its exit code, or 128 plus the
    /// signal that ended it -- as a shell reports it. Nil while it runs.
    /// Collected when the process itself exits, whatever happens to its
    /// terminal: a descendant may hold the terminal open after it, or it may
    /// close the terminal and run on.
    var exitStatus: Int32? { aliveLock.withLock { _exitStatus } }
    private var _exitStatus: Int32?

    /// The error `execve` gave when the program could not be started at
    /// all (its errno); then the process never ran and `exitStatus` is not
    /// the program's.
    private(set) var startError: Int32?

    /// Whether the process has turned off terminal echo (e.g. during a password prompt).
    var isPasswordMode: Bool {
        guard master >= 0 else { return false }
        var attr = termios()
        guard tcgetattr(master, &attr) == 0 else { return false }
        return (attr.c_lflag & tcflag_t(ECHO)) == 0
    }

    private var exitSource: DispatchSourceProcess?

    /// Watches the child for its exit and collects it then, so it does not
    /// linger as a zombie and its status is known.
    private func watchExit() {
        let pid = child
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        let collect: @Sendable () -> Bool = { [weak self] in
            var status: Int32 = 0
            guard waitpid(pid, &status, WNOHANG) == pid else { return false }
            let signal = status & 0x7f
            let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
            self?.aliveLock.withLock { self?._exitStatus = code }
            return true
        }
        source.setEventHandler {
            // The event can come a moment before the process can be waited on.
            for _ in 0..<100 where !collect() { usleep(10_000) }
            source.cancel()
        }
        exitSource = source
        source.resume()
        // An exit before the watch was set up is not reported by it.
        DispatchQueue.global(qos: .utility).async { if collect() { source.cancel() } }
    }

    /// The directory the child process actually started in -- what
    /// `working-directory`/`window-inherit-working-directory` resolved to,
    /// or the home directory when nothing supplied one.
    let startedInDirectory: String

    /// `program` replaces the login shell (argv[0] is the executable): the
    /// session runtime's client, when the terminal's shell lives in a
    /// persistent session. `environment` is added, and `removing` taken out,
    /// on top of what every shell gets.
    init?(cols: UInt16, rows: UInt16, workingDirectory: String? = nil, config: Tako.Config? = nil,
          program: [String]? = nil, environment: [String: String] = [:], removing: [String] = []) {
        // Everything the child needs -- argv, envp and the working directory
        // -- is built as C strings here, in the parent, before forkpty: after
        // it, only async-signal-safe calls are legal in the child, which
        // rules out setenv/unsetenv/strdup.
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let shellPathString = PTY.loginShell
        let extraEnv = PTY.shellIntegrationEnvironment(config: config, loginShell: shellPathString)
            + TakoPTYEnvironment.terminalIdentity(appVersion: appVersion)

        var envMap = ProcessInfo.processInfo.environment
        for key in TakoPTYEnvironment.variablesRemovedFromChild { envMap.removeValue(forKey: key) }
        envMap["TERM"] = "xterm-256color"
        envMap["COLORTERM"] = "truecolor"
        envMap["SHELL"] = shellPathString
        for (key, value) in extraEnv { envMap[key] = value }
        for key in removing { envMap.removeValue(forKey: key) }
        for (key, value) in environment { envMap[key] = value }

        // Plain C arrays, allocated here: passing a Swift array with `&` in
        // the child would go through Swift's array bridging, which is not
        // guaranteed to be allocation-free.
        let envStrings: [UnsafeMutablePointer<CChar>?] = envMap.map { strdup("\($0.key)=\($0.value)") }
        let envp = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: envStrings.count + 1)
        for (i, s) in envStrings.enumerated() { envp[i] = s }
        envp[envStrings.count] = nil

        let shellPath = strdup(program?.first ?? shellPathString)
        let argvStrings: [UnsafeMutablePointer<CChar>?] = program.map { $0.map { strdup($0) } }
            ?? [strdup(shellPathString), strdup("-l")]
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: argvStrings.count + 1)
        for (i, s) in argvStrings.enumerated() { argv[i] = s }
        argv[argvStrings.count] = nil

        // An app launched from the Finder inherits launchd's working
        // directory, which is `/`. A terminal that opens at the root of the
        // disk is useless, and it is why every title and prompt read "/".
        let startDir = workingDirectory.flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        self.startedInDirectory = startDir
        let childDir = strdup(startDir)

        // execve's error, if it fails, comes back on this pipe: both ends
        // close on exec, so a started program leaves it empty and closed.
        var errorPipe: [Int32] = [-1, -1]
        let haveErrorPipe = pipe(&errorPipe) == 0
        if haveErrorPipe {
            _ = fcntl(errorPipe[0], F_SETFD, FD_CLOEXEC)
            _ = fcntl(errorPipe[1], F_SETFD, FD_CLOEXEC)
        }

        var masterFD: Int32 = 0
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        let pid = forkpty(&masterFD, nil, nil, &size)
        if pid < 0 {
            if haveErrorPipe {
                close(errorPipe[0])
                close(errorPipe[1])
            }
            for s in envStrings { free(s) }
            for s in argvStrings { free(s) }
            free(shellPath)
            envp.deallocate()
            argv.deallocate()
            free(childDir)
            return nil
        }
        if pid == 0 {
            // A shell starts with default signal handling and nothing
            // blocked. Whatever this process ignores -- SIGHUP when launched
            // under nohup or from an ssh session, SIGINT from some launchers
            // -- would otherwise pass through exec to the shell and to every
            // program it runs: Ctrl-C would do nothing, and closing the
            // terminal would not end it.
            var empty: sigset_t = 0
            sigprocmask(SIG_SETMASK, &empty, nil)
            var signalNumber: Int32 = 1
            while signalNumber < NSIG {
                signal(signalNumber, SIG_DFL)
                signalNumber += 1
            }
            chdir(childDir)
            _ = execve(shellPath, argv, envp)
            var failure = errno
            if haveErrorPipe { _ = Darwin.write(errorPipe[1], &failure, MemoryLayout<Int32>.size) }
            _exit(127)
        }
        var startFailure: Int32?
        if haveErrorPipe {
            close(errorPipe[1])
            // Returns at the child's exec (the pipe closes) or its failure.
            var failure: Int32 = 0
            var got = 0
            repeat {
                got = withUnsafeMutableBytes(of: &failure) { Darwin.read(errorPipe[0], $0.baseAddress, $0.count) }
            } while got < 0 && errno == EINTR
            if got == MemoryLayout<Int32>.size { startFailure = failure }
            close(errorPipe[0])
        }
        for s in envStrings { free(s) }
        for s in argvStrings { free(s) }
        free(shellPath)
        envp.deallocate()
        argv.deallocate()
        free(childDir)
        master = masterFD
        child = pid
        startError = startFailure
        watchExit()
    }

    /// The user's login shell, from the password database. `$SHELL` is not
    /// it: an app launched from Finder inherits launchd's `/bin/zsh`, not
    /// what the user actually logs in with. Upstream reads passwd too,
    /// which is why it opens fish here and we were opening zsh.
    static var loginShell: String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// The environment upstream's shell integration needs: zsh through
    /// ZDOTDIR, everything else through XDG_DATA_DIRS. This is what makes
    /// the shell report its working directory (OSC 7), its title (OSC 0)
    /// and its prompt boundaries (OSC 133).
    func write(_ data: Data) {
        guard !data.isEmpty, alive else { return }
        _ = data.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
    }

    func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty, alive else { return }
        _ = bytes.withUnsafeBufferPointer { Darwin.write(master, $0.baseAddress, $0.count) }
    }

    func resize(cols: UInt16, rows: UInt16) {
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    func readLoop(targetQueue: DispatchQueue = .main, onData: @escaping (Data) -> Void, onExit: @escaping () -> Void) {
        let fd = master
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let readChunk: () -> Data? = {
                let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if n <= 0 { return nil }
                return Data(buffer[0..<n])
            }
            PTYDeliveryPump.pump(
                readNext: readChunk,
                readNextIfAvailable: {
                    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    guard Darwin.poll(&descriptor, 1, 0) > 0,
                          descriptor.revents & Int16(POLLIN) != 0 else {
                        return nil
                    }
                    return readChunk()
                },
                onData: onData,
                onExit: { [weak self] in
                    // Recorded before anyone is told, so whoever asks next
                    // sees it ended.
                    self?.markEnded()
                    onExit()
                },
                targetQueue: targetQueue
            )
        }
    }

    /// Set once the master is handed off to be closed. A second terminate
    /// -- a surface's close() and then its deinit -- must not close the
    /// number again: by then it may belong to another file.
    private var masterClosed = false

    func terminate() {
        markEnded()
        guard !masterClosed else { return }
        masterClosed = true
        let target = child
        var foregroundPgrp: pid_t = 0
        if master >= 0 {
            _ = ioctl(master, TIOCGPGRP, &foregroundPgrp)
        }
        if foregroundPgrp > 1 && foregroundPgrp != target {
            kill(-foregroundPgrp, SIGHUP)
            kill(foregroundPgrp, SIGHUP)
        }
        if target > 1 {
            kill(-target, SIGHUP)
            kill(target, SIGHUP)
        } else if target > 0 {
            kill(target, SIGHUP)
        }
        // Closing a pty master waits while its reader is inside read(),
        // which lasts until every process on the terminal has let go of it.
        // Escalating to SIGKILL after a grace period prevents background
        // processes like top, htop, or loopers from remaining orphaned.
        let fd = master
        DispatchQueue.global(qos: .utility).async {
            usleep(150_000)
            if foregroundPgrp > 1 && foregroundPgrp != target {
                kill(-foregroundPgrp, SIGKILL)
                kill(foregroundPgrp, SIGKILL)
            }
            if target > 1 {
                kill(-target, SIGKILL)
                kill(target, SIGKILL)
            } else if target > 0 {
                kill(target, SIGKILL)
            }
            close(fd)
        }
    }

    deinit {
        terminate()
    }
}
