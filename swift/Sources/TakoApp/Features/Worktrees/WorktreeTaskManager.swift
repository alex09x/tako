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
import AppKit
import TakoKit

/// Result of finishing a worktree task.
struct WorktreeTaskFinishResult: Equatable, Sendable {
    let taskId: String
    let name: String
    let worktreePath: String
    let archived: Bool
    let openedInEditor: Bool
    let status: WorktreeTaskStatus
}

/// Orchestrates worktree task creation, git worktree lifecycle, tab/workspace isolation, and archiving (C4).
@MainActor
final class WorktreeTaskManager {
    static let shared = WorktreeTaskManager()

    private let store: WorktreeTaskStore

    init(store: WorktreeTaskStore = .shared) {
        self.store = store
    }

    /// Creates a new git worktree task and opens it as a tab or workspace.
    @discardableResult
    func createTask(
        name: String,
        projectPath: String? = nil,
        branch: String? = nil,
        base: String? = nil,
        target: WorktreeTaskTarget = .tab,
        command: [String]? = nil,
        app: Tako.App? = nil,
        fromWindow: NSWindow? = nil
    ) throws -> WorktreeTaskInfo {
        let lookupPath = projectPath ?? FileManager.default.currentDirectoryPath
        guard let repoRoot = GitWorktreeHelper.findRepoRoot(from: lookupPath) else {
            throw NSError(
                domain: "WorktreeTaskManager",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Not inside a git repository: \(lookupPath)"]
            )
        }

        let sanitizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        guard !sanitizedName.isEmpty else {
            throw NSError(
                domain: "WorktreeTaskManager",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Task name cannot be empty"]
            )
        }

        let worktreePath = ((repoRoot as NSString).appendingPathComponent(".tako/worktrees") as NSString)
            .appendingPathComponent(sanitizedName)
        let effectiveBranch = branch ?? "task/\(sanitizedName)"
        let effectiveBase = base ?? GitWorktreeHelper.resolveBaseBranch(in: repoRoot)

        // 1. Create Git worktree
        try GitWorktreeHelper.createWorktree(
            repoRoot: repoRoot,
            worktreePath: worktreePath,
            branch: effectiveBranch,
            base: effectiveBase
        )

        // 2. Prepare task record
        var task = WorktreeTask(
            name: sanitizedName,
            projectRoot: repoRoot,
            worktreePath: worktreePath,
            branch: effectiveBranch,
            baseBranch: effectiveBase,
            target: target,
            command: command,
            status: .running
        )

        let takoApp = app ?? (NSApplication.shared.delegate as? AppDelegate)?.tako

        // 3. Open in target (workspace or tab)
        var config = Tako.SurfaceConfiguration()
        config.workingDirectory = worktreePath
        if let command, !command.isEmpty {
            config.program = command
        }

        switch target {
        case .workspace:
            let ws = WorkspaceStore.shared.createWorkspace(
                name: "Task: \(sanitizedName)",
                rootDirectory: worktreePath,
                color: "purple",
                icon: "hammer"
            )
            task.workspaceId = ws.id
            WorkspaceStore.shared.switchWorkspace(to: ws.id)

            if let takoApp {
                _ = TerminalController.newWindow(takoApp, withBaseConfig: config)
            }

        case .tab:
            let targetWindow = fromWindow ?? NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow ?? TerminalController.all.first?.window
            if let targetWindow, let takoApp {
                _ = TerminalController.newTab(takoApp, from: targetWindow, withBaseConfig: config)
            }
        }

        store.add(task)

        let status = GitWorktreeHelper.inspectStatus(worktreePath: worktreePath, baseBranch: effectiveBase)
        return WorktreeTaskInfo(
            task: task,
            ahead: status.ahead,
            behind: status.behind,
            changedFiles: status.changedFiles,
            hasUncommitted: status.hasUncommitted,
            hasUnpushed: status.hasUnpushed
        )
    }

