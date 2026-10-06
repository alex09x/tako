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
    /// `takoctl layout`: declarative layout capture, apply, approve and status (C2).
    static func layoutCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let action: String = try {
            if let a = request.args["action"], case .string(let str) = a { return str }
            if let a = request.args["subcommand"], case .string(let str) = a { return str }
            throw ControlError(.invalid, "layout command requires an action (save, apply, approve, status)")
        }()

        switch action {
        case "save":
            let window: NSWindow? = {
                if let surface = try? target(request, all) {
                    if let win = surface.window { return win }
                    if let matched = all.first(where: { $0.surface === surface }), let win = matched.controller?.window {
                        return win
                    }
                }
                if let app = NSApp, let key = app.keyWindow ?? app.mainWindow { return key }
                if let first = all.first(where: { $0.controller?.window != nil })?.controller?.window {
                    return first
                }
                return TerminalController.all.first?.window
            }()
            guard let window else {
                throw ControlError(.notFound, "no window found to save layout")
            }
            let doc = try LayoutManager.capture(window: window)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(doc)
            let jsonString = String(decoding: data, as: UTF8.self)

            if let path = request.args["path"]?.string, !path.isEmpty {
                let expanded = (path as NSString).expandingTildeInPath
                try data.write(to: URL(fileURLWithPath: expanded), options: .atomic)
            }

            let tabsCount = doc.windows.reduce(0) { $0 + $1.tabs.count }
            let panesCount = doc.allPanes.count
            return [
                "saved": .bool(true),
                "path": request.args["path"] ?? .null,
                "tabs": .number(Double(tabsCount)),
                "panes": .number(Double(panesCount)),
                "content": .string(jsonString)
            ]

        case "apply":
            let rawContent: String
            let filePath: String?
            if let content = request.args["content"]?.string, !content.isEmpty {
                rawContent = content
                filePath = request.args["path"]?.string
            } else if let path = request.args["path"]?.string, !path.isEmpty {
                let expanded = (path as NSString).expandingTildeInPath
                guard FileManager.default.fileExists(atPath: expanded) else {
                    throw ControlError(.notFound, "layout file not found: \(path)")
                }
                rawContent = try String(contentsOfFile: expanded, encoding: .utf8)
                filePath = path
            } else {
                throw ControlError(.invalid, "layout apply requires 'path' or 'content'")
            }

            guard let data = rawContent.data(using: .utf8) else {
                throw ControlError(.invalid, "invalid UTF-8 content in layout")
            }
            let doc = try JSONDecoder().decode(LayoutDocument.self, from: data)

            // Trust evaluation
            let isTrusted: Bool
            if !doc.hasPrograms {
                isTrusted = true
            } else if request.args["approve"] == .bool(true) {
                if let filePath {
                    LayoutTrustStore.shared.trust(path: filePath, content: rawContent)
                }
                isTrusted = true
            } else if let filePath, LayoutTrustStore.shared.isTrusted(path: filePath, content: rawContent) {
                isTrusted = true
            } else {
                if request.args["allow_unapproved"] == .bool(true) {
                    isTrusted = false
                } else {
                    throw ControlError(.disabled, "unapproved layout contains executable programs: approval required (use --approve or takoctl layout approve)")
                }
            }

            let takoApp = all.first?.controller?.tako ?? (NSApp?.delegate as? AppDelegate)?.tako
            let result = try LayoutManager.apply(document: doc, isTrusted: isTrusted, app: takoApp)
            return [
                "applied": .bool(true),
                "path": filePath.map(JSON.string) ?? .null,
                "windows": .number(Double(result.windowsCreated)),
                "tabs": .number(Double(result.tabsCreated)),
                "panes": .number(Double(result.panesCreated)),
                "programs_started": .number(Double(result.programsStarted)),
                "programs_suppressed": .number(Double(result.programsSuppressed)),
                "trusted": .bool(result.isTrusted)
            ]

        case "approve":
            guard let path = request.args["path"]?.string, !path.isEmpty else {
                throw ControlError(.invalid, "layout approve requires 'path'")
            }
            let expanded = (path as NSString).expandingTildeInPath
            let content: String = try {
                if let c = request.args["content"]?.string, !c.isEmpty { return c }
                return try String(contentsOfFile: expanded, encoding: .utf8)
            }()
            LayoutTrustStore.shared.trust(path: expanded, content: content)
            let hash = LayoutTrustStore.sha256(for: content)
            return [
                "approved": .bool(true),
                "path": .string(LayoutTrustStore.canonicalPath(expanded)),
                "sha256": .string(hash)
            ]

        case "status":
            guard let path = request.args["path"]?.string, !path.isEmpty else {
                throw ControlError(.invalid, "layout status requires 'path'")
            }
            let expanded = (path as NSString).expandingTildeInPath
            let content: String = try {
                if let c = request.args["content"]?.string, !c.isEmpty { return c }
                return try String(contentsOfFile: expanded, encoding: .utf8)
            }()
            let status = LayoutTrustStore.shared.status(path: expanded, content: content)
            let hash = LayoutTrustStore.sha256(for: content)
            let hasPrograms = (try? JSONDecoder().decode(LayoutDocument.self, from: Data(content.utf8)))?.hasPrograms ?? false
            return [
                "path": .string(LayoutTrustStore.canonicalPath(expanded)),
                "status": .string(status.description),
                "trusted": .bool(status.isTrusted),
                "sha256": .string(hash),
                "has_programs": .bool(hasPrograms)
            ]

        default:
            throw ControlError(.invalid, "unknown layout action: \(action)")
        }
    }

    /// `takoctl tab-new`: open a new tab beside a targeted pane.
    static func tabNewCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let pane = try ControlLayout.newTab(beside: try target(request, all), args: request.args, client: request.client)
        recordActivity(for: request, on: pane.id, action: "tab-new")
        return ["id": .string(pane.id.uuidString.lowercased())]
    }

    /// `takoctl split`: split a targeted pane.
    static func splitCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let pane = try ControlLayout.split(try target(request, all), args: request.args, client: request.client)
        recordActivity(for: request, on: pane.id, action: "split")
        return ["id": .string(pane.id.uuidString.lowercased())]
    }

    /// `takoctl collapse`: collapse subagent hierarchy for a pane.
    static func collapseCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let surface = try target(request, all)
        recordActivity(for: request, on: surface.id, action: "collapse")
        SubagentHierarchyStore.shared.setCollapsed(surface.id, collapsed: true)
        return ["id": .string(surface.id.uuidString.lowercased()), "collapsed": .bool(true)]
    }

    /// `takoctl expand`: expand subagent hierarchy for a pane.
    static func expandCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let surface = try target(request, all)
        recordActivity(for: request, on: surface.id, action: "expand")
        SubagentHierarchyStore.shared.setCollapsed(surface.id, collapsed: false)
        return ["id": .string(surface.id.uuidString.lowercased()), "collapsed": .bool(false)]
    }

    /// `takoctl focus`: focus a targeted pane.
    static func focusCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let surface = try target(request, all)
        recordActivity(for: request, on: surface.id, action: "focus")
        ControlLayout.focus(surface)
        return ["id": .string(surface.id.uuidString.lowercased())]
    }

    /// `takoctl title`: change the title of a targeted pane.
    static func titleCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let surface = try target(request, all)
        recordActivity(for: request, on: surface.id, action: "title")
        try ControlLayout.title(surface, try ControlInput.text(request.args, "title"))
        return ["id": .string(surface.id.uuidString.lowercased())]
    }
}
