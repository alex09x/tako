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
import Combine
import Foundation

/// Per-session state store for floating terminal panes and the bottom-right minimize shelf.
/// `BaseTerminalController.surfaceTree` remains the sole owner of live `Tako.SurfaceView` instances.
@MainActor
final class FloatingCanvasStore: ObservableObject {
    struct PendingFocus: Equatable {
        let surfaceId: UUID
        let generation: UInt64
    }

    struct SplitPlacementHint {
        let anchorId: UUID
        let newId: UUID
        let direction: SplitTree<Tako.SurfaceView>.NewDirection
    }

    @Published internal(set) var panes: [FloatingPaneState] = []
    var lastValidCanvasSize: CGSize?
    private(set) var pendingFocus: PendingFocus?

    private var focusGeneration: UInt64 = 0
    private var nextZOrder: Int = 1
    private var needsInitialRectSeeding = false
    private var pendingSplitHint: SplitPlacementHint?
    var onPersistNeeded: (() -> Void)?

    var hasMinimizedPanes: Bool {
        panes.contains { $0.mode == .minimized }
    }

    var visiblePanesSortedByZ: [FloatingPaneState] {
        panes
            .enumerated()
            .filter { $0.element.mode != .minimized }
            .sorted { lhs, rhs in
                if lhs.element.zOrder != rhs.element.zOrder {
                    return lhs.element.zOrder < rhs.element.zOrder
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    var minimizedPanes: [FloatingPaneState] {
        panes.filter { $0.mode == .minimized }
    }

    var topmostVisiblePane: FloatingPaneState? {
        visiblePanesSortedByZ.last
    }

    func state(for surfaceId: UUID) -> FloatingPaneState? {
        panes.first { $0.surfaceId == surfaceId }
    }

    func isMinimized(_ surfaceId: UUID) -> Bool {
        state(for: surfaceId)?.mode == .minimized
    }

    func effectiveCanvasSize(fallback: CGSize? = nil) -> CGSize {
        if let lastValidCanvasSize, FloatingPaneGeometry.isValidCanvasSize(lastValidCanvasSize) {
            return lastValidCanvasSize
        }
        if let fallback, FloatingPaneGeometry.isValidCanvasSize(fallback) {
            return fallback
        }
        return FloatingPaneGeometry.fallbackCanvasSize
    }

    func snapshot() -> FloatingCanvasSnapshot {
        FloatingCanvasSnapshot(version: 1, panes: panes)
    }

    func setPendingSplitHint(_ hint: SplitPlacementHint?) {
        pendingSplitHint = hint
    }

    // MARK: - Pending Focus Tracking (Attach-Driven, Zero Polling)

    @discardableResult
    func requestPendingFocus(for surfaceId: UUID) -> UInt64 {
        focusGeneration &+= 1
        let pending = PendingFocus(surfaceId: surfaceId, generation: focusGeneration)
        pendingFocus = pending
        return focusGeneration
    }

    func noteExplicitFocusChange(to surfaceId: UUID?) {
        guard let current = pendingFocus else { return }
        if let surfaceId, current.surfaceId != surfaceId {
            focusGeneration &+= 1
            pendingFocus = nil
        }
    }

    func cancelPendingFocus(for surfaceId: UUID) {
        if pendingFocus?.surfaceId == surfaceId {
            pendingFocus = nil
        }
    }

    @discardableResult
    func consumePendingFocusIfMatching(_ surfaceId: UUID) -> Bool {
        guard pendingFocus?.surfaceId == surfaceId else { return false }
        pendingFocus = nil
        return true
    }

    // MARK: - Canvas Size & Restoration

    func updateCanvasSize(_ size: CGSize, tree: SplitTree<Tako.SurfaceView>) {
        guard FloatingPaneGeometry.isValidCanvasSize(size) else { return }
        lastValidCanvasSize = size

        if needsInitialRectSeeding {
            needsInitialRectSeeding = false
            seedInitialRects(for: tree, in: size)
        }
    }

    func loadRestoredSnapshot(
        _ snapshot: FloatingCanvasSnapshot?,
        for tree: SplitTree<Tako.SurfaceView>,
        fallbackSize: CGSize?
    ) {
        if let fallbackSize, FloatingPaneGeometry.isValidCanvasSize(fallbackSize) {
            lastValidCanvasSize = fallbackSize
        }
        let hasValidSize = lastValidCanvasSize != nil
        let canvas = effectiveCanvasSize(fallback: fallbackSize)
        let liveIds = Array(tree).map(\.id)
        let liveSet = Set(liveIds)

        guard !liveIds.isEmpty else {
            panes = []
            needsInitialRectSeeding = false
            return
        }

        if let snapshot, !snapshot.panes.isEmpty {
            let cleanArea = FloatingPaneGeometry.workArea(in: canvas, hasMinimizedPanes: false)
            var restored: [FloatingPaneState] = []
            var seen = Set<UUID>()
            for entry in snapshot.panes where liveSet.contains(entry.surfaceId) && seen.insert(entry.surfaceId).inserted {
                var sanitized = entry
                sanitized.rect = FloatingPaneGeometry.sanitizePreferredRect(
                    entry.rect,
                    fallback: FloatingPaneGeometry.defaultNormalRect(in: cleanArea, cascadeIndex: restored.count)
                )
                restored.append(sanitized)
            }
            normalizeZOrders(&restored)
            let hasMin = restored.contains { $0.mode == .minimized }
            let area = FloatingPaneGeometry.workArea(in: canvas, hasMinimizedPanes: hasMin)
            for id in liveIds where !seen.contains(id) {
                let mode: FloatingPaneMode = restored.isEmpty && liveIds.count == 1 ? .maximized : .normal
                let z = nextZOrder
                nextZOrder += 1
                restored.append(FloatingPaneState(
                    surfaceId: id,
                    mode: mode,
                    rect: FloatingPaneGeometry.defaultNormalRect(in: area, cascadeIndex: restored.count),
                    zOrder: z
                ))
            }
            needsInitialRectSeeding = false
            panes = restored
            return
        }

        needsInitialRectSeeding = !hasValidSize
        seedInitialRects(for: tree, in: canvas)
    }

    private func seedInitialRects(for tree: SplitTree<Tako.SurfaceView>, in canvasSize: CGSize) {
        let leaves = Array(tree)
        guard !leaves.isEmpty else {
            panes = []
            return
        }
        let area = FloatingPaneGeometry.workArea(in: canvasSize, hasMinimizedPanes: false)
        if leaves.count == 1 {
            let id = leaves[0].id
            let z = allocateZOrder()
            panes = [FloatingPaneState(
                surfaceId: id,
                mode: .maximized,
                restoreMode: .maximized,
                rect: FloatingPaneGeometry.defaultNormalRect(in: area, cascadeIndex: 0),
                zOrder: z
            )]
            return
        }

        let mapped = tree.root.map { FloatingPaneGeometry.rectsFromSplitTree($0, in: area) } ?? [:]
        var seeded: [FloatingPaneState] = []
        for (index, leaf) in leaves.enumerated() {
            let rect = mapped[leaf.id] ?? FloatingPaneGeometry.defaultNormalRect(in: area, cascadeIndex: index)
            seeded.append(FloatingPaneState(
                surfaceId: leaf.id,
                mode: .normal,
                restoreMode: .normal,
                rect: rect,
                zOrder: allocateZOrder()
            ))
        }
        panes = seeded
    }

    // MARK: - SurfaceTree Synchronization

    func sync(with tree: SplitTree<Tako.SurfaceView>, fallbackSize: CGSize?) {
        let hint = pendingSplitHint
        pendingSplitHint = nil

        if let fallbackSize, lastValidCanvasSize == nil, FloatingPaneGeometry.isValidCanvasSize(fallbackSize) {
            lastValidCanvasSize = fallbackSize
        }

        let leaves = Array(tree)
        if leaves.isEmpty {
            if let pending = pendingFocus {
                cancelPendingFocus(for: pending.surfaceId)
            }
            if !panes.isEmpty {
                panes = []
                onPersistNeeded?()
            }
            return
        }

        if panes.isEmpty {
            needsInitialRectSeeding = (lastValidCanvasSize == nil)
            seedInitialRects(for: tree, in: effectiveCanvasSize(fallback: fallbackSize))
            onPersistNeeded?()
            return
        }

        let liveSet = Set(leaves.map(\.id))
        var next = panes.filter { pane in
            let alive = liveSet.contains(pane.surfaceId)
            if !alive { cancelPendingFocus(for: pane.surfaceId) }
            return alive
        }

        let existingIds = Set(next.map(\.surfaceId))
        let added = leaves.map(\.id).filter { !existingIds.contains($0) }
        guard !added.isEmpty || next.count != panes.count else { return }

        let canvas = effectiveCanvasSize(fallback: fallbackSize)
        let hasMin = next.contains { $0.mode == .minimized }
        let area = FloatingPaneGeometry.workArea(in: canvas, hasMinimizedPanes: hasMin)

        for newId in added {
            if next.isEmpty {
                next.append(FloatingPaneState(
                    surfaceId: newId,
                    mode: .maximized,
                    restoreMode: .maximized,
                    rect: FloatingPaneGeometry.defaultNormalRect(in: area),
                    zOrder: allocateZOrder()
                ))
                continue
            }

            if let hint, hint.newId == newId,
               let anchorIdx = next.firstIndex(where: { $0.surfaceId == hint.anchorId }) {
                let visibleIndices = next.indices.filter { next[$0].mode != .minimized }
                if visibleIndices.count == 1, visibleIndices.first == anchorIdx, next[anchorIdx].mode == .maximized {
                    let (anchorRect, newRect) = splitPairRects(direction: hint.direction, in: area)
                    next[anchorIdx].mode = .normal
                    next[anchorIdx].restoreMode = .normal
                    next[anchorIdx].rect = anchorRect
                    next.append(FloatingPaneState(
                        surfaceId: newId,
                        mode: .normal,
                        restoreMode: .normal,
                        rect: newRect,
                        zOrder: allocateZOrder()
                    ))
                    continue
                }

                let baseRect = next[anchorIdx].rect
                next.append(FloatingPaneState(
                    surfaceId: newId,
                    mode: .normal,
                    restoreMode: .normal,
                    rect: FloatingPaneGeometry.cascadedRect(from: baseRect, in: area),
                    zOrder: allocateZOrder()
                ))
                continue
            }

            next.append(FloatingPaneState(
                surfaceId: newId,
                mode: .normal,
                restoreMode: .normal,
                rect: FloatingPaneGeometry.defaultNormalRect(in: area, cascadeIndex: next.count),
                zOrder: allocateZOrder()
            ))
        }

        panes = next
        onPersistNeeded?()
    }

    private func splitPairRects(
        direction: SplitTree<Tako.SurfaceView>.NewDirection,
        in area: CGRect
    ) -> (anchor: CGRect, created: CGRect) {
        let gap: CGFloat = 10
        let inset = area.insetBy(dx: 8, dy: 8)
        switch direction {
        case .right, .left:
            let half = max(FloatingPaneGeometry.minSize.width, ((inset.width - gap) * 0.5).rounded())
            let left = FloatingPaneGeometry.clamp(
                CGRect(x: inset.minX, y: inset.minY, width: half, height: inset.height), to: area)
            let right = FloatingPaneGeometry.clamp(
                CGRect(x: inset.maxX - half, y: inset.minY, width: half, height: inset.height), to: area)
            return direction == .right ? (left, right) : (right, left)
        case .down, .up:
            let half = max(FloatingPaneGeometry.minSize.height, ((inset.height - gap) * 0.5).rounded())
            let top = FloatingPaneGeometry.clamp(
                CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: half), to: area)
            let bottom = FloatingPaneGeometry.clamp(
                CGRect(x: inset.minX, y: inset.maxY - half, width: inset.width, height: half), to: area)
            return direction == .down ? (top, bottom) : (bottom, top)
        }
    }

    func normalizeZOrders(_ entries: inout [FloatingPaneState]) {
        let sortedIndices = entries.indices.sorted { lhs, rhs in
            if entries[lhs].zOrder != entries[rhs].zOrder {
                return entries[lhs].zOrder < entries[rhs].zOrder
            }
            return lhs < rhs
        }
        for (rankOffset, idx) in sortedIndices.enumerated() {
            entries[idx].zOrder = rankOffset + 1
        }
        nextZOrder = entries.count + 1
    }

    func allocateZOrder() -> Int {
        if nextZOrder >= Int.max - 1024 {
            normalizeZOrders(&panes)
        }
        defer { nextZOrder += 1 }
        return nextZOrder
    }
}
