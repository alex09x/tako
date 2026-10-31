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

extension SessionSnapshotStore {
    /// Preserve the last screen from before this run without copying its bytes.
    func preservePrevious(id: UUID) throws {
        let source = url(for: id)
        var info = stat()
        if lstat(source.path, &info) != 0 {
            if errno == ENOENT { return }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
        let history = directory.appendingPathComponent("History", isDirectory: true)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard Self.isPrivateHistory(history) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
        let archived = history.appendingPathComponent("\(id.uuidString)-\(UUID().uuidString).snapshot")
        guard link(source.path, archived.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let fd = open(history.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    /// Privacy and explicit deletion apply to this app's history as well.
    func removeHistory(except ids: Set<UUID>) {
        removeHistory { !ids.contains($0) }
    }

    func removeHistory(id: UUID) {
        removeHistory { $0 == id }
    }

    private func removeHistory(_ shouldRemove: (UUID) -> Bool) {
        let history = directory.appendingPathComponent("History", isDirectory: true)
        guard Self.isOwnedHistory(history),
              let files = try? FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "snapshot" {
            let name = file.deletingPathExtension().lastPathComponent
            guard name.count == 73, name[name.index(name.startIndex, offsetBy: 36)] == "-",
                  let id = UUID(uuidString: String(name.prefix(36))),
                  UUID(uuidString: String(name.suffix(36))) != nil, shouldRemove(id) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
        // Only remove the directory if it is empty; never remove unrelated files.
        _ = rmdir(history.path)
    }

    private static func isPrivateHistory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR &&
            info.st_uid == getuid() && info.st_mode & 0o077 == 0
    }

    private static func isOwnedHistory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
    }
}
