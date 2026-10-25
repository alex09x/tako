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
    /// `takoctl workspace`: manage project workspaces (C1).
    static func workspaceCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let action = request.args["action"]?.string ?? "list"
        switch action {
        case "list":
            let list: [JSON] = WorkspaceStore.shared.workspaces.map { ws in
                var dict: [String: JSON] = [
                    "id": .string(ws.id.uuidString.lowercased()),
                    "name": .string(ws.name),
                    "tabs": .array(ws.tabIdentifiers.map { .string($0) }),
                    "is_active": .bool(ws.id == WorkspaceStore.shared.activeWorkspaceId),
                    "attention_count": .number(Double(WorkspaceStore.shared.attentionCount(for: ws))),
                ]
                if let root = ws.rootDirectory { dict["root_directory"] = .string(root) }
                if let color = ws.color { dict["color"] = .string(color) }
                if let icon = ws.icon { dict["icon"] = .string(icon) }
                if let activeTab = ws.activeTabIdentifier { dict["active_tab"] = .string(activeTab) }
                return .object(dict)
            }
            return ["workspaces": .array(list)]

        case "current":
            let ws = WorkspaceStore.shared.activeWorkspace
            var dict: [String: JSON] = [
                "id": .string(ws.id.uuidString.lowercased()),
                "name": .string(ws.name),
                "tabs": .array(ws.tabIdentifiers.map { .string($0) }),
                "is_active": .bool(true),
                "attention_count": .number(Double(WorkspaceStore.shared.attentionCount(for: ws))),
            ]
            if let root = ws.rootDirectory { dict["root_directory"] = .string(root) }
            if let color = ws.color { dict["color"] = .string(color) }
            if let icon = ws.icon { dict["icon"] = .string(icon) }
            if let activeTab = ws.activeTabIdentifier { dict["active_tab"] = .string(activeTab) }
            return dict

        case "history":
            let items: [JSON] = WorkspaceStore.shared.recentTransitions.map { t in
                .object([
                    "sequence": .number(Double(t.sequence)),
                    "from_id": .string(t.fromId.uuidString.lowercased()),
                    "to_id": .string(t.toId.uuidString.lowercased()),
                    "timestamp": .number(t.timestamp),
                ])
            }
            let tabItems: [JSON] = WorkspaceStore.shared.recentTabTransitions.map { t in
                .object([
                    "sequence": .number(Double(t.sequence)),
                    "workspace_id": .string(t.workspaceId.uuidString.lowercased()),
                    "from_id": .string(t.fromId),
                    "to_id": .string(t.toId),
                    "timestamp": .number(t.timestamp),
                ])
            }
            return [
                "transitions": .array(items),
                "tab_transitions": .array(tabItems),
            ]

        case "switch":
            guard let nameOrId = request.args["name"]?.string, !nameOrId.isEmpty else {
                throw ControlError(.invalid, "workspace name or ID required")
            }
            let switched = WorkspaceStore.shared.switchWorkspace(named: nameOrId) ||
                (UUID(uuidString: nameOrId).map { WorkspaceStore.shared.switchWorkspace(to: $0) } ?? false)
            guard switched else {
                throw ControlError(.notFound, "workspace not found: \(nameOrId)")
            }
            let ws = WorkspaceStore.shared.activeWorkspace
            return [
                "id": .string(ws.id.uuidString.lowercased()),
                "name": .string(ws.name),
                "is_active": .bool(true),
            ]

        case "create":
            guard let name = request.args["name"]?.string, !name.isEmpty else {
                throw ControlError(.invalid, "workspace name required")
            }
            let root = request.args["root"]?.string
            let color = request.args["color"]?.string
            let icon = request.args["icon"]?.string
            let ws = WorkspaceStore.shared.createWorkspace(name: name, rootDirectory: root, color: color, icon: icon)
            var dict: [String: JSON] = [
                "id": .string(ws.id.uuidString.lowercased()),
                "name": .string(ws.name),
            ]
            if let r = ws.rootDirectory { dict["root_directory"] = .string(r) }
            if let c = ws.color { dict["color"] = .string(c) }
            if let i = ws.icon { dict["icon"] = .string(i) }
            return dict

        case "delete":
            guard let nameOrId = request.args["name"]?.string, !nameOrId.isEmpty else {
                throw ControlError(.invalid, "workspace name or ID required")
            }
            let targetWs = WorkspaceStore.shared.workspace(named: nameOrId)
                ?? UUID(uuidString: nameOrId).flatMap { WorkspaceStore.shared.workspace(for: $0) }
            guard let target = targetWs else {
                throw ControlError(.notFound, "workspace not found: \(nameOrId)")
            }
            guard target.id != WorkspaceStore.defaultWorkspaceId else {
                throw ControlError(.invalid, "cannot delete default workspace")
            }
            guard WorkspaceStore.shared.deleteWorkspace(id: target.id) else {
                throw ControlError(.invalid, "failed to delete workspace")
            }
            return ["deleted": .string(target.name)]

        case "assign":
            guard let wsIdentifier = request.args["workspace"]?.string, !wsIdentifier.isEmpty else {
                throw ControlError(.invalid, "workspace name or ID required")
            }
            let targetWs = WorkspaceStore.shared.workspace(named: wsIdentifier)
                ?? UUID(uuidString: wsIdentifier).flatMap { WorkspaceStore.shared.workspace(for: $0) }
            guard let targetWorkspace = targetWs else {
                throw ControlError(.notFound, "workspace not found: \(wsIdentifier)")
            }
            let tabId: String
            if let directTab = request.args["tab"]?.string, !directTab.isEmpty {
                tabId = try resolveTab(directTab, all: all)
            } else {
                let surface = try Self.target(request, all)
                guard let matchedPane = all.first(where: { $0.surface === surface }) else {
                    throw ControlError(.notFound, "cannot determine tab for pane")
                }
                tabId = matchedPane.stableTabID
            }
            WorkspaceStore.shared.assignTab(tabIdentifier: tabId, to: targetWorkspace.id)
            return [
                "tab": .string(tabId),
                "workspace": .string(targetWorkspace.name),
            ]

        default:
            throw ControlError(.invalid, "unknown workspace action: \(action)")
        }
    }

    /// The tab `name` stands for, as the workspace store knows it: a tab's
    /// control id, its stable id, a pane's id -- whole or a prefix of eight
    /// or more characters, as `tree` prints it -- or a tab the store already
    /// lists though its window is not open. Anything else is refused: an
    /// unknown name stored as a tab left the workspace with an entry no
    /// window matches, and the switch to it opened an empty shell while the
    /// real tabs went out of sight.
    static func resolveTab(_ name: String, all: [Pane]) throws -> String {
        if let pane = all.first(where: { $0.tabID == name || $0.stableTabID == name }) {
            return pane.stableTabID
        }
        let wanted = name.lowercased()
        let byPane = all.filter { pane in
            let id = pane.surface.id.uuidString.lowercased()
            return id == wanted || (wanted.count >= 8 && id.hasPrefix(wanted))
        }
        if byPane.count == 1 { return byPane[0].stableTabID }
        if byPane.count > 1 {
            throw ControlError(.invalid, "\"\(name)\" matches panes of several tabs; give more of the id")
        }
        if WorkspaceStore.shared.workspace(forTab: name) != nil { return name }
        throw ControlError(.notFound, "no tab or pane \"\(name)\" (takoctl tree lists them)")
    }
}
