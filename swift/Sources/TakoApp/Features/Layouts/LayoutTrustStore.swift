import Foundation
import CryptoKit

/// Trust status of a layout file.
enum LayoutTrustStatus: Equatable, Sendable {
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

/// Stores and verifies user trust approvals for declarative layout files.
///
/// Under the C2 trust model:
/// - A layout file found in a project is untrusted until the user approves it.
/// - A changed file asks again (detected via SHA-256 content hash mismatch).
/// - An unapproved layout never starts a program.
final class LayoutTrustStore: @unchecked Sendable {
    static let shared = LayoutTrustStore()

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
            self.fileURL = dir?.appendingPathComponent("trusted_layouts.json")
        }
        load()
    }

    /// Standardizes a file path to its canonical representation.
    static func canonicalPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        return standardized
    }

    /// Computes the hex SHA-256 hash of a string.
    static func sha256(for text: String) -> String {
        let data = Data(text.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Computes the hex SHA-256 hash of raw file contents.
    static func sha256(for fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Checks the trust status of a layout file given its path and contents.
    func status(path: String, content: String) -> LayoutTrustStatus {
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

    /// Checks whether a layout file at `path` with `content` is currently trusted.
    func isTrusted(path: String, content: String) -> Bool {
        status(path: path, content: content) == .trusted
    }

    /// Checks whether a layout file on disk is currently trusted.
    func isTrusted(fileURL: URL) -> Bool {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return false
        }
        return isTrusted(path: fileURL.path, content: content)
    }

    /// Approves and records trust for a layout file with its current contents.
    func trust(path: String, content: String) {
        let canonical = Self.canonicalPath(path)
        let hash = Self.sha256(for: content)
        let record = Record(path: canonical, sha256: hash, approvedAt: Date())
        lock.lock()
        records[canonical] = record
        lock.unlock()
        save()
    }

    /// Approves and records trust for a layout file on disk.
    func trust(fileURL: URL) throws {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        trust(path: fileURL.path, content: content)
    }

    /// Revokes trust for a layout file.
    func revoke(path: String) {
        let canonical = Self.canonicalPath(path)
        lock.lock()
        records.removeValue(forKey: canonical)
        lock.unlock()
        save()
    }

    /// Resets all stored trust records (primarily for test isolation).
    func resetForTesting() {
        lock.lock()
        records.removeAll()
        lock.unlock()
    }

    // MARK: - Persistence

    private func load() {
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let loaded = try JSONDecoder().decode([String: Record].self, from: data)
            lock.lock()
            records = loaded
            lock.unlock()
        } catch {
            // Unparseable file: start clean
        }
    }

    private func save() {
        guard let url = fileURL else { return }
        do {
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            lock.lock()
            let copy = records
            lock.unlock()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(copy)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best effort save
        }
    }
}
