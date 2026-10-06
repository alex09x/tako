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

extension ControlCommands {
    /// `takoctl task`: worktree tasks for isolated agent branches (C4).
    static func taskCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let action: String = try {
            if let a = request.args["action"], case .string(let str) = a { return str }
            if let a = request.args["subcommand"], case .string(let str) = a { return str }
            throw ControlError(.invalid, "task command requires a subcommand (create, list, status, finish)")
        }()

        let surface: Tako.SurfaceView? = (try? target(request, all)) ?? all.first?.surface
        let path: String? = {
            if let p = request.args["path"]?.string, !p.isEmpty { return p }
            if let s = surface, let pwd = s.workingDirectory, !pwd.isEmpty { return pwd }
            return nil
        }()

        switch action {
        case "create":
            guard let name = request.args["name"]?.string, !name.isEmpty else {
                throw ControlError(.invalid, "task create requires 'name'")
            }
            let branch = request.args["branch"]?.string
            let base = request.args["base"]?.string
            let targetStr = request.args["target"]?.string ?? "tab"
            let target: WorktreeTaskTarget = (targetStr == "workspace") ? .workspace : .tab
            let command: [String]? = {
                if let arr = request.args["command"]?.array {
                    return arr.compactMap { $0.string }
                }
                if let str = request.args["command"]?.string, !str.isEmpty {
                    return [str]
                }
                return nil
            }()

            let takoApp = all.first?.controller?.tako ?? (NSApp?.delegate as? AppDelegate)?.tako
            let fromWindow = surface?.window ?? all.first?.controller?.window

            do {
                let info = try WorktreeTaskManager.shared.createTask(
                    name: name,
                    projectPath: path,
                    branch: branch,
                    base: base,
                    target: target,
                    command: command,
                    app: takoApp,
                    fromWindow: fromWindow
                )
                var dict: [String: JSON] = [
                    "created": .bool(true),
                    "id": .string(info.id),
                    "name": .string(info.name),
                    "project": .string(info.projectRoot),
                    "worktree": .string(info.worktreePath),
                    "branch": .string(info.branch),
                    "base": .string(info.baseBranch),
                    "target": .string(info.target.rawValue),
                    "status": .string(info.status.rawValue)
                ]
                if let cmd = info.command {
                    dict["command"] = .array(cmd.map(JSON.string))
                }
                return dict
            } catch {
                throw ControlError(.internalError, error.localizedDescription)
            }

        case "list":
            let tasks = WorktreeTaskManager.shared.listTasks(for: path)
            let tasksJson: [JSON] = tasks.map { t in
                var dict: [String: JSON] = [
                    "id": .string(t.id),
                    "name": .string(t.name),
                    "project": .string(t.projectRoot),
                    "worktree": .string(t.worktreePath),
                    "branch": .string(t.branch),
                    "base": .string(t.baseBranch),
                    "target": .string(t.target.rawValue),
                    "status": .string(t.status.rawValue),
                    "ahead": .number(Double(t.ahead)),
                    "behind": .number(Double(t.behind)),
                    "changed_files": .number(Double(t.changedFiles)),
                    "has_uncommitted": .bool(t.hasUncommitted),
                    "has_unpushed": .bool(t.hasUnpushed)
                ]
                if let cmd = t.command {
                    dict["command"] = .array(cmd.map(JSON.string))
                }
                return .object(dict)
            }
            return [
                "tasks": .array(tasksJson)
            ]

        case "status":
            guard let name = request.args["name"]?.string, !name.isEmpty else {
                throw ControlError(.invalid, "task status requires 'name'")
            }
            do {
                let t = try WorktreeTaskManager.shared.status(name: name, projectPath: path)
                var dict: [String: JSON] = [
                    "id": .string(t.id),
                    "name": .string(t.name),
                    "project": .string(t.projectRoot),
                    "worktree": .string(t.worktreePath),
                    "branch": .string(t.branch),
                    "base": .string(t.baseBranch),
                    "target": .string(t.target.rawValue),
                    "status": .string(t.status.rawValue),
                    "ahead": .number(Double(t.ahead)),
                    "behind": .number(Double(t.behind)),
                    "changed_files": .number(Double(t.changedFiles)),
                    "has_uncommitted": .bool(t.hasUncommitted),
                    "has_unpushed": .bool(t.hasUnpushed)
                ]
                if let cmd = t.command {
                    dict["command"] = .array(cmd.map(JSON.string))
                }
                return dict
            } catch {
                throw ControlError(.notFound, error.localizedDescription)
            }

        case "finish":
            guard let name = request.args["name"]?.string, !name.isEmpty else {
                throw ControlError(.invalid, "task finish requires 'name'")
            }
            let archive = request.args["archive"] == .bool(true)
            let editor = request.args["editor"] == .bool(true)
            let force = request.args["force"] == .bool(true)
            do {
                let res = try WorktreeTaskManager.shared.finishTask(
                    name: name,
                    projectPath: path,
                    archive: archive,
                    editor: editor,
                    force: force
                )
                return [
                    "finished": .bool(true),
                    "id": .string(res.taskId),
                    "name": .string(res.name),
                    "worktree": .string(res.worktreePath),
                    "archived": .bool(res.archived),
                    "opened_in_editor": .bool(res.openedInEditor),
                    "status": .string(res.status.rawValue)
                ]
            } catch {
                throw ControlError(.disabled, error.localizedDescription)
            }

        default:
            throw ControlError(.invalid, "unknown task subcommand: \(action)")
        }
    }
}
