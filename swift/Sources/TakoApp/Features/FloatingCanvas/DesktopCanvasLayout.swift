/*
 * tako — Tile allocation, attention counts and status presentation policy for the canvas
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation

/// Identity-only mirror of `SplitTree.Node`, so allocation never mutates the tree.
indirect enum CanvasTileNode<ID: Hashable>: Equatable {
    case leaf(ID)
    case split(horizontal: Bool, ratio: Double, left: CanvasTileNode, right: CanvasTileNode)

    /// Drops leaves not in `keep`; a split with one surviving side collapses to it.
    func pruned(keeping keep: Set<ID>) -> CanvasTileNode? {
        switch self {
        case .leaf(let id):
            return keep.contains(id) ? self : nil
        case .split(let horizontal, let ratio, let left, let right):
            switch (left.pruned(keeping: keep), right.pruned(keeping: keep)) {
            case let (l?, r?): return .split(horizontal: horizontal, ratio: ratio, left: l, right: r)
            case let (l?, nil): return l
            case let (nil, r?): return r
            case (nil, nil): return nil
            }
        }
    }
}

extension CanvasTileNode where ID == UUID {
    init<V: NSView & Codable & Identifiable>(_ node: SplitTree<V>.Node) where V.ID == UUID {
        switch node {
        case .leaf(let view):
            self = .leaf(view.id)
        case .split(let split):
            self = .split(horizontal: split.direction == .horizontal, ratio: split.ratio,
                          left: CanvasTileNode(split.left), right: CanvasTileNode(split.right))
        }
    }
}

enum DesktopCanvasLayout {
    /// Presented frames for every visible pane. Tiled panes share `area` using the
    /// split ratios; floating/minimized/maximized panes are excluded from tiling.
    /// A sole maximized pane covers the area edge-to-edge (no gap or radius inset).
    static func frames(tree: CanvasTileNode<UUID>?, panes: [UUID: CanvasPanePresentation],
                       in area: CGRect, gap: CGFloat = DesktopCanvasMetrics.paneGap) -> [UUID: CGRect] {
        var out: [UUID: CGRect] = [:]
        let maximizedPanes: [CanvasPanePresentation] = panes.values.filter { $0.mode == .maximized }
        if let top = maximizedPanes.max(by: { $0.zOrder < $1.zOrder }) {
            out[top.surfaceId] = area
            return out
        }
        let tiledIDs: [UUID] = panes.values.filter { $0.mode.participatesInTiling }.map { $0.surfaceId }
        let tiled = Set(tiledIDs)
        // Panes absent from the presentation map default to tiled.
        let allLeaves = tree.map(leaves) ?? []
        let keep = tiled.union(allLeaves.filter { panes[$0] == nil })
        if let node = tree?.pruned(keeping: keep) {
            if case .leaf(let only) = node {
                out[only] = area
            } else {
                allocate(node, bounds: area, gap: gap, into: &out)
            }
        }
        for pane in panes.values where pane.mode == .floating {
            let rect = pane.preferredRect ?? FloatingPaneGeometry.defaultNormalRect(in: area)
            out[pane.surfaceId] = FloatingPaneGeometry.clamp(rect, to: area)
        }
        return out
    }

    static func leaves(_ node: CanvasTileNode<UUID>) -> [UUID] {
        switch node {
        case .leaf(let id): return [id]
        case .split(_, _, let l, let r): return leaves(l) + leaves(r)
        }
    }

    private static func allocate(_ node: CanvasTileNode<UUID>, bounds: CGRect, gap: CGFloat,
                                 into out: inout [UUID: CGRect]) {
        switch node {
        case .leaf(let id):
            out[id] = bounds.integral
        case .split(let horizontal, let ratio, let left, let right):
            let r = CGFloat(min(max(ratio, 0.1), 0.9))
            if horizontal {
                let usable = max(2, bounds.width - gap)
                let lw = (usable * r).rounded()
                allocate(left, bounds: CGRect(x: bounds.minX, y: bounds.minY, width: lw, height: bounds.height), gap: gap, into: &out)
                allocate(right, bounds: CGRect(x: bounds.minX + lw + gap, y: bounds.minY, width: usable - lw, height: bounds.height), gap: gap, into: &out)
            } else {
                let usable = max(2, bounds.height - gap)
                let th = (usable * r).rounded()
                allocate(left, bounds: CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: th), gap: gap, into: &out)
                allocate(right, bounds: CGRect(x: bounds.minX, y: bounds.minY + th + gap, width: bounds.width, height: usable - th), gap: gap, into: &out)
            }
        }
    }
}

/// Sidebar attention badge counts keyed by pane identity, so a pane listed both
/// under its session row and as a child row is counted once.
struct SidebarAttentionCounts: Equatable {
    var waiting = 0
    var errors = 0
    var unreadDone = 0

    enum Kind { case waiting, error, done, other }

    init(waiting: Int = 0, errors: Int = 0, unreadDone: Int = 0) {
        self.waiting = waiting
        self.errors = errors
        self.unreadDone = unreadDone
    }

    /// `panes` may repeat ids (parent + child listing); `unread` holds unread pane ids.
    /// Visibility toggles (`status-show`) never feed in here: counting is tracking.
    init(panes: [(id: UUID, kind: Kind)], unread: Set<UUID>, preferences: DesktopPreferences) {
        var seen = Set<UUID>()
        for pane in panes where seen.insert(pane.id).inserted {
            switch pane.kind {
            case .waiting where preferences.countsWaiting: waiting += 1
            case .error where preferences.countsErrors: errors += 1
            case .done where preferences.countsDone && unread.contains(pane.id): unreadDone += 1
            default: break
            }
        }
    }
}

/// Presentation-only status effect choice. Never alters tracked status or unread.
enum CanvasStatusEffect: Equatable {
    case hidden
    case staticIndicator
    case comet
    case breathe

    enum Activity { case working, waiting, other }

    static func resolve(activity: Activity, preferences: DesktopPreferences,
                        reduceMotion: Bool, isVisible: Bool) -> CanvasStatusEffect {
        guard preferences.showsStatus else { return .hidden }
        guard preferences.shouldAnimateStatus(reduceMotion: reduceMotion, isVisible: isVisible) else {
            return .staticIndicator
        }
        switch activity {
        case .working: return .comet
        case .waiting: return .breathe
        case .other: return .staticIndicator
        }
    }

    /// Whether Core Animation layers should be running (paused otherwise).
    var animates: Bool { self == .comet || self == .breathe }
}

enum CanvasPaneTitleColor {
    /// Title color follows the pane's own terminal foreground so it stays readable on
    /// dark and light terminal themes independently of the app palette.
    static func color(foreground: NSColor, background: NSColor) -> NSColor {
        let fg = luminance(foreground), bg = luminance(background)
        let contrast = (max(fg, bg) + 0.05) / (min(fg, bg) + 0.05)
        if contrast >= 3 { return foreground }
        return bg > 0.5 ? .black : .white
    }

    static func luminance(_ color: NSColor) -> CGFloat {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }
}
