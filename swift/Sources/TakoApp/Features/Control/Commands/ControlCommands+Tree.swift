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
    /// The one pane a request means, decided now -- `active` included.
    static func target(_ request: ControlRequest, _ all: [Pane]) throws -> Tako.SurfaceView {
        let id = try ControlTarget.from(request.args, requestFrom: request.from)
            .resolve(panes: all.map(\.surface.id), requestFrom: request.from, active: activePane(all))
        guard let pane = all.first(where: { $0.surface.id == id }) else {
            throw ControlError(.notFound, "no pane \(id.uuidString.lowercased())")
        }
        return pane.surface
    }

    static func version() -> [String: JSON] {
        let info = Bundle.main.infoDictionary ?? [:]
        return [
            "app": .string("Tako"),
            "version": .string(info["CFBundleShortVersionString"] as? String ?? ""),
            "build": .string(info["CFBundleVersion"] as? String ?? ""),
            "protocol": .number(Double(ControlProtocol.version)),
        ]
    }

    /// Windows, their tabs, and the panes in each. What the shell reported
    /// and nothing guessed: `cwd` is the last OSC 7 directory; `pid` and
    /// `tty` are the pane's own process, and null when that process is the
    /// client of a persistent session rather than the shell.
    static func tree(_ panes: [Pane], active: UUID?) -> [String: JSON] {
        var windows: [(id: String, tabs: [(id: String, panes: [JSON])])] = []
        var tabInfo: [String: [String: JSON]] = [:]
        for pane in panes {
            let surface = pane.surface
            let persistent = surface.persistence != nil
            var node: [String: JSON] = [
                "id": .string(surface.id.uuidString.lowercased()),
                "title": .string(surface.title),
                "cwd": surface.pwd.map(JSON.string) ?? .null,
                "focused": .bool(surface.id == active),
                "status": .string(surface.crab.paneStatus.rawValue),
                "unread": .bool(surface.crab.unread),
                "alternateScreen": .bool(surface.isAlternateScreen),
                "persistentSession": .bool(persistent),
                "exited": .bool(surface.processExited),
            ]
            if let text = surface.crab.statusText {
                node["statusText"] = .string(text)
            }
            if let ttl = surface.crab.remainingTTL {
                node["statusTTL"] = .number(ttl)
            }
            if let parent = SubagentHierarchyStore.shared.parent(of: surface.id) {
                node["parent"] = .string(parent.uuidString.lowercased())
            }
            if let label = SubagentHierarchyStore.shared.label(for: surface.id) {
                node["label"] = .string(label)
            }
            if SubagentHierarchyStore.shared.hasChildren(surface.id) {
                let children = SubagentHierarchyStore.shared.children(of: surface.id)
                node["children"] = .array(children.map { .string($0.uuidString.lowercased()) })
                if let summary = SubagentHierarchyStore.shared.statusSummary(for: surface.id) {
                    node["childrenStatus"] = .string(summary)
                }
                node["collapsed"] = .bool(SubagentHierarchyStore.shared.isCollapsed(surface.id))
            }
            if persistent {
                node["pid"] = .null
                node["tty"] = .null
            } else {
                node["pid"] = surface.surfaceModel?.foregroundPID.map { .number(Double($0)) } ?? .null
                node["tty"] = surface.surfaceModel?.ttyName.map(JSON.string) ?? .null
            }
            // Grouped by id, in the order first seen: tabs of one window
            // need not come one after another.
            let w = windows.firstIndex { $0.id == pane.windowID } ?? {
                windows.append((pane.windowID, []))
                return windows.count - 1
            }()
            let t = windows[w].tabs.firstIndex { $0.id == pane.tabID } ?? {
                windows[w].tabs.append((pane.tabID, []))
                if let controller = pane.controller {
                    tabInfo[pane.tabID] = tabFacts(controller)
                }
                return windows[w].tabs.count - 1
            }()
            windows[w].tabs[t].panes.append(.object(node))
        }
        return ["windows": .array(windows.map { window in
            // Tabs in the order the tab bar shows them.
            let tabs = window.tabs.sorted {
                (tabInfo[$0.id]?["index"]?.number ?? 0) < (tabInfo[$1.id]?["index"]?.number ?? 0)
            }
            return .object([
                "id": .string(window.id),
                "tabs": .array(tabs.map { tab in
                    var node = tabInfo[tab.id] ?? [:]
                    node["id"] = .string(tab.id)
                    node["panes"] = .array(tab.panes)
                    return .object(node)
                }),
            ])
        })]
    }

    /// What a tab adds to its panes: its place in the tab bar (from 1), its
    /// title, whether it is the one shown, and how its panes are split --
    /// `{"pane": id}` or `{"split": "right"|"down", "ratio", "children": [a, b]}`.
    static func tabFacts(_ controller: BaseTerminalController) -> [String: JSON] {
        var facts: [String: JSON] = ["layout": controller.surfaceTree.root.map(layout) ?? .null]
        if let window = controller.window, !(controller is QuickTerminalController) {
            let group = Tako.CustomTabGroup.group(for: window)
            facts["index"] = .number(Double((group.windows.firstIndex { $0 === window } ?? 0) + 1))
            facts["selected"] = .bool(group.selectedWindow === window || group.windows.count <= 1)
            facts["title"] = .string(controller.titleOverride ?? window.title)
            let ws = WorkspaceStore.shared.workspace(forTab: window.stableTabIdentifier) ?? WorkspaceStore.shared.activeWorkspace
            facts["workspace"] = .string(ws.name)
        }
        return facts
    }

    static func layout(_ node: SplitTree<Tako.SurfaceView>.Node) -> JSON {
        switch node {
        case .leaf(let view):
            return .object(["pane": .string(view.id.uuidString.lowercased())])
        case .split(let split):
            return .object([
                "split": .string(split.direction == .horizontal ? "right" : "down"),
                "ratio": .number((split.ratio * 100).rounded() / 100),
                "children": .array([layout(split.left), layout(split.right)]),
            ])
        }
    }
}

