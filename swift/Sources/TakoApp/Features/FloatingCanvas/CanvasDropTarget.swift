/*
 * tako — Native terminal docking targets and split insertion
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

struct CanvasDropTarget: Equatable {
    enum Side: CaseIterable { case left, right, top, bottom }
    let anchor: UUID?
    let side: Side
    let frame: CGRect

    var label: String {
        switch side {
        case .left: anchor == nil ? "Left Half" : "Left"
        case .right: anchor == nil ? "Right Half" : "Right"
        case .top: anchor == nil ? "Top Half" : "Above"
        case .bottom: anchor == nil ? "Bottom Half" : "Below"
        }
    }

    static func pick(at point: CGPoint, frames: [UUID: CGRect], area: CGRect) -> Self? {
        guard area.contains(point), !frames.isEmpty else { return nil }
        let edges: [(Side, CGFloat)] = [(.left, point.x - area.minX), (.right, area.maxX - point.x),
                                       (.top, point.y - area.minY), (.bottom, area.maxY - point.y)]
        if let edge = edges.min(by: { $0.1 < $1.1 }), edge.1 < 28 {
            return target(anchor: nil, side: edge.0, rect: area)
        }
        // Stable ordering also makes edge ties deterministic.
        for (id, rect) in frames.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where rect.contains(point) {
            let distances: [(Side, CGFloat)] = [(.left, (point.x - rect.minX) / rect.width),
                (.right, (rect.maxX - point.x) / rect.width), (.top, (point.y - rect.minY) / rect.height),
                (.bottom, (rect.maxY - point.y) / rect.height)]
            guard let edge = distances.min(by: { $0.1 < $1.1 }), edge.1 < 0.35 else { return nil }
            return target(anchor: id, side: edge.0, rect: rect)
        }
        return nil
    }

    private static func target(anchor: UUID?, side: Side, rect: CGRect) -> Self? {
        let horizontal = side == .left || side == .right
        let gap = DesktopCanvasMetrics.paneGap
        let minimum = FloatingPaneGeometry.minSize
        guard horizontal ? rect.width >= minimum.width * 2 + gap : rect.height >= minimum.height * 2 + gap else { return nil }
        var frame = rect
        if horizontal {
            frame.size.width = (rect.width - gap) / 2
            if side == .right { frame.origin.x = rect.maxX - frame.width }
        } else {
            frame.size.height = (rect.height - gap) / 2
            if side == .bottom { frame.origin.y = rect.maxY - frame.height }
        }
        return Self(anchor: anchor, side: side, frame: frame)
    }
}

extension BaseTerminalController {
    func updateCanvasDrop(for surface: Tako.SurfaceView, in size: CGSize) {
        guard let window, let event = NSApp.currentEvent, !event.modifierFlags.contains(.option) else {
            floatingCanvas.dropTarget = nil
            return
        }
        let width = window.contentView?.bounds.width ?? size.width
        let point = CGPoint(x: event.locationInWindow.x - (width - size.width),
                            y: size.height - event.locationInWindow.y)
        var frames = floatingCanvas.presentedFrames(in: size)
        frames = frames.filter { $0.key != surface.id && floatingCanvas.isTiled($0.key) }
        let area = FloatingCanvasStore.gridArea(in: FloatingPaneGeometry.workArea(in: size,
            hasMinimizedPanes: floatingCanvas.hasMinimizedPanes))
        floatingCanvas.dropTarget = CanvasDropTarget.pick(at: point, frames: frames, area: area)
    }

    @discardableResult
    func dockCanvasPane(_ surface: Tako.SurfaceView, at target: CanvasDropTarget) -> Bool {
        guard surfaceTree.contains(surface), let node = surfaceTree.find(id: surface.id) else { return false }
        let reduced = surfaceTree.removing(node)
        let next: SplitTree<Tako.SurfaceView>
        if let id = target.anchor {
            guard let anchor = reduced.first(where: { $0.id == id }) else { return false }
            let direction: SplitTree<Tako.SurfaceView>.NewDirection
            switch target.side { case .left: direction = .left; case .right: direction = .right
            case .top: direction = .up; case .bottom: direction = .down }
            guard let tree = try? reduced.inserting(view: surface, at: anchor, direction: direction) else { return false }
            next = tree
        } else if let root = reduced.root {
            let before = target.side == .left || target.side == .top
            next = .init(root: .split(.init(direction: target.side == .left || target.side == .right ? .horizontal : .vertical,
                ratio: 0.5, left: before ? node : root, right: before ? root : node)), zoomed: nil)
        } else { next = .init(view: surface) }
        floatingCanvas.dropTarget = nil
        floatingCanvas.tiledIds.insert(surface.id)
        replaceSurfaceTree(next, moveFocusTo: surface, undoAction: "Move Terminal")
        floatingCanvas.sync(with: next, fallbackSize: estimatedFloatingCanvasSize())
        revealAndFocusFloatingPane(surface)
        return true
    }
}
