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

enum SessionCollisionGuard {
    /// A missing record in an old layout is not evidence that the pane never
    /// had a session. An inaccessible namespace is also treated as unknown.
    static func mayContainSession(id: UUID, home: URL) -> Bool {
        let root = home.appendingPathComponent(".tako-sessions", isDirectory: true)
        var info = stat()
        if lstat(root.path, &info) != 0 { return errno != ENOENT }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return true }
        let name = SessionNamespace.sessionName(for: id)
        for entry in entries {
            let namespace = root.appendingPathComponent(entry, isDirectory: true)
            if lstat(namespace.path, &info) != 0 {
                if errno == ENOENT { continue }
                return true
            }
            if !SessionRuntimeRegistry.isValidID(entry) {
                // Ordinary files (for example .DS_Store) cannot be namespaces.
                if info.st_mode & S_IFMT == S_IFREG { continue }
                return true
            }
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { return true }
            if lstat(namespace.appendingPathComponent(name).path, &info) == 0 { return true }
            if errno != ENOENT { return true }
        }
        return false
    }
}
