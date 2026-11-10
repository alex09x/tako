/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

extension ControlCommands {
    /// `takoctl pane`: a pane's canvas state, what the pane header's buttons
    /// change -- `state`, `float`, `dock`, `maximize`, `unmaximize`,
    /// `minimize`, `restore`, `set STATE` -- and `move` to a window of its own.
    static func paneCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let action = request.args["action"]?.string ?? "state"
        let surface = try target(request, all)
        recordActivity(for: request, on: surface.id, action: "pane \(action)")
        let select = request.args["select"] != .bool(false)
        switch action {
        case "state", "get":
            return try ControlPaneState.describe(surface)
        case "set":
            guard let state = try ControlPaneState.requested(request.args) else {
                throw ControlError(.invalid, "pane set needs a state: \(ControlPaneState.names.joined(separator: ", "))")
            }
            return try ControlPaneState.set(surface, to: state, select: select)
        case "float":
            return try ControlPaneState.set(surface, to: .floating, select: select)
        case "dock", "tile":
            return try ControlPaneState.set(surface, to: .tiled, select: select)
        case "maximize":
            return try ControlPaneState.set(surface, to: .maximized, select: select)
        case "minimize":
            return try ControlPaneState.set(surface, to: .minimized, select: select)
        case "unmaximize", "restore":
            return try restore(surface, select: select)
        case "frame":
            guard let frame = try requestedFrame(request.args) else { return try ControlPaneState.describe(surface) }
            return try ControlPaneState.setFrame(surface, to: frame)
        case "move":
            return try moveToNewWindow(surface, args: request.args)
        default:
            throw ControlError(.invalid, "unknown pane action \"\(action)\"; use state, set, float, dock, maximize, unmaximize, minimize, restore, frame or move")
        }
    }

    /// Off the shelf to the state it left, or out of maximized to its own
    /// place; a pane in neither stays as it is.
    private static func restore(_ surface: Tako.SurfaceView, select: Bool) throws -> [String: JSON] {
        let controller = try ControlPaneState.controller(of: surface)
        switch controller.canvasMode(of: surface) {
        case .minimized?:
            let pane = controller.floatingCanvas.state(for: surface.id)
            let target: CanvasPaneMode = pane?.restoreMode == .maximized ? .maximized
                : controller.floatingCanvas.isTiled(surface.id) ? .tiled : .floating
            return try ControlPaneState.set(surface, to: target, select: select)
        case .maximized?:
            let target: CanvasPaneMode = controller.floatingCanvas.isTiled(surface.id) ? .tiled : .floating
            return try ControlPaneState.set(surface, to: target, select: select)
        default:
            return try ControlPaneState.describe(surface)
        }
    }

    /// `pane move --window new`: the pane leaves its tab for a new window.
    private static func moveToNewWindow(_ surface: Tako.SurfaceView, args: [String: JSON]) throws -> [String: JSON] {
        let destination = args["window"]?.string ?? "new"
        guard destination == "new" else {
            throw ControlError(.invalid, "pane move takes --window new; moving into another window is not supported yet")
        }
        let controller = try ControlPaneState.controller(of: surface)
        // The new window belongs where the pane's tab did, not to whichever
        // workspace happens to be in front.
        let workspace = controller.window.flatMap { WorkspaceStore.shared.workspace(forTab: $0.stableTabIdentifier) }
        guard let moved = controller.moveSurfaceToNewWindow(surface), let window = moved.window else {
            throw ControlError(.invalid, "the pane is alone in its tab; it already has a window of its own")
        }
        if let workspace {
            WorkspaceStore.shared.assignTab(tabIdentifier: window.stableTabIdentifier, to: workspace.id)
        }
        var result: [String: JSON] = [
            "id": .string(surface.id.uuidString.lowercased()),
            "window": .string(windowID(window)),
        ]
        if let workspace { result["workspace"] = .string(workspace.name) }
        return result
    }

    /// The id `tree` and `window list` give the window holding `window`'s tab.
    static func windowID(_ window: NSWindow) -> String {
        "window-\(ObjectIdentifier(Tako.CustomTabGroup.group(for: window)).hexString)"
    }
}
