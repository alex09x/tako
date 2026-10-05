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
import Testing
import AppKit
@testable import Tako
import TakoKit

@Suite @MainActor struct WorktreeTaskTests {

    @Test func testWorktreeTaskCodableRoundTrip() throws {
        let task = WorktreeTask(
            id: "task-uuid-1",
            name: "agent-work",
            projectRoot: "/tmp/project",
            worktreePath: "/tmp/project/.tako/worktrees/agent-work",
            branch: "task/agent-work",
            baseBranch: "main",
            target: .workspace,
            command: ["cargo", "test"],
            status: .running
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(task)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(WorktreeTask.self, from: data)

        #expect(decoded.id == task.id)
        #expect(decoded.name == task.name)
        #expect(decoded.projectRoot == task.projectRoot)
        #expect(decoded.worktreePath == task.worktreePath)
        #expect(decoded.branch == task.branch)
        #expect(decoded.baseBranch == task.baseBranch)
        #expect(decoded.target == .workspace)
        #expect(decoded.command == ["cargo", "test"])
        #expect(decoded.status == .running)
    }

    @Test func testWorktreeTaskStoreOperations() throws {
        let store = WorktreeTaskStore(isTesting: true)
        let t1 = WorktreeTask(
            id: "t1",
            name: "task-one",
            projectRoot: "/tmp/repo-a",
            worktreePath: "/tmp/repo-a/.tako/worktrees/task-one",
            branch: "task/task-one",
            baseBranch: "main"
        )
        let t2 = WorktreeTask(
            id: "t2",
            name: "task-two",
            projectRoot: "/tmp/repo-b",
            worktreePath: "/tmp/repo-b/.tako/worktrees/task-two",
            branch: "task/task-two",
            baseBranch: "main"
        )

        store.add(t1)
        store.add(t2)

        #expect(store.task(id: "t1")?.name == "task-one")
        #expect(store.task(named: "task-two", in: "/tmp/repo-b")?.id == "t2")
        #expect(store.task(named: "task-two", in: "/tmp/repo-a") == nil)

        let repoATasks = store.tasks(for: "/tmp/repo-a")
        #expect(repoATasks.count == 1)
        #expect(repoATasks.first?.id == "t1")

        store.updateStatus(id: "t1", status: .finished)
        #expect(store.task(id: "t1")?.status == .finished)

        store.remove(id: "t2")
        #expect(store.task(id: "t2") == nil)
    }

    @Test func testThreeTasksRunSideBySideWithoutTouchingFiles() throws {
        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tako_worktree_test_\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        // Setup a real git repo
        _ = GitWorktreeHelper.runGit(["init", "-b", "main"], in: tempDir.path)
        _ = GitWorktreeHelper.runGit(["config", "user.name", "Tako Test"], in: tempDir.path)
        _ = GitWorktreeHelper.runGit(["config", "user.email", "test@tako.local"], in: tempDir.path)

        let initialFile = tempDir.appendingPathComponent("README.md")
        try "Initial project content".write(to: initialFile, atomically: true, encoding: .utf8)
        _ = GitWorktreeHelper.runGit(["add", "README.md"], in: tempDir.path)
        _ = GitWorktreeHelper.runGit(["commit", "-m", "Initial commit"], in: tempDir.path)

        let store = WorktreeTaskStore(isTesting: true)
        let manager = WorktreeTaskManager(store: store)

        // Create 3 tasks side by side
        let info1 = try manager.createTask(name: "task-alpha", projectPath: tempDir.path, target: .tab)
        let info2 = try manager.createTask(name: "task-beta", projectPath: tempDir.path, target: .tab)
        let info3 = try manager.createTask(name: "task-gamma", projectPath: tempDir.path, target: .tab)

        #expect(fm.fileExists(atPath: info1.worktreePath))
        #expect(fm.fileExists(atPath: info2.worktreePath))
        #expect(fm.fileExists(atPath: info3.worktreePath))

        // Modify file in task-1
        let f1 = URL(fileURLWithPath: info1.worktreePath).appendingPathComponent("alpha.txt")
        try "Content from Alpha".write(to: f1, atomically: true, encoding: .utf8)

        // Modify file in task-2
        let f2 = URL(fileURLWithPath: info2.worktreePath).appendingPathComponent("beta.txt")
        try "Content from Beta".write(to: f2, atomically: true, encoding: .utf8)

        // Modify file in task-3
        let f3 = URL(fileURLWithPath: info3.worktreePath).appendingPathComponent("gamma.txt")
        try "Content from Gamma".write(to: f3, atomically: true, encoding: .utf8)

        // Verify task isolation: none of them see each other's new files
        #expect(fm.fileExists(atPath: f1.path))
        #expect(!fm.fileExists(atPath: URL(fileURLWithPath: info1.worktreePath).appendingPathComponent("beta.txt").path))
        #expect(!fm.fileExists(atPath: URL(fileURLWithPath: info1.worktreePath).appendingPathComponent("gamma.txt").path))

        #expect(fm.fileExists(atPath: f2.path))
        #expect(!fm.fileExists(atPath: URL(fileURLWithPath: info2.worktreePath).appendingPathComponent("alpha.txt").path))
        #expect(!fm.fileExists(atPath: URL(fileURLWithPath: info2.worktreePath).appendingPathComponent("gamma.txt").path))

        #expect(fm.fileExists(atPath: f3.path))
        #expect(!fm.fileExists(atPath: URL(fileURLWithPath: info3.worktreePath).appendingPathComponent("alpha.txt").path))
        #expect(!fm.fileExists(atPath: URL(fileURLWithPath: info3.worktreePath).appendingPathComponent("beta.txt").path))

        // Main repository does not have uncommitted files from worktrees
        #expect(!fm.fileExists(atPath: tempDir.appendingPathComponent("alpha.txt").path))
        #expect(!fm.fileExists(atPath: tempDir.appendingPathComponent("beta.txt").path))
        #expect(!fm.fileExists(atPath: tempDir.appendingPathComponent("gamma.txt").path))

        // List tasks
        let list = manager.listTasks(for: tempDir.path)
        #expect(list.count == 3)
    }

    @Test func testArchivingRefusesUncommittedAndUnpushedWork() throws {
        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tako_archive_safety_\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        _ = GitWorktreeHelper.runGit(["init", "-b", "main"], in: tempDir.path)
        _ = GitWorktreeHelper.runGit(["config", "user.name", "Tako Test"], in: tempDir.path)
        _ = GitWorktreeHelper.runGit(["config", "user.email", "test@tako.local"], in: tempDir.path)

        let initialFile = tempDir.appendingPathComponent("README.md")
        try "Initial".write(to: initialFile, atomically: true, encoding: .utf8)
        _ = GitWorktreeHelper.runGit(["add", "README.md"], in: tempDir.path)
        _ = GitWorktreeHelper.runGit(["commit", "-m", "Initial"], in: tempDir.path)

        let store = WorktreeTaskStore(isTesting: true)
        let manager = WorktreeTaskManager(store: store)

        let taskInfo = try manager.createTask(name: "safety-task", projectPath: tempDir.path, target: .tab)

        // 1. Uncommitted change: should refuse archiving
        let dirtyFile = URL(fileURLWithPath: taskInfo.worktreePath).appendingPathComponent("work.txt")
        try "Unsaved work".write(to: dirtyFile, atomically: true, encoding: .utf8)

        #expect(throws: Error.self) {
            try manager.finishTask(name: "safety-task", projectPath: tempDir.path, archive: true, force: false)
        }
        #expect(fm.fileExists(atPath: taskInfo.worktreePath))
        #expect(fm.fileExists(atPath: dirtyFile.path))

        // 2. Commit the change locally (unpushed): should also refuse archiving without force
        _ = GitWorktreeHelper.runGit(["add", "work.txt"], in: taskInfo.worktreePath)
        _ = GitWorktreeHelper.runGit(["commit", "-m", "Work in progress"], in: taskInfo.worktreePath)

        #expect(throws: Error.self) {
            try manager.finishTask(name: "safety-task", projectPath: tempDir.path, archive: true, force: false)
        }
        #expect(fm.fileExists(atPath: taskInfo.worktreePath))

