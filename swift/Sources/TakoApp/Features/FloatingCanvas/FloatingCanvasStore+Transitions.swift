/*
 * tako — Terminal emulator
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
    // MARK: - Window Operations (Z-Order, Move, Resize, Maximize, Minimize, Restore)

    func bringToFront(_ surfaceId: UUID, persist: Bool = true) {
        guard let idx = panes.firstIndex(where: { $0.surfaceId == surfaceId }),
              panes[idx].mode != .minimized else { return }
        let currentMax = panes.filter { $0.mode != .minimized }.map(\.zOrder).max() ?? 0
        guard panes[idx].zOrder < currentMax || panes.filter({ $0.mode != .minimized && $0.zOrder == currentMax }).count > 1 else {
            return
        }
        panes[idx].zOrder = allocateZOrder()
        if persist { onPersistNeeded?() }
    }

    func setInteractiveRect(_ rect: CGRect, for surfaceId: UUID, in canvasSize: CGSize) {
        guard FloatingPaneGeometry.isValidCanvasSize(canvasSize),
              let idx = panes.firstIndex(where: { $0.surfaceId == surfaceId }) else { return }
        lastValidCanvasSize = canvasSize
        let area = FloatingPaneGeometry.workArea(in: canvasSize, hasMinimizedPanes: hasMinimizedPanes)
        let clamped = FloatingPaneGeometry.clamp(rect, to: area)
        var updated = panes[idx]
        updated.mode = .normal
        updated.restoreMode = .normal
        updated.rect = clamped
        if updated != panes[idx] {
            panes[idx] = updated
        }
    }

    func commitInteractiveRect(for surfaceId: UUID, in canvasSize: CGSize) {
        if FloatingPaneGeometry.isValidCanvasSize(canvasSize),
           let idx = panes.firstIndex(where: { $0.surfaceId == surfaceId }),
           panes[idx].mode == .normal {
            let area = FloatingPaneGeometry.workArea(in: canvasSize, hasMinimizedPanes: hasMinimizedPanes)
            panes[idx].rect = FloatingPaneGeometry.clamp(panes[idx].rect, to: area)
        }
        onPersistNeeded?()
    }

    func detachMaximizedForDrag(
        _ surfaceId: UUID,
        pointerXInCanvas: CGFloat,
        pointerYInHeader: CGFloat,
        in canvasSize: CGSize
    ) -> CGRect? {
        guard FloatingPaneGeometry.isValidCanvasSize(canvasSize),
              let idx = panes.firstIndex(where: { $0.surfaceId == surfaceId }),
              panes[idx].mode == .maximized else { return nil }
        lastValidCanvasSize = canvasSize
        let area = FloatingPaneGeometry.workArea(in: canvasSize, hasMinimizedPanes: hasMinimizedPanes)
        let normal = FloatingPaneGeometry.clamp(panes[idx].rect, to: area)
        let ratio = min(max(pointerXInCanvas / max(1, area.width), 0.1), 0.9)
        let originX = pointerXInCanvas - normal.width * ratio
        let originY = max(area.minY, pointerYInHeader - min(max(pointerYInHeader, 4), FloatingPaneGeometry.headerHeight - 4))
        let detached = FloatingPaneGeometry.clamp(
            CGRect(x: originX.rounded(), y: originY.rounded(), width: normal.width, height: normal.height),
            to: area
        )
        panes[idx].mode = .normal
        panes[idx].restoreMode = .normal
        panes[idx].rect = detached
        panes[idx].zOrder = allocateZOrder()
        return detached
    }

    func toggleMaximize(_ surfaceId: UUID, in canvasSize: CGSize? = nil) {
        if let canvasSize, FloatingPaneGeometry.isValidCanvasSize(canvasSize) {
            lastValidCanvasSize = canvasSize
        }
        guard let idx = panes.firstIndex(where: { $0.surfaceId == surfaceId }) else { return }
        switch panes[idx].mode {
        case .maximized:
            let area = FloatingPaneGeometry.workArea(
                in: effectiveCanvasSize(fallback: canvasSize),
                hasMinimizedPanes: hasMinimizedPanes
            )
            panes[idx].rect = FloatingPaneGeometry.clamp(panes[idx].rect, to: area)
            panes[idx].mode = .normal
            panes[idx].restoreMode = .normal
        case .normal, .minimized:
            panes[idx].mode = .maximized
            panes[idx].restoreMode = .maximized
        }
        panes[idx].zOrder = allocateZOrder()
        onPersistNeeded?()
    }

    func minimize(_ surfaceId: UUID) {
        guard let idx = panes.firstIndex(where: { $0.surfaceId == surfaceId }),
              panes[idx].mode != .minimized else { return }
        cancelPendingFocus(for: surfaceId)
        panes[idx].restoreMode = (panes[idx].mode == .maximized) ? .maximized : .normal
        panes[idx].mode = .minimized
        onPersistNeeded?()
    }

    /// Restores a minimized pane to its exact prior visible mode (`.maximized` or `.normal` with its saved `rect`).
    @discardableResult
    func restore(_ surfaceId: UUID, in canvasSize: CGSize? = nil) -> FloatingPaneMode? {
        if let canvasSize, FloatingPaneGeometry.isValidCanvasSize(canvasSize) {
            lastValidCanvasSize = canvasSize
        }
        guard let idx = panes.firstIndex(where: { $0.surfaceId == surfaceId }) else { return nil }
        if panes[idx].mode == .minimized {
            let targetMode: FloatingPaneMode = (panes[idx].restoreMode == .maximized) ? .maximized : .normal
            panes[idx].mode = targetMode
        }
        let area = FloatingPaneGeometry.workArea(
            in: effectiveCanvasSize(fallback: canvasSize),
            hasMinimizedPanes: panes.contains { $0.mode == .minimized }
        )
        panes[idx].rect = FloatingPaneGeometry.clamp(panes[idx].rect, to: area)
        panes[idx].zOrder = allocateZOrder()
        onPersistNeeded?()
        return panes[idx].mode
    }
}
