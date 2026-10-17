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

/// What runs on a persistent session's terminal. The pty Tako holds is the
/// session client's, so asking it for its foreground answers "the client";
/// the shell runs on a terminal of the session runtime's own. From the
/// shell's pid the kernel tells that terminal and what is in front on it.
enum SessionShell {
    struct Terminal: Equatable {
        /// The process group in front: the running command, or the shell.
        let foregroundPID: Int
        /// `/dev/ttysNNN`.
        let ttyName: String?
    }

    static func terminal(ofShell pid: pid_t) -> Terminal? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let tpgid = Int(info.e_tpgid)
        return Terminal(foregroundPID: tpgid > 0 ? tpgid : Int(pid), ttyName: ttyName(device: info.e_tdev))
    }

    /// No controlling terminal is NODEV (all bits set).
    static func ttyName(device: UInt32) -> String? {
        guard device != UInt32.max, let name = devname(dev_t(bitPattern: device), S_IFCHR) else { return nil }
        let text = String(cString: name)
        return text.isEmpty || text == "??" ? nil : "/dev/" + text
    }
}