        // 3. Forced archive: removes cleanly
        let forcedResult = try manager.finishTask(name: "safety-task", projectPath: tempDir.path, archive: true, force: true)
        #expect(forcedResult.archived)
        #expect(!fm.fileExists(atPath: taskInfo.worktreePath))
    }

    @Test func testControlTaskCommands() throws {
        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tako_ctrl_task_\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        _ = GitWorktreeHelper.runGit(["init", "-b", "main"], in: tempDir.path)
        _ = GitWorktreeHelper.runGit(["config", "user.name", "Tako Test"], in: tempDir.path)
        _ = GitWorktreeHelper.runGit(["config", "user.email", "test@tako.local"], in: tempDir.path)

        let initialFile = tempDir.appendingPathComponent("README.md")
        try "Initial".write(to: initialFile, atomically: true, encoding: .utf8)
        _ = GitWorktreeHelper.runGit(["add", "README.md"], in: tempDir.path)
        _ = GitWorktreeHelper.runGit(["commit", "-m", "Initial"], in: tempDir.path)

        let app = Tako.App()
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        surface.pwd = tempDir.path
        let tree = SplitTree<Tako.SurfaceView>(view: surface)
        let controller = BaseTerminalController(app, surfaceTree: tree)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        win.windowController = controller
        controller.window = win
        win.contentView = surface

        let pane = ControlCommands.Pane(
            surface: surface,
            windowID: "win-1",
            tabID: "tab-1",
            stableTabID: win.stableTabIdentifier,
            controller: controller
        )

        // 1. Task Create
        let createReq = ControlRequest(
            cmd: "task",
            args: [
                "action": .string("create"),
                "name": .string("ctrl-agent-task"),
                "path": .string(tempDir.path),
                "target": .string("tab")
            ],
            from: nil
        )
        let createResp = try ControlCommands.taskCommand(createReq, all: [pane])
        #expect(createResp["created"]?.bool == true)
        #expect(createResp["name"]?.string == "ctrl-agent-task")
        #expect(createResp["branch"]?.string == "task/ctrl-agent-task")

        // 2. Task Status
        let statusReq = ControlRequest(
            cmd: "task",
            args: [
                "action": .string("status"),
                "name": .string("ctrl-agent-task"),
                "path": .string(tempDir.path)
            ],
            from: nil
        )
        let statusResp = try ControlCommands.taskCommand(statusReq, all: [pane])
        #expect(statusResp["name"]?.string == "ctrl-agent-task")
        #expect(statusResp["status"]?.string == "running")

        // 3. Task List
        let listReq = ControlRequest(
            cmd: "task",
            args: [
                "action": .string("list"),
                "path": .string(tempDir.path)
            ],
            from: nil
        )
        let listResp = try ControlCommands.taskCommand(listReq, all: [pane])
        guard let tasks = listResp["tasks"]?.array else {
            Issue.record("Expected tasks array")
            return
        }
        #expect(!tasks.isEmpty)

        // 4. Task Finish (clean archive)
        let finishReq = ControlRequest(
            cmd: "task",
            args: [
                "action": .string("finish"),
                "name": .string("ctrl-agent-task"),
                "archive": .bool(true),
                "path": .string(tempDir.path)
            ],
            from: nil
        )
        let finishResp = try ControlCommands.taskCommand(finishReq, all: [pane])
        #expect(finishResp["finished"]?.bool == true)
        #expect(finishResp["archived"]?.bool == true)
    }

    @Test func testLargeGitOutputDoesNotDeadlockPipeBuffer() throws {
        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tako_deadlock_test_\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        _ = GitWorktreeHelper.runGit(["init", "-b", "main"], in: tempDir.path)
        _ = GitWorktreeHelper.runGit(["config", "user.name", "Tako Test"], in: tempDir.path)
        _ = GitWorktreeHelper.runGit(["config", "user.email", "test@tako.local"], in: tempDir.path)

        let initialFile = tempDir.appendingPathComponent("README.md")
        try "Initial".write(to: initialFile, atomically: true, encoding: .utf8)
        _ = GitWorktreeHelper.runGit(["add", "README.md"], in: tempDir.path)
        _ = GitWorktreeHelper.runGit(["commit", "-m", "Initial commit"], in: tempDir.path)

        let store = WorktreeTaskStore(isTesting: true)
        let manager = WorktreeTaskManager(store: store)

        let taskInfo = try manager.createTask(name: "large-changeset", projectPath: tempDir.path, target: .tab)

        // Generate > 1,500 modified/untracked files to exceed macOS 64KB kernel pipe buffer
        let worktreeURL = URL(fileURLWithPath: taskInfo.worktreePath)
        for i in 1...1500 {
            let fileURL = worktreeURL.appendingPathComponent("file_with_a_moderately_long_path_name_\(i).txt")
            try "sample content".write(to: fileURL, atomically: true, encoding: .utf8)
        }

        // inspectStatus invokes `git status --porcelain`, which produces > 75KB of output.
        // Before the fix, this would permanently deadlock waiting for process exit before reading pipe handles.
        let status = GitWorktreeHelper.inspectStatus(worktreePath: taskInfo.worktreePath, baseBranch: "main")
        #expect(status.hasUncommitted == true)
        #expect(status.changedFiles >= 1500)

        let liveStatus = try manager.status(name: "large-changeset", projectPath: tempDir.path)
        #expect(liveStatus.hasUncommitted == true)
        #expect(liveStatus.changedFiles >= 1500)
    }
}

