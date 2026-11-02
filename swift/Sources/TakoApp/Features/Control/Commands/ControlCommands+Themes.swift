/*
 * tako — Complete theme configuration over the control protocol
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation

extension ControlCommands {
    static func themeCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let app = (NSApp.delegate as? AppDelegate)?.tako ?? all.first?.controller?.tako
        let path = app?.activeConfigPath ?? ProcessInfo.processInfo.environment["TAKO_CONFIG_PATH"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config/tako/config")
        let service = ThemeControlService(configURL: URL(fileURLWithPath: path),
            globalTheme: app.map { owner in { owner.config.theme } }, reload: { app?.reloadConfig() })
        let action = request.args["action"]?.string ?? "list"
        let scoped = ["apply", "current", "reset"].contains(action)
        let scope = scoped ? try themeScope(request, all: all, service: service) : nil
        do {
            var result = try service.handle(request.args, scope: scope)
            if let scope, case .pane(let id, _) = scope {
                let surface = all.first(where: { $0.surface.id == id })?.surface
                result["is_live"] = .bool(surface != nil)
                result["rendered_config"] = surface.map { .string(ThemePresetConfig.configuration(from: $0.theme)) } ?? .null
            }
            return result
        } catch let error as ThemePresetError {
            let code: ControlError.Code
            switch error {
            case .notFound: code = .notFound
            case .readOnlyBuiltin, .cannotShadowBuiltin: code = .disabled
            case .presetAlreadyExists, .staleOverwrite: code = .busy
            case .persistenceFailed: code = .internalError
            default: code = .invalid
            }
            throw ControlError(code, error.localizedDescription)
        }
    }

    static func themeScope(_ request: ControlRequest, all: [Pane], service: ThemeControlService) throws -> ThemeControlScope {
        let args = request.args
        let action = args["action"]?.string ?? "current"
        if action != "current", args["scope"] == nil { throw ControlError(.invalid, "choose --global, --workspace NAME, or --target SESSION") }
        guard args["scope"] == nil || args["scope"]?.string != nil else { throw ControlError(.invalid, "scope must be global, workspace, or pane") }
        switch args["scope"]?.string ?? "pane" {
        case "global":
            guard args["workspace"] == nil, args["target"] == nil else { throw ControlError(.invalid, "theme scopes are mutually exclusive") }
            return .global
        case "workspace":
            guard args["target"] == nil, let name = args["workspace"]?.string, !name.isEmpty else {
                throw ControlError(.invalid, "workspace scope needs a workspace name or UUID, without a pane target")
            }
            if let workspace = service.workspaces.workspaces.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id.uuidString.caseInsensitiveCompare(name) == .orderedSame
            }) { return .workspace(workspace.id, workspace.name) }
            // Retained closed scopes remain inspectable/resettable so their
            // old preset references can be removed safely through the CLI.
            if let id = UUID(uuidString: name), service.appearances.document.overrides(for: .workspace(id)) != nil {
                return .workspace(id, nil)
            }
            throw ControlError(.notFound, "workspace not found: \(name)")
        case "pane":
            guard args["workspace"] == nil, args["target"] == nil || args["target"]?.string != nil else {
                throw ControlError(.invalid, "pane scope accepts a session target, without workspace")
            }
            do {
                let surface = try target(request, all)
                if let pane = all.first(where: { $0.surface === surface }) {
                    let workspace = service.workspaces.workspace(forTab: pane.stableTabID)?.id ?? service.workspaces.activeWorkspaceId
                    return .pane(surface.id, workspaceID: workspace)
                }
            } catch let error as ControlError where error.code == .ambiguous || error.code == .invalid {
                throw error
            } catch {
                // A full saved UUID can be configured before it has a view.
            }
            if let raw = args["target"]?.string, let id = UUID(uuidString: raw) {
                let records = SessionRecordStore(directory: SessionPlaces.support.appendingPathComponent("SessionRecords"))
                if case .record(let saved) = records.read(id) { return .pane(id, workspaceID: saved.workspaceID) }
                if service.appearances.document.overrides(for: .pane(id)) != nil { return .pane(id, workspaceID: nil) }
            }
            throw ControlError(.notFound, "session not found; use its full UUID for a saved session")
        default: throw ControlError(.invalid, "scope must be global, workspace, or pane")
        }
    }
}
