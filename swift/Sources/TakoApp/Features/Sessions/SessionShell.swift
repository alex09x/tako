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

    /// The command in front of the shell, as a command line: what a Tako
    /// that restarted under a running `tail -f` or ssh never saw marked.
    /// Nil while the shell itself is in front.
    static func runningCommand(ofShell pid: pid_t) -> String? {
        guard let front = terminal(ofShell: pid)?.foregroundPID, front != Int(pid) else { return nil }
        return commandLine(ofProcess: pid_t(front))
    }

    /// A process's arguments, quoted where the shell would need it.
    static func commandLine(ofProcess pid: pid_t) -> String? {
        guard let arguments = arguments(ofProcess: pid), !arguments.isEmpty else { return nil }
        return arguments.map(quoted).joined(separator: " ")
    }

    /// KERN_PROCARGS2: argc, the executable's path, padding, then argv.
    static func arguments(ofProcess pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    private static func quoted(_ argument: String) -> String {
        let plain = CharacterSet(charactersIn: "@%+=:,./-_~").union(.alphanumerics)
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy(plain.contains) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// No controlling terminal is NODEV (all bits set).
    static func ttyName(device: UInt32) -> String? {
        guard device != UInt32.max, let name = devname(dev_t(bitPattern: device), S_IFCHR) else { return nil }
        let text = String(cString: name)
        return text.isEmpty || text == "??" ? nil : "/dev/" + text
    }
}
