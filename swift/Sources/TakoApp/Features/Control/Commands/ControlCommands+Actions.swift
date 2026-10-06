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
    /// `takoctl action`: project action discovery, execution, approval and status (C3).
    static func actionCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let action: String = try {
            if let a = request.args["action"], case .string(let str) = a { return str }
            if let a = request.args["subcommand"], case .string(let str) = a { return str }
            throw ControlError(.invalid, "action command requires a subcommand (list, run, approve, status)")
        }()

        let surface: Tako.SurfaceView? = (try? target(request, all)) ?? all.first?.surface

        let project: ProjectActionDiscovery.DiscoveredProject? = {
            if let path = request.args["path"]?.string, !path.isEmpty {
                return ProjectActionDiscovery.find(at: path)
            }
            if let surface {
                return ProjectActionDiscovery.find(for: surface)
            }
            return ProjectActionDiscovery.find(at: FileManager.default.currentDirectoryPath)
        }()

        switch action {
        case "list":
            guard let project else {
                return ["actions": .array([])]
            }
            let status = ProjectActionTrustStore.shared.status(path: project.filePath, content: project.fileContent)
            let actionsJson: [JSON] = project.file.actions.map { act in
                var dict: [String: JSON] = [
                    "id": .string(act.id),
                    "title": .string(act.title),
                    "target": .string(act.effectiveTarget.rawValue),
                    "direction": .string(act.effectiveDirection.rawValue),
                    "command": .array(act.effectiveCommand.map(JSON.string))
                ]
                if let desc = act.description { dict["description"] = .string(desc) }
                if let cwd = act.cwd { dict["cwd"] = .string(cwd) }
                return .object(dict)
            }
            return [
                "project": .string(project.projectRoot),
                "path": .string(project.filePath),
                "name": project.file.name.map(JSON.string) ?? .null,
                "trusted": .bool(status.isTrusted),
                "status": .string(status.description),
                "actions": .array(actionsJson)
            ]

        case "run":
            guard let id = request.args["id"]?.string, !id.isEmpty else {
                throw ControlError(.invalid, "action run requires 'id'")
            }
            guard let project else {
                throw ControlError(.notFound, "no project actions found for current pane or specified path")
            }
            guard let act = project.file.actions.first(where: { $0.id == id }) else {
                throw ControlError(.notFound, "action '\(id)' not found in project actions (\(project.filePath))")
            }

            let approveFlag = request.args["approve"] == .bool(true)
            if approveFlag {
                ProjectActionTrustStore.shared.trust(path: project.filePath, content: project.fileContent)
            }

            let status = ProjectActionTrustStore.shared.status(path: project.filePath, content: project.fileContent)
            guard status.isTrusted else {
                throw ControlError(.disabled, "unapproved project actions: approval required (use --approve or takoctl action approve)")
            }

            guard let targetSurface = surface else {
                throw ControlError(.notFound, "no active surface to run project action")
            }

            let takoApp = all.first?.controller?.tako ?? (NSApp?.delegate as? AppDelegate)?.tako
            let result = try ProjectActionManager.shared.execute(
                action: act,
                projectRoot: project.projectRoot,
                from: targetSurface,
                isTrusted: true,
                app: takoApp
            )

            return [
                "ran": .bool(result.executed),
                "id": .string(result.actionId),
                "title": .string(act.title),
                "target": .string(result.target.rawValue),
                "cwd": .string(result.effectiveCwd),
                "trusted": .bool(result.isTrusted)
            ]

        case "approve":
            guard let project else {
                throw ControlError(.notFound, "no project actions found to approve")
            }
            ProjectActionTrustStore.shared.trust(path: project.filePath, content: project.fileContent)
            let hash = ProjectActionTrustStore.sha256(for: project.fileContent)
            return [
                "approved": .bool(true),
                "project": .string(project.projectRoot),
                "path": .string(ProjectActionTrustStore.canonicalPath(project.filePath)),
                "sha256": .string(hash)
            ]

        case "status":
            guard let project else {
                throw ControlError(.notFound, "no project actions found to inspect status")
            }
            let status = ProjectActionTrustStore.shared.status(path: project.filePath, content: project.fileContent)
            let hash = ProjectActionTrustStore.sha256(for: project.fileContent)
            return [
                "project": .string(project.projectRoot),
                "path": .string(ProjectActionTrustStore.canonicalPath(project.filePath)),
                "status": .string(status.description),
                "trusted": .bool(status.isTrusted),
                "sha256": .string(hash),
                "actions_count": .number(Double(project.file.actions.count))
            ]

        default:
            throw ControlError(.invalid, "unknown action subcommand: \(action)")
        }
    }
}
