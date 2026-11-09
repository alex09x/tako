/*
 * tako — Tiled, floating, maximized and minimized canvas presentation on the live store
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import CoreGraphics
import Foundation

extension FloatingCanvasStore {
    func isTiled(_ surfaceId: UUID) -> Bool { tiledIds.contains(surfaceId) }

    func effectiveCanvasSize(fallback: CGSize? = nil) -> CGSize {
        if let lastValidCanvasSize, FloatingPaneGeometry.isValidCanvasSize(lastValidCanvasSize) {
            return lastValidCanvasSize
        }
        if let fallback, FloatingPaneGeometry.isValidCanvasSize(fallback) {
            return fallback
        }
        return FloatingPaneGeometry.fallbackCanvasSize
    }

    /// A split joins the grid: a maximized grid pane returns to its tile so the new pane is visible.
    func returnMaximizedTilesToGrid(_ next: inout [FloatingPaneState]) {
        guard next.count > 1 else { return }
        for i in next.indices where next[i].mode == .maximized && tiledIds.contains(next[i].surfaceId) {
            next[i].mode = .normal
            next[i].restoreMode = .normal
        }
    }

    /// Per-pane presentation derived from the authoritative pane list and grid membership.
    func presentation(of pane: FloatingPaneState) -> CanvasPanePresentation {
        let tiled = tiledIds.contains(pane.surfaceId)
        let mode: CanvasPaneMode
        switch pane.mode {
        case .normal: mode = tiled ? .tiled : .floating
        case .maximized: mode = .maximized
        case .minimized: mode = .minimized
        }
        return CanvasPanePresentation(
            surfaceId: pane.surfaceId, mode: mode, restoreMode: tiled ? .tiled : .floating,
            restoresMaximized: pane.mode == .minimized && pane.restoreMode == .maximized,
            preferredRect: pane.rect, zOrder: pane.zOrder)
    }

    func presentationSnapshot() -> CanvasPresentationSnapshot {
        CanvasPresentationSnapshot(panes: panes.map(presentation(of:)))
    }

    /// Area the split grid is allocated in: the work area inset by the application gap.
    /// The terminal SDK keeps zero padding; this spacing belongs to the canvas.
    static func gridArea(in workArea: CGRect) -> CGRect {
        let gap = DesktopCanvasMetrics.paneGap
        guard workArea.width > 4 * gap, workArea.height > 4 * gap else { return workArea }
        return workArea.insetBy(dx: gap, dy: gap)
    }

    /// Final presented frames for every visible pane. Maximized panes cover the work area;
    /// panes beneath keep their tile/floating frames so they stay mounted.
    func presentedFrames(in canvasSize: CGSize) -> [UUID: CGRect] {
        let area = FloatingPaneGeometry.workArea(in: canvasSize, hasMinimizedPanes: hasMinimizedPanes)
        var underlying: [UUID: CanvasPanePresentation] = [:]
        var maximized: [UUID] = []
        for pane in panes {
            var p = presentation(of: pane)
            if p.mode == .maximized {
                maximized.append(pane.surfaceId)
                p.mode = p.restoreMode == .tiled ? .tiled : .floating
            }
            underlying[pane.surfaceId] = p
        }
        var out = DesktopCanvasLayout.frames(tree: tileTree, panes: underlying, in: Self.gridArea(in: area))
        for (id, p) in underlying where p.mode == .floating {
            out[id] = FloatingPaneGeometry.clamp(p.preferredRect ?? .zero, to: area)
        }
        for id in maximized { out[id] = area }
        return out
    }

    func presentedFrame(of surfaceId: UUID, in canvasSize: CGSize) -> CGRect {
        if let frame = presentedFrames(in: canvasSize)[surfaceId] { return frame }
        guard let pane = state(for: surfaceId) else { return .zero }
        return FloatingPaneGeometry.presentedFrame(for: pane, in: canvasSize, hasMinimizedPanes: hasMinimizedPanes)
    }

    // MARK: - Grid ⇄ free floating

    /// Detaches a grid pane to free floating at its preferred rectangle (kept across
    /// tile/float round trips), or returns a floating pane to its grid slot.
    /// Only the presented frame changes; the Surface, PTY and focus are untouched.
    func toggleFloating(_ surfaceId: UUID, in canvasSize: CGSize? = nil) {
        if let canvasSize, FloatingPaneGeometry.isValidCanvasSize(canvasSize) {
            lastValidCanvasSize = canvasSize
        }
        guard let idx = panes.firstIndex(where: { $0.surfaceId == surfaceId }),
              panes[idx].mode != .minimized else { return }
        let canvas = effectiveCanvasSize(fallback: canvasSize)
        let fromRect = presentedFrame(of: surfaceId, in: canvas)
        if tiledIds.contains(surfaceId) {
            tiledIds.remove(surfaceId)
        } else {
            tiledIds.insert(surfaceId)
        }
        panes[idx].mode = .normal
        panes[idx].restoreMode = .normal
        panes[idx].zOrder = allocateZOrder()
        recordTransition(surfaceId: surfaceId, kind: .modeMorph, fromRect: fromRect,
                         toRect: presentedFrame(of: surfaceId, in: canvas))
        onPersistNeeded?()
    }
}
