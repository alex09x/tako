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

/// Keeps a bounded set of layouts from before launches, outside the journal's
/// rolling generations, for recovery after an incomplete restore.
enum LayoutRecoveryArchive {
    static let limit = 32

    static func preserve(_ data: Data, generation: UInt64, in directory: URL) throws {
        let target = directory.appendingPathComponent("recovery-\(generation).json")
        var info = stat()
        if lstat(target.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, try Data(contentsOf: target) == data else {
                throw LayoutJournal.JournalError("conflicting layout recovery copy")
            }
        } else if errno == ENOENT {
            try LayoutJournal.atomicWrite(data, to: target)
        } else {
            throw LayoutJournal.JournalError("cannot inspect layout recovery copy")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let archives = names.compactMap { name -> (UInt64, String)? in
            guard name.hasPrefix("recovery-"), name.hasSuffix(".json"),
                  let n = UInt64(name.dropFirst("recovery-".count).dropLast(".json".count)) else { return nil }
            return (n, name)
        }.sorted { $0.0 > $1.0 }
        for (_, name) in archives.dropFirst(limit) {
            let path = directory.appendingPathComponent(name).path
            var info = stat()
            if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG { unlink(path) }
        }
    }
}
