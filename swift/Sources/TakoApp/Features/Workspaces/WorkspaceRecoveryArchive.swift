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

extension Notification.Name {
    static let takoWorkspacePersistenceFailed = Notification.Name("takoWorkspacePersistenceFailed")
}

enum WorkspaceRecoveryArchive {
    /// Preserve the previous launch's bytes before the workspace store writes.
    static func preservePrevious(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size <= 16 * 1_048_576 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
        let data = try Data(contentsOf: url)
        let history = url.deletingLastPathComponent().appendingPathComponent("History", isDirectory: true)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var historyInfo = stat()
        guard lstat(history.path, &historyInfo) == 0, historyInfo.st_mode & S_IFMT == S_IFDIR,
              historyInfo.st_uid == getuid(), historyInfo.st_mode & 0o077 == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        }
        try LayoutJournal.atomicWrite(data, to: history.appendingPathComponent("workspace-\(UUID().uuidString).json"))
    }
}
