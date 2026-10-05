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

/// A recorded command and environment configuration to resume an agent
/// session after a relaunch or process loss (C6).
public struct ResumeSessionRecord: Codable, Equatable, Sendable {
    public var argv: [String]
    public var cwd: String
    public var env: [String: String]
    public var recordedAt: Date
    public var isImported: Bool

    public init(
        argv: [String],
        cwd: String,
        env: [String: String] = [:],
        recordedAt: Date = Date(),
        isImported: Bool = false
    ) {
        self.argv = argv
        self.cwd = cwd
        self.env = ResumeSessionStore.sanitizeEnvironment(env)
        self.recordedAt = recordedAt
        self.isImported = isImported
    }
}

/// Stores user-approved command prefixes for directories (C6).
/// Commands only run automatically after relaunch when their prefix
/// was approved by the user for that directory.
@MainActor
public final class ResumeTrustStore {
    public static let shared = ResumeTrustStore()

    public static let userDefaultsKey = "tako.resume_approved_prefixes"

    private let defaults: UserDefaults
    private var approvedByCwd: [String: [String]] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.approvedByCwd = defaults.dictionary(forKey: Self.userDefaultsKey) as? [String: [String]] ?? [:]
    }

    private func normalizePath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardized
        return url.path
    }

    /// Checks whether an argv command line is approved to auto-run in the specified directory.
    public func isApproved(argv: [String], cwd: String) -> Bool {
        guard !argv.isEmpty else { return false }
        let normCwd = normalizePath(cwd)
        guard let prefixes = approvedByCwd[normCwd], !prefixes.isEmpty else {
            return false
        }

        let cmdQuoted = argv.map { ResumeSessionStore.shellQuote($0) }.joined(separator: " ")
        let cmdPlain = argv.joined(separator: " ")

        for prefix in prefixes {
            let p = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.isEmpty { continue }

            if cmdQuoted == p || cmdPlain == p {
                return true
            }

            let pWords = p.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if !pWords.isEmpty && argv.count >= pWords.count {
                if Array(argv.prefix(pWords.count)) == pWords {
                    return true
                }
            }
        }
        return false
    }

    /// Approves a command prefix for a directory.
    public func approve(prefix: String, cwd: String) {
        let normCwd = normalizePath(cwd)
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var list = approvedByCwd[normCwd] ?? []
        if !list.contains(trimmed) {
            list.append(trimmed)
            approvedByCwd[normCwd] = list
            persist()
        }
    }

    /// Revokes an approval for a directory.
    public func revoke(prefix: String, cwd: String) {
        let normCwd = normalizePath(cwd)
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var list = approvedByCwd[normCwd] else { return }

        list.removeAll { $0 == trimmed }
        if list.isEmpty {
            approvedByCwd.removeValue(forKey: normCwd)
        } else {
            approvedByCwd[normCwd] = list
        }
        persist()
    }

    /// Clears all directory approvals.
    public func clearAll() {
        approvedByCwd.removeAll()
        persist()
    }

    public func approvedPrefixes(for cwd: String) -> [String] {
        let normCwd = normalizePath(cwd)
        return approvedByCwd[normCwd] ?? []
    }

    private func persist() {
        defaults.set(approvedByCwd, forKey: Self.userDefaultsKey)
    }
}

/// Central store for recording and persisting resume sessions per pane (C6).
/// Ensures secret-like environment variables are stripped and imported sessions
/// remain untrusted.
@MainActor
public final class ResumeSessionStore {
    public static let shared = ResumeSessionStore()

    public nonisolated static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let bundle = Bundle.main.bundleIdentifier ?? "com.alex09x.tako"
        return base.appendingPathComponent(bundle).appendingPathComponent("ResumeSessions", isDirectory: true)
    }

    private let directory: URL
    private var inMemoryRecords: [UUID: ResumeSessionRecord] = [:]

    public init(directory: URL = ResumeSessionStore.defaultDirectory) {
        self.directory = directory
    }

    // MARK: - Secret Sanitization

    /// Checks if an environment variable key looks like a credential or secret.
    public nonisolated static func isSecretKey(_ key: String) -> Bool {
        let upper = key.uppercased()
        let forbidden = [
            "KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "PASSPHRASE",
            "AUTH", "CREDENTIAL", "PRIVATE", "SIGNING", "ACCESS", "API",
            "CERT", "BEARER", "SALT",
        ]
        if forbidden.contains(where: { upper.contains($0) }) {
            return true
        }
        let parts = upper.components(separatedBy: CharacterSet.alphanumerics.inverted)
        if parts.contains("PASS") || parts.contains("PWD") {
            return true
        }
        return false
    }

    /// Strips any environment variables whose names indicate secrets.
    public nonisolated static func sanitizeEnvironment(_ env: [String: String]) -> [String: String] {
        env.filter { !isSecretKey($0.key) }
    }

    /// Safely quotes an argv token for POSIX shell execution so that metacharacters
    /// (e.g. `;`, `&`, `|`, `$`, `` ` ``, `<`, `>`, quotes, whitespace) are treated literally.
    public nonisolated static func shellQuote(_ arg: String) -> String {
        if arg.isEmpty {
            return "''"
        }
        let safePattern = "^[a-zA-Z0-9_./@:+=-]+$"
        if arg.range(of: safePattern, options: .regularExpression) != nil {
            return arg
        }
        return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Persistence

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    /// Records how to resume what runs in a pane.
    public func set(record: ResumeSessionRecord, for id: UUID, isSecure: Bool = false) {
        guard !isSecure else {
            clear(for: id)
            return
        }
        inMemoryRecords[id] = record

        // Persist to disk
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let fileUrl = url(for: id)
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: fileUrl, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileUrl.path)
        }
    }

    /// Reads the recorded resume configuration for a pane.
    public func record(for id: UUID) -> ResumeSessionRecord? {
        if let cached = inMemoryRecords[id] {
            return cached
        }
        let fileUrl = url(for: id)
        guard let data = try? Data(contentsOf: fileUrl),
              let decoded = try? JSONDecoder().decode(ResumeSessionRecord.self, from: data)
        else {
            return nil
        }
        inMemoryRecords[id] = decoded
        return decoded
    }

    /// Clears the resume configuration for a pane.
    public func clear(for id: UUID) {
        inMemoryRecords.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Drops saved resume records for panes that no longer exist.
    public func removeAll(except ids: Set<UUID>) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent)
            if id.map({ !ids.contains($0) }) ?? true {
                try? FileManager.default.removeItem(at: file)
            }
        }
        inMemoryRecords = inMemoryRecords.filter { ids.contains($0.key) }
    }

    public func removeAll() {
        removeAll(except: [])
    }
}
