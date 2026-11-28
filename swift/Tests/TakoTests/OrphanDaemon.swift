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

/// A session daemon a test can no longer reach by name -- its socket file was
/// replaced -- so `kill <name>` would end another daemon. Ends it and the
/// command it runs by process id, so no test leaves it behind.
enum OrphanDaemon {
    /// The daemon running `shell` -- the session process `zmx list` gives --
    /// when that parent is a process of `runtime`; nil otherwise.
    static func daemon(ofShell shell: pid_t, runtime: URL) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(shell, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let parent = pid_t(info.pbi_ppid)
        return isProcess(parent, of: runtime) ? parent : nil
    }

    /// Ends the daemon `pid` and its children, if `pid` is still a process of
    /// `runtime` (an id the system has since given to something else is left
    /// alone). Returns the ids still alive afterwards: empty when all ended.
    @discardableResult
    static func end(_ pid: pid_t, runtime: URL) -> [pid_t] {
        guard isProcess(pid, of: runtime) else { return [] }
        let all = [pid] + children(of: pid)
        for p in all { kill(p, SIGTERM) }
        if !waitGone(all, timeout: 2) {
            for p in all where alive(p) { kill(p, SIGKILL) }
            _ = waitGone(all, timeout: 2)
        }
        return all.filter(alive)
    }

    static func alive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func children(of pid: pid_t) -> [pid_t] {
        var ids = [pid_t](repeating: 0, count: 64)
        _ = proc_listchildpids(pid, &ids, Int32(ids.count * MemoryLayout<pid_t>.size))
        return ids.filter { $0 > 0 }
    }

    private static func isProcess(_ pid: pid_t, of runtime: URL) -> Bool {
        pid > 1 && path(of: pid) == runtime.resolvingSymlinksInPath().path
    }

    private static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
    }

    private static func waitGone(_ pids: [pid_t], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !pids.contains(where: alive) { return true }
            usleep(20_000)
        }
        return !pids.contains(where: alive)
    }
}
