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

/// Central store for managing active and archived worktree tasks (C4).
final class WorktreeTaskStore: @unchecked Sendable {
    static let shared = WorktreeTaskStore()

    private let lock = NSLock()
    private var tasksById: [String: WorktreeTask] = [:]
    private var fileURL: URL?
    private let isTesting: Bool

    init(fileURL: URL? = nil, isTesting: Bool = false) {
        self.isTesting = isTesting
        if let fileURL {
            self.fileURL = fileURL
        } else if !isTesting {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let dir = appSupport?.appendingPathComponent("com.tako-core.terminal")
            self.fileURL = dir?.appendingPathComponent("worktree_tasks.json")
        }
        load()
    }

    private func load() {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode([WorktreeTask].self, from: data)
            lock.lock()
            defer { lock.unlock() }
            for task in decoded {
                tasksById[task.id] = task
            }
        } catch {
            NSLog("[WorktreeTaskStore] Failed to load tasks from \(fileURL.path): \(error)")
        }
    }

    private func save() {
        guard let fileURL, !isTesting else { return }
        lock.lock()
        let tasks = Array(tasksById.values)
        lock.unlock()

        do {
            let parentDir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(atPath: parentDir.path, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(tasks)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[WorktreeTaskStore] Failed to save tasks to \(fileURL.path): \(error)")
        }
    }

    func add(_ task: WorktreeTask) {
        lock.lock()
        tasksById[task.id] = task
        lock.unlock()
        save()
    }

    func task(id: String) -> WorktreeTask? {
        lock.lock()
        defer { lock.unlock() }
        return tasksById[id]
    }

    func task(named name: String, in projectRoot: String? = nil) -> WorktreeTask? {
        lock.lock()
        defer { lock.unlock() }
        return tasksById.values.first { task in
            let nameMatches = task.name == name || task.id == name
            if let projectRoot {
                let canonicalRoot = (projectRoot as NSString).standardizingPath
                let taskRoot = (task.projectRoot as NSString).standardizingPath
                return nameMatches && taskRoot == canonicalRoot
            }
            return nameMatches
        }
    }

    func tasks(for projectRoot: String) -> [WorktreeTask] {
        let canonical = (projectRoot as NSString).standardizingPath
        lock.lock()
        defer { lock.unlock() }
        return tasksById.values
            .filter { ( $0.projectRoot as NSString ).standardizingPath == canonical && $0.status != .archived }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func allTasks() -> [WorktreeTask] {
        lock.lock()
        defer { lock.unlock() }
        return Array(tasksById.values).sorted { $0.createdAt < $1.createdAt }
    }

    func updateStatus(id: String, status: WorktreeTaskStatus) {
        lock.lock()
        if var task = tasksById[id] {
            task.status = status
            tasksById[id] = task
        }
        lock.unlock()
        save()
    }

    func remove(id: String) {
        lock.lock()
        tasksById.removeValue(forKey: id)
        lock.unlock()
        save()
    }

    func resetForTesting() {
        lock.lock()
        tasksById.removeAll()
        lock.unlock()
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
