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
        applyInteractiveRect(rect, for: surfaceId, in: canvasSize, detachFromGrid: true)
    }

    func setHeaderDragRect(_ rect: CGRect, for surfaceId: UUID, in canvasSize: CGSize) {
        beginHeaderDrag(for: surfaceId)
        applyInteractiveRect(rect, for: surfaceId, in: canvasSize, detachFromGrid: false)
    }

    private func applyInteractiveRect(_ rect: CGRect, for surfaceId: UUID, in canvasSize: CGSize, detachFromGrid: Bool) {
        guard FloatingPaneGeometry.isValidCanvasSize(canvasSize),
              let idx = panes.firstIndex(where: { $0.surfaceId == surfaceId }) else { return }
        cancelTransition(for: surfaceId)
        lastValidCanvasSize = canvasSize
        let area = FloatingPaneGeometry.workArea(in: canvasSize, hasMinimizedPanes: hasMinimizedPanes)
        let clamped = FloatingPaneGeometry.clamp(rect, to: area)
        // Explicit rect edits detach; header drags choose their final mode on release.
        if detachFromGrid && tiledIds.contains(surfaceId) { tiledIds.remove(surfaceId) }
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
        cancelTransition(for: surfaceId)
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
        if !canDockHeaderDrag(surfaceId) { tiledIds.remove(surfaceId) }
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
        let canvas = effectiveCanvasSize(fallback: canvasSize)
        let priorPane = panes[idx]
        let priorMinCount = minimizedPanes.count
        let fromRect: CGRect = priorPane.mode == .minimized
            ? FloatingCanvasMotion.shelfAnchorRect(in: canvas, minimizedCount: priorMinCount)
            : presentedFrame(of: surfaceId, in: canvas)
        cancelHeaderDrag(for: surfaceId)

        switch panes[idx].mode {
        case .maximized:
            panes[idx].mode = .normal
            panes[idx].restoreMode = .normal
        case .normal, .minimized:
            panes[idx].mode = .maximized
            panes[idx].restoreMode = .maximized
        }
        panes[idx].zOrder = allocateZOrder()

        let toRect = presentedFrame(of: surfaceId, in: canvas)
        recordTransition(
            surfaceId: surfaceId,
            kind: priorPane.mode == .minimized ? .restoring : .modeMorph,
            fromRect: fromRect,
            toRect: toRect
        )
        onPersistNeeded?()
    }

    func minimize(
        _ surfaceId: UUID,
        title: String = "Terminal",
        backgroundColor: NSColor = .black,
        backgroundOpacity: Double = 1.0,
        statusColor: NSColor = .gray
    ) {
        guard let idx = panes.firstIndex(where: { $0.surfaceId == surfaceId }),
              panes[idx].mode != .minimized else { return }
        let canvas = effectiveCanvasSize()
        let departingFrame = presentedFrame(of: surfaceId, in: canvas)
        cancelHeaderDrag(for: surfaceId)
        cancelPendingFocus(for: surfaceId)
        panes[idx].restoreMode = (panes[idx].mode == .maximized) ? .maximized : .normal
        panes[idx].mode = .minimized
        let shelfTarget = FloatingCanvasMotion.shelfAnchorRect(
            in: canvas,
            minimizedCount: minimizedPanes.count
        )
        recordTransition(
            surfaceId: surfaceId,
            kind: .minimizing,
            fromRect: departingFrame,
            toRect: shelfTarget,
            title: title,
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity,
            statusColor: statusColor
        )
        onPersistNeeded?()
    }

    /// Restores a minimized pane to its exact prior visible mode (`.maximized` or `.normal` with its saved preferred `rect`).
    @discardableResult
    func restore(_ surfaceId: UUID, in canvasSize: CGSize? = nil) -> FloatingPaneMode? {
        if let canvasSize, FloatingPaneGeometry.isValidCanvasSize(canvasSize) {
            lastValidCanvasSize = canvasSize
        }
        guard let idx = panes.firstIndex(where: { $0.surfaceId == surfaceId }) else { return nil }
        let wasMinimized = (panes[idx].mode == .minimized)
        let priorMinCount = minimizedPanes.count
        if wasMinimized {
            let targetMode: FloatingPaneMode = (panes[idx].restoreMode == .maximized) ? .maximized : .normal
            panes[idx].mode = targetMode
        }
        panes[idx].zOrder = allocateZOrder()

        if wasMinimized {
            let canvas = effectiveCanvasSize(fallback: canvasSize)
            let fromRect = FloatingCanvasMotion.shelfAnchorRect(in: canvas, minimizedCount: priorMinCount)
            let toRect = presentedFrame(of: surfaceId, in: canvas)
            recordTransition(
                surfaceId: surfaceId,
                kind: .restoring,
                fromRect: fromRect,
                toRect: toRect
            )
        }
        onPersistNeeded?()
        return panes[idx].mode
    }
}