    /// Lists active worktree tasks for the project, checking live git status.
    func listTasks(for projectPath: String? = nil) -> [WorktreeTaskInfo] {
        let repoRoot: String? = {
            if let path = projectPath {
                return GitWorktreeHelper.findRepoRoot(from: path)
            }
            return nil
        }()

        let tasks: [WorktreeTask]
        if let repoRoot {
            tasks = store.tasks(for: repoRoot)
        } else {
            tasks = store.allTasks().filter { $0.status != .archived }
        }

        return tasks.map { task in
            let status = GitWorktreeHelper.inspectStatus(worktreePath: task.worktreePath, baseBranch: task.baseBranch)
            return WorktreeTaskInfo(
                task: task,
                ahead: status.ahead,
                behind: status.behind,
                changedFiles: status.changedFiles,
                hasUncommitted: status.hasUncommitted,
                hasUnpushed: status.hasUnpushed
            )
        }
    }

    /// Obtains detailed live status for a specific task.
    func status(name: String, projectPath: String? = nil) throws -> WorktreeTaskInfo {
        let repoRoot = projectPath.flatMap { GitWorktreeHelper.findRepoRoot(from: $0) }
        guard let task = store.task(named: name, in: repoRoot) else {
            throw NSError(
                domain: "WorktreeTaskManager",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Worktree task '\(name)' not found"]
            )
        }
        let status = GitWorktreeHelper.inspectStatus(worktreePath: task.worktreePath, baseBranch: task.baseBranch)
        return WorktreeTaskInfo(
            task: task,
            ahead: status.ahead,
            behind: status.behind,
            changedFiles: status.changedFiles,
            hasUncommitted: status.hasUncommitted,
            hasUnpushed: status.hasUnpushed
        )
    }

    /// Finishes a worktree task: optionally opens in editor and/or archives after verifying clean state.
    func finishTask(
        name: String,
        projectPath: String? = nil,
        archive: Bool = false,
        editor: Bool = false,
        force: Bool = false
    ) throws -> WorktreeTaskFinishResult {
        let repoRoot = projectPath.flatMap { GitWorktreeHelper.findRepoRoot(from: $0) }
        guard let task = store.task(named: name, in: repoRoot) else {
            throw NSError(
                domain: "WorktreeTaskManager",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Worktree task '\(name)' not found"]
            )
        }

        var openedInEditor = false
        if editor {
            let url = URL(fileURLWithPath: task.worktreePath)
            NSWorkspace.shared.open(url)
            openedInEditor = true
        }

        var archived = false
        if archive {
            let gitState = GitWorktreeHelper.inspectStatus(worktreePath: task.worktreePath, baseBranch: task.baseBranch)
            if gitState.hasUncommitted && !force {
                throw NSError(
                    domain: "WorktreeTaskManager",
                    code: 409,
                    userInfo: [NSLocalizedDescriptionKey: "Refusing to archive worktree '\(name)': has \(gitState.changedFiles) uncommitted change(s). Commit, stash, or use --force."]
                )
            }
            if gitState.hasUnpushed && !force {
                throw NSError(
                    domain: "WorktreeTaskManager",
                    code: 409,
                    userInfo: [NSLocalizedDescriptionKey: "Refusing to archive worktree '\(name)': has \(gitState.ahead) unpushed commit(s). Push or use --force."]
                )
            }

            // Clean or forced: remove the worktree
            try GitWorktreeHelper.removeWorktree(
                repoRoot: task.projectRoot,
                worktreePath: task.worktreePath,
                force: force
            )

            // Remove associated workspace if one was created
            if let wsId = task.workspaceId {
                WorkspaceStore.shared.deleteWorkspace(id: wsId)
            }

            store.updateStatus(id: task.id, status: .archived)
            archived = true
        } else {
            store.updateStatus(id: task.id, status: .finished)
        }

        let newStatus: WorktreeTaskStatus = archived ? .archived : .finished
        return WorktreeTaskFinishResult(
            taskId: task.id,
            name: task.name,
            worktreePath: task.worktreePath,
            archived: archived,
            openedInEditor: openedInEditor,
            status: newStatus
        )
    }
}
