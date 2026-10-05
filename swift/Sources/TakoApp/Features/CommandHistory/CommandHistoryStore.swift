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

/// A single recorded command history entry from shell-integration (OSC 133) records (E9).
public struct CommandHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let command: String
    public let cwd: String?
    public let startedAt: Date
    public let duration: TimeInterval?
    public let exitCode: Int32?
    public let paneId: UUID?

    public init(
        id: UUID = UUID(),
        command: String,
        cwd: String? = nil,
        startedAt: Date = Date(),
        duration: TimeInterval? = nil,
        exitCode: Int32? = nil,
        paneId: UUID? = nil
    ) {
        self.id = id
        self.command = command
        self.cwd = cwd
        self.startedAt = startedAt
        self.duration = duration
        self.exitCode = exitCode
        self.paneId = paneId
    }
}

/// A local, searchable persistent store of commands from shell integration across all panes (E9).
/// Obeys the same privacy rules as snapshots: secure-input sessions contribute nothing.
public final class CommandHistoryStore: @unchecked Sendable {
    public static let shared = CommandHistoryStore()

    /// Maximum entries kept in the local history store.
    public static let maxEntries = 5_000

    private let lock = NSLock()
    private var entries: [CommandHistoryEntry] = []
    public var storageURL: URL?

    public init(storageURL: URL? = nil) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            let bundle = Bundle.main.bundleIdentifier ?? "com.alex09x.tako"
            self.storageURL = base.appendingPathComponent(bundle).appendingPathComponent("command_history.json")
        }
        load()
    }

    /// Records a finished command into history.
    /// Excludes empty commands or callers from secure-input sessions.
    public func record(
        command: String,
        cwd: String?,
        startedAt: Date,
        duration: TimeInterval?,
        exitCode: Int32?,
        paneId: UUID?
    ) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lock.lock()
        let entry = CommandHistoryEntry(
            id: UUID(),
            command: trimmed,
            cwd: cwd,
            startedAt: startedAt,
            duration: duration,
            exitCode: exitCode,
            paneId: paneId
        )
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        lock.unlock()
        save()
    }

    /// Returns all recorded history entries in chronological order.
    public func allEntries() -> [CommandHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// Searches recorded commands by substring query across command text and working directory.
    /// Returns results in reverse chronological order (newest first).
    public func search(query: String, limit: Int = 100) -> [CommandHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        let clampedLimit = max(0, min(limit, 5000))
        guard clampedLimit > 0 else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty {
            return Array(entries.suffix(clampedLimit).reversed())
        }
        let matched = entries.filter { entry in
            entry.command.localizedCaseInsensitiveContains(trimmed) ||
            (entry.cwd?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
        return Array(matched.suffix(clampedLimit).reversed())
    }

    /// Clears all history entries and removes storage file.
    public func clear() {
        lock.lock()
        entries.removeAll()
        let url = storageURL
        lock.unlock()
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func load() {
        guard let url = storageURL, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let loaded = try decoder.decode([CommandHistoryEntry].self, from: data)
            lock.lock()
            self.entries = Array(loaded.suffix(Self.maxEntries))
            lock.unlock()
        } catch {
            // If corrupt or unreadable, start fresh
        }
    }

    private func save() {
        guard let url = storageURL else { return }
        lock.lock()
        let toSave = entries
        lock.unlock()

        do {
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(toSave)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Ignore write failures to avoid interrupting terminal execution
        }
    }
}
