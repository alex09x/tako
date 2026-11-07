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
    /// Expected terminal body size (`SurfaceHostingView` bounds) for a visible floating pane.
    /// Returns `nil` for minimized panes so `reflowSurfaces` preserves their last real PTY grid.
    func presentedBodySize(for surfaceId: UUID, in canvasSize: CGSize) -> CGSize? {
        guard let pane = state(for: surfaceId), pane.mode != .minimized else { return nil }
        let frame = FloatingPaneGeometry.presentedFrame(
            for: pane,
            in: effectiveCanvasSize(fallback: canvasSize),
            hasMinimizedPanes: hasMinimizedPanes
        )
        return FloatingPaneGeometry.bodySize(for: frame)
    }

    /// Selects the next visible floating pane in the requested spatial or cyclic direction.
    /// Minimized panes are excluded from keyboard split navigation until explicitly restored.
    func spatialFocusTarget(
        direction: Tako.SplitFocusDirection,
        from sourceId: UUID,
        in canvasSize: CGSize
    ) -> UUID? {
        let canvas = effectiveCanvasSize(fallback: canvasSize)
        let hasMin = hasMinimizedPanes
        let visible = visiblePanesSortedByZ
        guard visible.count > 1 else { return nil }

        let frames: [UUID: CGRect] = Dictionary(uniqueKeysWithValues: visible.map { pane in
            (pane.surfaceId, FloatingPaneGeometry.presentedFrame(
                for: pane, in: canvas, hasMinimizedPanes: hasMin))
        })

        let orderedForCycle = panes.enumerated()
            .filter { $0.element.mode != .minimized }
            .sorted { lhs, rhs in
                let lf = frames[lhs.element.surfaceId] ?? .zero
                let rf = frames[rhs.element.surfaceId] ?? .zero
                if lf.minY != rf.minY { return lf.minY < rf.minY }
                if lf.minX != rf.minX { return lf.minX < rf.minX }
                if lhs.offset != rhs.offset { return lhs.offset < rhs.offset }
                return lhs.element.surfaceId.uuidString < rhs.element.surfaceId.uuidString
            }
            .map(\.element)

        switch direction {
        case .previous:
            guard let idx = orderedForCycle.firstIndex(where: { $0.surfaceId == sourceId }) else {
                return orderedForCycle.last?.surfaceId
            }
            let prev = (idx - 1 + orderedForCycle.count) % orderedForCycle.count
            return orderedForCycle[prev].surfaceId

        case .next:
            guard let idx = orderedForCycle.firstIndex(where: { $0.surfaceId == sourceId }) else {
                return orderedForCycle.first?.surfaceId
            }
            let next = (idx + 1) % orderedForCycle.count
            return orderedForCycle[next].surfaceId

        case .left, .right, .up, .down:
            guard let sourceFrame = frames[sourceId] else {
                return visible.last(where: { $0.surfaceId != sourceId })?.surfaceId
            }
            var best: (id: UUID, score: CGFloat, zOrder: Int)?
            for candidate in visible where candidate.surfaceId != sourceId {
                guard let rect = frames[candidate.surfaceId] else { continue }
                guard let score = directionalScore(direction: direction, from: sourceFrame, to: rect) else {
                    continue
                }
                if let current = best {
                    if score < current.score || (abs(score - current.score) < 0.5 && candidate.zOrder > current.zOrder) {
                        best = (candidate.surfaceId, score, candidate.zOrder)
                    }
                } else {
                    best = (candidate.surfaceId, score, candidate.zOrder)
                }
            }
            return best?.id
        }
    }

    private func directionalScore(
        direction: Tako.SplitFocusDirection,
        from src: CGRect,
        to dst: CGRect
    ) -> CGFloat? {
        let dx = dst.midX - src.midX
        let dy = dst.midY - src.midY
        switch direction {
        case .left:
            guard dx < -1 else { return nil }
            let overlap = max(0, min(src.maxY, dst.maxY) - max(src.minY, dst.minY))
            let penalty: CGFloat = overlap > 0 ? 0 : abs(dy) * 2.0
            return abs(dx) + abs(dy) * 0.35 + penalty
        case .right:
            guard dx > 1 else { return nil }
            let overlap = max(0, min(src.maxY, dst.maxY) - max(src.minY, dst.minY))
            let penalty: CGFloat = overlap > 0 ? 0 : abs(dy) * 2.0
            return abs(dx) + abs(dy) * 0.35 + penalty
        case .up:
            guard dy < -1 else { return nil }
            let overlap = max(0, min(src.maxX, dst.maxX) - max(src.minX, dst.minX))
            let penalty: CGFloat = overlap > 0 ? 0 : abs(dx) * 2.0
            return abs(dy) + abs(dx) * 0.35 + penalty
        case .down:
            guard dy > 1 else { return nil }
            let overlap = max(0, min(src.maxX, dst.maxX) - max(src.minX, dst.minX))
            let penalty: CGFloat = overlap > 0 ? 0 : abs(dx) * 2.0
            return abs(dy) + abs(dx) * 0.35 + penalty
        case .previous, .next:
            return nil
        }
    }

    /// Resizes a visible `.normal` floating pane from keyboard split-resize shortcuts.
    func resizeByKeyboard(
        _ surfaceId: UUID,
        direction: Tako.SplitResizeDirection,
        amount: CGFloat,
        in canvasSize: CGSize
    ) {
        let canvas = effectiveCanvasSize(fallback: canvasSize)
        guard let idx = panes.firstIndex(where: { $0.surfaceId == surfaceId }),
              panes[idx].mode == .normal else { return }
        let area = FloatingPaneGeometry.workArea(in: canvas, hasMinimizedPanes: hasMinimizedPanes)
        var rect = FloatingPaneGeometry.presentedFrame(
            for: panes[idx],
            in: canvas,
            hasMinimizedPanes: hasMinimizedPanes
        )
        switch direction {
        case .left:
            rect.origin.x -= amount
            rect.size.width += amount
        case .right:
            rect.size.width += amount
        case .up:
            rect.origin.y -= amount
            rect.size.height += amount
        case .down:
            rect.size.height += amount
        }
        panes[idx].rect = FloatingPaneGeometry.clamp(rect, to: area)
        onPersistNeeded?()
    }

    /// Arranges all currently visible panes into an even non-overlapping grid inside `workArea`,
    /// leaving minimized panes untouched on the shelf.
    func equalizeVisiblePanes(in canvasSize: CGSize) {
        let canvas = effectiveCanvasSize(fallback: canvasSize)
        let visibleIndices = panes.indices.filter { panes[$0].mode != .minimized }
        guard !visibleIndices.isEmpty else { return }
        let area = FloatingPaneGeometry.workArea(in: canvas, hasMinimizedPanes: hasMinimizedPanes)
        if visibleIndices.count == 1 {
            let idx = visibleIndices[0]
            panes[idx].mode = .maximized
            panes[idx].restoreMode = .maximized
            onPersistNeeded?()
            return
        }

        let gap: CGFloat = 10
        let inset = area.insetBy(dx: 8, dy: 8)
        let count = visibleIndices.count
        let cols = Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(cols)))
        let cellW = max(1, ((inset.width - CGFloat(cols - 1) * gap) / CGFloat(cols)).rounded())
        let cellH = max(1, ((inset.height - CGFloat(rows - 1) * gap) / CGFloat(rows)).rounded())

        for (order, idx) in visibleIndices.enumerated() {
            let col = order % cols
            let row = order / cols
            let raw = CGRect(
                x: inset.minX + CGFloat(col) * (cellW + gap),
                y: inset.minY + CGFloat(row) * (cellH + gap),
                width: cellW,
                height: cellH
            )
            panes[idx].mode = .normal
            panes[idx].restoreMode = .normal
            panes[idx].rect = FloatingPaneGeometry.clamp(raw, to: area)
        }
        onPersistNeeded?()
    }
}
