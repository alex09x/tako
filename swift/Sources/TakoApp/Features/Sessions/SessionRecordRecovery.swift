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

extension SessionRecordStore {
    /// A user-selected adoption can replace an unreadable record only after
    /// preserving its exact bytes. Existing valid identities are never replaced.
    func recover(_ record: SessionRecord, replacing expected: SessionRecord? = nil) throws {
        try withLock(record.id) {
            switch read(record.id) {
            case .none:
                guard expected == nil else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ESTALE)) }
                try createIfAbsent(record)
            case .record(let current):
                guard expected == current,
                      current.runtimeID != record.runtimeID || current.generation != record.generation else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST))
                }
                try archivePrevious(current)
                try LayoutJournal.atomicWrite(JSONEncoder().encode(record), to: url(for: record.id))
            case .unreadable:
                guard expected == nil else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ESTALE)) }
                let original = url(for: record.id)
                var info = stat()
                guard lstat(original.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                      info.st_uid == getuid(), info.st_size <= 1_048_576 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
                let data = try Data(contentsOf: original)
                let history = try privateHistory()
                let archive = history.appendingPathComponent("\(record.id.uuidString)-\(UUID().uuidString).damaged")
                try LayoutJournal.atomicWrite(data, to: archive)
                // Cooperative writers cannot change the record while the lock is held.
                try LayoutJournal.atomicWrite(JSONEncoder().encode(record), to: original)
            }
        }
    }

    func archivePrevious(_ record: SessionRecord) throws {
        let history = try privateHistory()
        let archive = history.appendingPathComponent("\(record.id.uuidString)-\(UUID().uuidString).session")
        try LayoutJournal.atomicWrite(JSONEncoder().encode(record), to: archive)
    }

    private func privateHistory() throws -> URL {
        let history = directory.appendingPathComponent("History", isDirectory: true)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(history.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        }
        return history
    }
}
