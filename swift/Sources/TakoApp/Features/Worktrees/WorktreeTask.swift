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

/// Target container for a newly created worktree task (C4).
enum WorktreeTaskTarget: String, Codable, Sendable {
    case tab
    case workspace
}

/// Lifecycle status of a worktree task.
enum WorktreeTaskStatus: String, Codable, Sendable {
    case running
    case idle
    case finished
    case archived
    case error
}

/// Represents a parallel agent worktree task with its own working copy and branch (C4).
struct WorktreeTask: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let projectRoot: String
    let worktreePath: String
    let branch: String
    let baseBranch: String
    let target: WorktreeTaskTarget
    let command: [String]?
    let createdAt: Date
    var status: WorktreeTaskStatus
    var tabIdentifier: String?
    var workspaceId: UUID?

    init(
        id: String = UUID().uuidString,
        name: String,
        projectRoot: String,
        worktreePath: String,
        branch: String,
        baseBranch: String,
        target: WorktreeTaskTarget = .tab,
        command: [String]? = nil,
        createdAt: Date = Date(),
        status: WorktreeTaskStatus = .running,
        tabIdentifier: String? = nil,
        workspaceId: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.projectRoot = projectRoot
        self.worktreePath = worktreePath
        self.branch = branch
        self.baseBranch = baseBranch
        self.target = target
        self.command = command
        self.createdAt = createdAt
        self.status = status
        self.tabIdentifier = tabIdentifier
        self.workspaceId = workspaceId
    }
}

/// Snapshot of a worktree task including live git state (ahead/behind, changes).
struct WorktreeTaskInfo: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let projectRoot: String
    let worktreePath: String
    let branch: String
    let baseBranch: String
    let target: WorktreeTaskTarget
    let status: WorktreeTaskStatus
    let ahead: Int
    let behind: Int
    let changedFiles: Int
    let hasUncommitted: Bool
    let hasUnpushed: Bool
    let command: [String]?
    let createdAt: Date

    init(
        task: WorktreeTask,
        ahead: Int,
        behind: Int,
        changedFiles: Int,
        hasUncommitted: Bool,
        hasUnpushed: Bool
    ) {
        self.id = task.id
        self.name = task.name
        self.projectRoot = task.projectRoot
        self.worktreePath = task.worktreePath
        self.branch = task.branch
        self.baseBranch = task.baseBranch
        self.target = task.target
        self.status = task.status
        self.ahead = ahead
        self.behind = behind
        self.changedFiles = changedFiles
        self.hasUncommitted = hasUncommitted
        self.hasUnpushed = hasUnpushed
        self.command = task.command
        self.createdAt = task.createdAt
    }
}
