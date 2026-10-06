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
import CryptoKit

/// Trust status of a project actions file (C3).
enum ProjectActionTrustStatus: Equatable, Sendable {
    case trusted
    case untrusted
    case changed(recordedSHA256: String, currentSHA256: String)

    var isTrusted: Bool {
        if case .trusted = self { return true }
        return false
    }

    var description: String {
        switch self {
        case .trusted:
            return "trusted"
        case .untrusted:
            return "untrusted"
        case .changed(let recorded, let current):
            return "changed (previously approved: \(recorded.prefix(8))..., current: \(current.prefix(8))...)"
        }
    }
}

/// Stores and verifies user trust approvals for project-local actions.
///
/// Under the C3 trust model:
/// - Actions defined in a project file are trusted on first use (requiring user approval).
/// - Re-confirmed when they change (detected via SHA-256 hash mismatch).
/// - An unapproved project action never runs.
final class ProjectActionTrustStore: @unchecked Sendable {
    static let shared = ProjectActionTrustStore()

    struct Record: Codable, Equatable, Sendable {
        let path: String
        let sha256: String
        let approvedAt: Date

        init(path: String, sha256: String, approvedAt: Date = Date()) {
            self.path = path
            self.sha256 = sha256
            self.approvedAt = approvedAt
        }
    }

    private let lock = NSLock()
    private var records: [String: Record] = [:]
    private var fileURL: URL?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let dir = appSupport?.appendingPathComponent("com.tako-core.terminal")
            self.fileURL = dir?.appendingPathComponent("trusted_actions.json")
        }
        load()
    }

    /// Standardizes a file path to its canonical representation.
    static func canonicalPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }

    /// Computes the hex SHA-256 hash of a string.
    static func sha256(for text: String) -> String {
        let data = Data(text.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Checks the trust status of a project actions file given its path and contents.
    func status(path: String, content: String) -> ProjectActionTrustStatus {
        let canonical = Self.canonicalPath(path)
        let currentHash = Self.sha256(for: content)
        lock.lock()
        defer { lock.unlock() }

        guard let record = records[canonical] else {
            return .untrusted
        }
        if record.sha256 == currentHash {
            return .trusted
        } else {
            return .changed(recordedSHA256: record.sha256, currentSHA256: currentHash)
        }
    }

    /// Returns whether the actions file is trusted without modification.
    func isTrusted(path: String, content: String) -> Bool {
        status(path: path, content: content).isTrusted
    }

    /// Approves a project actions file, recording its content hash.
    func trust(path: String, content: String) {
        let canonical = Self.canonicalPath(path)
        let hash = Self.sha256(for: content)
        lock.lock()
        records[canonical] = Record(path: canonical, sha256: hash, approvedAt: Date())
        lock.unlock()
        save()
    }

    /// Revokes approval for a project actions file.
    func revoke(path: String) {
        let canonical = Self.canonicalPath(path)
        lock.lock()
        records.removeValue(forKey: canonical)
        lock.unlock()
        save()
    }

    /// Clears all records (useful for test isolation).
    func resetForTesting() {
        lock.lock()
        records.removeAll()
        lock.unlock()
    }

    private func load() {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode([String: Record].self, from: data)
            lock.lock()
            self.records = decoded
            lock.unlock()
        } catch {
            // If the store is unreadable, start fresh
            lock.lock()
            self.records = [:]
            lock.unlock()
        }
    }

    private func save() {
        guard let fileURL else { return }
        do {
            let parentDir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            lock.lock()
            let copy = records
            lock.unlock()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(copy)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence failures should not crash the app
        }
    }
}
