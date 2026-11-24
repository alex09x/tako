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

/// A pane's canvas state as `takoctl` names it -- `tiled`, `floating`,
/// `maximized`, `minimized` -- and the one place a request changes it.
@MainActor
enum ControlPaneState {
    static let names = ["tiled", "floating", "maximized", "minimized"]

    static func name(_ mode: CanvasPaneMode) -> String {
        switch mode {
        case .tiled: return "tiled"
        case .floating: return "floating"
        case .maximized: return "maximized"
        case .minimized: return "minimized"
        }
    }

    /// The state a request names; `docked` and `grid` are `tiled` by
    /// another name, `float` is `floating`.
    static func mode(_ name: String) throws -> CanvasPaneMode {
        switch name.lowercased() {
        case "tiled", "tile", "docked", "dock", "grid": return .tiled
        case "floating", "float": return .floating
        case "maximized", "maximize", "zoomed": return .maximized
        case "minimized", "minimize", "shelf": return .minimized
        default:
            throw ControlError(.invalid, "unknown pane state \"\(name)\"; use \(names.joined(separator: ", "))")
        }
    }

    /// The `state` argument of a request, if it has one.
    static func requested(_ args: [String: JSON]) throws -> CanvasPaneMode? {
        guard let raw = args["state"], raw != .null else { return nil }
        guard let name = raw.string else { throw ControlError(.invalid, "\"state\" must be a string") }
        return try mode(name)
    }

    static func controller(of surface: Tako.SurfaceView) throws -> BaseTerminalController {
        guard let controller = BaseTerminalController.owningController(for: surface) else {
            throw ControlError(.notFound, "the pane is not in a window")
        }
        guard controller.usesFloatingCanvas else {
            throw ControlError(.invalid, "the Quick Terminal's panes have no canvas states")
        }
        return controller
    }

    static func rect(_ rect: CGRect) -> JSON {
        .object(["x": .number(rect.minX), "y": .number(rect.minY),
                 "width": .number(rect.width), "height": .number(rect.height)])
    }

    /// The pane's state and where it is, as `pane state` answers: its mode,
    /// whether it belongs to the grid (where it goes back to), what the shelf
    /// restores it as, its own floating rectangle and the frame it shows in
    /// -- both in points from the tab's top left -- and its place in the stack.
    static func describe(_ surface: Tako.SurfaceView) throws -> [String: JSON] {
        let controller = try controller(of: surface)
        let store = controller.floatingCanvas
        guard let mode = controller.canvasMode(of: surface), let pane = store.state(for: surface.id) else {
            throw ControlError(.notFound, "the pane is not on its tab's canvas")
        }
        let presentation = store.presentation(of: pane)
        let grid = store.isTiled(surface.id)
        var result: [String: JSON] = [
            "id": .string(surface.id.uuidString.lowercased()),
            "state": .string(name(mode)),
            "grid": .bool(grid),
            "restoresMaximized": .bool(presentation.restoresMaximized),
            "rect": rect(pane.rect),
            "zOrder": .number(Double(pane.zOrder)),
            "shown": .bool(controller.isShownTab),
        ]
        if mode == .minimized {
            result["restoresTo"] = .string(presentation.restoresMaximized ? "maximized" : name(grid ? .tiled : .floating))
        } else {
            let canvas = store.effectiveCanvasSize(fallback: controller.estimatedFloatingCanvasSize())
            result["frame"] = rect(store.presentedFrame(of: surface.id, in: canvas))
        }
        return result
    }

    /// Moves and sizes the pane as dragging its header and edges does: it
    /// floats there, clamped to the tab. In points from the tab's top left.
    static func setFrame(_ surface: Tako.SurfaceView, to frame: CGRect) throws -> [String: JSON] {
        let controller = try controller(of: surface)
        let store = controller.floatingCanvas
        guard let mode = controller.canvasMode(of: surface) else {
            throw ControlError(.notFound, "the pane is not on its tab's canvas")
        }
        guard mode != .minimized else {
            throw ControlError(.invalid, "the pane is on the shelf; restore it before giving it a frame")
        }
        let min = FloatingPaneGeometry.minSize
        guard frame.width >= min.width, frame.height >= min.height else {
            throw ControlError(.invalid, "a pane is at least \(Int(min.width)) x \(Int(min.height)) points")
        }
        let canvas = store.effectiveCanvasSize(fallback: controller.estimatedFloatingCanvasSize())
        store.setInteractiveRect(frame, for: surface.id, in: canvas)
        store.commitInteractiveRect(for: surface.id, in: canvas)
        SessionSidebarStore.shared.objectWillChange.send()
        return try describe(surface)
    }

    /// Puts the pane in `target`. Brought forward only when its tab is the
    /// one shown and `select` allows: a script never pulls a hidden tab out.
    @discardableResult
    static func set(_ surface: Tako.SurfaceView, to target: CanvasPaneMode, select: Bool = true) throws -> [String: JSON] {
        let controller = try controller(of: surface)
        guard controller.setCanvasMode(surface, to: target, reveal: select && controller.isShownTab) != nil else {
            throw ControlError(.notFound, "the pane is not on its tab's canvas")
        }
        return try describe(surface)
    }

    /// A pane just created by `tab-new`, `split`, `run` or `window new`,
    /// put in the state the request asked for -- straight there, with no
    /// animation from a place it never was -- and answered with its id and
    /// the state it ended in.
    @discardableResult
    static func applyRequested(_ args: [String: JSON], to pane: Tako.SurfaceView) throws -> [String: JSON] {
        var result: [String: JSON] = ["id": .string(pane.id.uuidString.lowercased())]
        if let target = try requested(args) {
            try set(pane, to: target, select: args["select"] != .bool(false))
            BaseTerminalController.owningController(for: pane)?.floatingCanvas.cancelTransition(for: pane.id)
        }
        if let mode = BaseTerminalController.owningController(for: pane)?.canvasMode(of: pane) {
            result["state"] = .string(name(mode))
        }
        return result
    }
}
