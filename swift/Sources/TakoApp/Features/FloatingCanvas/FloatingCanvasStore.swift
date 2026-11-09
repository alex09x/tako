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
    @Published private(set) var activeTransition: FloatingPaneTransition?
    /// `.normal` panes in this set are tiled by the split grid; the rest float.
    @Published internal(set) var tiledIds: Set<UUID> = []
    @Published var dropTarget: CanvasDropTarget?
    /// Identity mirror of the controller's `SplitTree`, used for tile allocation.
    internal(set) var tileTree: CanvasTileNode<UUID>?
    var lastValidCanvasSize: CGSize?
    private(set) var pendingFocus: PendingFocus?
    private(set) var transitionGeneration: UInt64 = 0
    var reduceMotionProvider: () -> Bool = { LivingAnimationState.shared.reduceMotion }

    private var focusGeneration: UInt64 = 0
    private var transitionCleanupTask: Task<Void, Never>?
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

    func snapshot() -> FloatingCanvasSnapshot {
        FloatingCanvasSnapshot(version: 1, panes: panes,
                               tiled: panes.map(\.surfaceId).filter { tiledIds.contains($0) })
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
        tileTree = tree.root.map { CanvasTileNode<UUID>($0) }

        guard !liveIds.isEmpty else {
            panes = []
            tiledIds = []
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
            // Old saved state has no grid: its normal panes stay floating.
            let snapshotIds = Set(snapshot.panes.map(\.surfaceId))
            let added = snapshot.tiled == nil ? [] : liveIds.filter { !snapshotIds.contains($0) }
            tiledIds = Set(snapshot.tiled ?? []).intersection(liveSet).union(added)
            return
        }

        needsInitialRectSeeding = !hasValidSize
        seedInitialRects(for: tree, in: canvas)
    }

    private func seedInitialRects(for tree: SplitTree<Tako.SurfaceView>, in canvasSize: CGSize) {
        let leaves = Array(tree)
        guard !leaves.isEmpty else {
            panes = []
            tiledIds = []
            return
        }
        tiledIds = Set(leaves.map(\.id))
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
        tileTree = tree.root.map { CanvasTileNode<UUID>($0) }
        if leaves.isEmpty {
            if let pending = pendingFocus {
                cancelPendingFocus(for: pending.surfaceId)
            }
            cancelTransition()
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
            if !alive {
                cancelPendingFocus(for: pane.surfaceId)
                cancelTransition(for: pane.surfaceId)
            }
            return alive
        }

        let existingIds = Set(next.map(\.surfaceId))
        let added = leaves.map(\.id).filter { !existingIds.contains($0) }
        guard !added.isEmpty || next.count != panes.count else { return }
        tiledIds = tiledIds.intersection(liveSet).union(added)

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

            let normalCount = next.filter { $0.mode == .normal }.count
            let newRect: CGRect
            if let hint, hint.newId == newId,
               let anchorIdx = next.firstIndex(where: { $0.surfaceId == hint.anchorId }),
               next[anchorIdx].mode == .normal {
                newRect = FloatingPaneGeometry.cascadedRect(from: next[anchorIdx].rect, in: area)
            } else {
                newRect = FloatingPaneGeometry.defaultNormalRect(in: area, cascadeIndex: normalCount)
            }

            next.append(FloatingPaneState(
                surfaceId: newId,
                mode: .normal,
                restoreMode: .normal,
                rect: newRect,
                zOrder: allocateZOrder()
            ))
        }

        if !added.isEmpty { returnMaximizedTilesToGrid(&next) }
        panes = next
        onPersistNeeded?()
    }

    // MARK: - Transition Tracking (190ms Transform-Only, ReduceMotion & Rapid-Cancel Safe)

    func cancelTransition(for surfaceId: UUID? = nil) {
        if let surfaceId, activeTransition?.surfaceId != surfaceId {
            return
        }
        transitionGeneration &+= 1
        transitionCleanupTask?.cancel()
        transitionCleanupTask = nil
        if activeTransition != nil {
            activeTransition = nil
        }
    }

    func recordTransition(
        surfaceId: UUID,
        kind: FloatingPaneTransitionKind,
        fromRect: CGRect,
        toRect: CGRect,
        title: String = "Terminal",
        backgroundColor: NSColor = .black,
        backgroundOpacity: Double = 1.0,
        statusColor: NSColor = .gray
    ) {
        transitionGeneration &+= 1
        let gen = transitionGeneration
        transitionCleanupTask?.cancel()
        transitionCleanupTask = nil

        guard !reduceMotionProvider() else {
            if activeTransition != nil {
                activeTransition = nil
            }
            return
        }

        activeTransition = FloatingPaneTransition(
            generation: gen,
            surfaceId: surfaceId,
            kind: kind,
            fromRect: fromRect,
            toRect: toRect,
            title: title,
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity,
            statusColor: statusColor
        )

        let nanos = UInt64((FloatingCanvasMotion.duration + 0.02) * 1_000_000_000)
        transitionCleanupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self, self.activeTransition?.generation == gen else { return }
            self.activeTransition = nil
            self.transitionCleanupTask = nil
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
