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

/// A pane's place on the canvas as one value -- on the grid, floating,
/// maximized or on the shelf -- and a way to put it in any of them, for
/// `takoctl pane` and for panes created already in a given state.
extension BaseTerminalController {
    /// Where `surface` is on this tab's canvas; nil without a canvas (the
    /// Quick Terminal) or for a pane this tab does not hold.
    func canvasMode(of surface: Tako.SurfaceView) -> CanvasPaneMode? {
        guard usesFloatingCanvas, let pane = floatingCanvas.state(for: surface.id) else { return nil }
        return floatingCanvas.presentation(of: pane).mode
    }

    /// Whether this tab is the one its window shows.
    var isShownTab: Bool {
        guard let window else { return false }
        let group = Tako.CustomTabGroup.group(for: window)
        return group.selectedWindow === window || group.windows.count <= 1
    }

    /// Puts `surface` in `target`, through the same canvas steps the pane's
    /// header buttons take, and answers the mode it ends in.
    ///
    /// `reveal` does what a click does besides: brings the pane forward and
    /// gives it the keyboard (or, minimizing, gives it to the next pane).
    /// Without it only the presentation changes -- a tab that is not shown
    /// stays hidden and the keyboard stays where it is; a pane coming off
    /// the shelf is mounted again and its visibility follows its window.
    @discardableResult
    func setCanvasMode(_ surface: Tako.SurfaceView, to target: CanvasPaneMode, reveal: Bool) -> CanvasPaneMode? {
        guard var mode = canvasMode(of: surface) else { return nil }
        guard mode != target else { return mode }
        let size = estimatedFloatingCanvasSize()
        if target == .minimized {
            minimizeFloatingPane(surface, revealNext: reveal)
            return canvasMode(of: surface)
        }
        if mode == .minimized {
            floatingCanvas.restore(surface.id, in: size)
            mode = canvasMode(of: surface) ?? mode
        }
        if mode == .maximized, target != .maximized {
            floatingCanvas.toggleMaximize(surface.id, in: size)
            mode = canvasMode(of: surface) ?? mode
        }
        switch (mode, target) {
        case (.tiled, .maximized), (.floating, .maximized):
            floatingCanvas.toggleMaximize(surface.id, in: size)
        case (.tiled, .floating), (.floating, .tiled):
            floatingCanvas.toggleFloating(surface.id, in: size)
        default:
            break
        }
        if reveal {
            revealAndFocusFloatingPane(surface, in: size)
        } else {
            SessionSidebarStore.shared.objectWillChange.send()
        }
        return canvasMode(of: surface)
    }
}
