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

/// A pane's place on its tab's canvas as a layout file keeps it: the mode
/// it shows in, whether it belongs to the grid, what the shelf gives back,
/// and its own floating rectangle -- enough that a saved layout opens with
/// every pane where it was and restoring each one brings it back the same.
@MainActor
enum LayoutPanePresentation {
    /// `pane` with the presentation of `surface` filled in; a plain tile
    /// keeps every field out of the file.
    static func capture(_ surface: Tako.SurfaceView, in controller: BaseTerminalController,
                        into pane: LayoutPane) -> LayoutPane {
        let store = controller.floatingCanvas
        guard let mode = controller.canvasMode(of: surface), let state = store.state(for: surface.id),
              mode != .tiled else { return pane }
        let grid = store.isTiled(surface.id)
        var pane = pane
        pane.state = ControlPaneState.name(mode)
        pane.grid = grid
        pane.restoresMaximized = store.presentation(of: state).restoresMaximized ? true : nil
        pane.rect = grid ? nil : LayoutFrame(state.rect)
        return pane
    }

    /// A pane's presentation fields, checked before anything opens.
    static func validate(_ pane: LayoutPane) throws {
        let mode = try pane.state.map(ControlPaneState.mode) ?? .tiled
        if pane.grid == false, mode == .tiled {
            throw ControlError(.invalid, "a pane in state tiled is on the grid; grid false contradicts it")
        }
        if pane.grid == true, mode == .floating {
            throw ControlError(.invalid, "a floating pane is off the grid; grid true contradicts it")
        }
        if pane.restoresMaximized == true, mode != .minimized {
            throw ControlError(.invalid, "restoresMaximized is for a minimized pane")
        }
        if let rect = pane.rect {
            let min = FloatingPaneGeometry.minSize
            guard [rect.x, rect.y, rect.width, rect.height].allSatisfy(\.isFinite),
                  rect.width >= min.width, rect.height >= min.height else {
                throw ControlError(.invalid, "a pane's rect is four finite numbers, at least \(Int(min.width)) x \(Int(min.height))")
            }
        }
    }

    /// Each pane of a tab just opened, put where its file says, through the
    /// canvas store and the same steps the pane header takes: its rectangle
    /// and grid membership first, then maximized, and the shelf last so a
    /// minimized pane remembers what it was. Nothing is brought forward,
    /// nothing animates.
    static func apply(_ tab: LayoutTab, to controller: BaseTerminalController) {
        let surfaces = Array(controller.surfaceTree)
        let panes = tab.allPanes
        guard surfaces.count == panes.count, controller.usesFloatingCanvas else { return }
        let store = controller.floatingCanvas
        var shelf: [Tako.SurfaceView] = []
        for (surface, pane) in zip(surfaces, panes) {
            guard let mode = try? pane.state.map(ControlPaneState.mode) ?? .tiled else { continue }
            let grid = pane.grid ?? (mode != .floating)
            if let rect = pane.rect {
                let canvas = store.effectiveCanvasSize(fallback: controller.estimatedFloatingCanvasSize())
                store.setInteractiveRect(rect.asRect, for: surface.id, in: canvas)
                store.commitInteractiveRect(for: surface.id, in: canvas)
            }
            controller.setCanvasMode(surface, to: grid ? .tiled : .floating, reveal: false)
            if mode == .maximized || (mode == .minimized && pane.restoresMaximized == true) {
                controller.setCanvasMode(surface, to: .maximized, reveal: false)
            }
            if mode == .minimized { shelf.append(surface) }
            store.cancelTransition(for: surface.id)
        }
        for surface in shelf {
            controller.setCanvasMode(surface, to: .minimized, reveal: false)
            store.cancelTransition(for: surface.id)
        }
    }
}
