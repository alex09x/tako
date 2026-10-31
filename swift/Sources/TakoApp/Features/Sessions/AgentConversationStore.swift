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

/// Observations, not proof that a conversation is the only process in a pane.
/// Each distinct observation is retained without replacing older candidates.
struct AgentConversationStore {
    struct Entry: Equatable {
        let surface: UUID
        let provider: String
        let sessionID: String
        let lastSeen: Date
        var resumeCommand: String { provider == "claude" ? "claude --resume \(sessionID)" : "codex resume \(sessionID)" }
    }

    static var shared: Self { Self(directory: SessionPlaces.support.appendingPathComponent("AgentConversations", isDirectory: true)) }
    let directory: URL

    static func valid(provider: String, sessionID: String) -> Bool {
        guard ["claude", "codex"].contains(provider), (1...128).contains(sessionID.utf8.count) else { return false }
        return sessionID.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }

    private func openDirectory(create: Bool) throws -> Int32 {
        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        }
        return fd
    }

    func note(surface: UUID, provider: String, sessionID: String) throws {
        guard Self.valid(provider: provider, sessionID: sessionID) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        let dir = try openDirectory(create: true)
        defer { close(dir) }
        let name = "\(surface.uuidString.lowercased()).\(provider).\(sessionID)"
        let fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0 {
            if errno == EEXIST {
                let existingFD = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard existingFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                defer { close(existingFD) }
                var existing = stat()
                guard fstat(existingFD, &existing) == 0,
                      existing.st_mode & S_IFMT == S_IFREG, existing.st_uid == getuid(),
                      existing.st_mode & 0o077 == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
                }
                guard futimens(existingFD, nil) == 0, fsync(existingFD) == 0, fsync(dir) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                return
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(fd) }
        guard fsync(fd) == 0, fsync(dir) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    func entries() throws -> [Entry] {
        let dir: Int32
        do { dir = try openDirectory(create: false) }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return [] }
        defer { close(dir) }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return names.compactMap { name in
            let parts = name.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3, let surface = UUID(uuidString: String(parts[0])) else { return nil }
            let provider = String(parts[1]), sessionID = String(parts[2])
            guard Self.valid(provider: provider, sessionID: sessionID) else { return nil }
            var info = stat()
            guard fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { return nil }
            let lastSeen = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
            return Entry(surface: surface, provider: provider, sessionID: sessionID, lastSeen: lastSeen)
        }.sorted {
            if $0.lastSeen != $1.lastSeen { return $0.lastSeen > $1.lastSeen }
            return ($0.surface.uuidString, $0.provider, $0.sessionID) < ($1.surface.uuidString, $1.provider, $1.sessionID)
        }
    }
}
