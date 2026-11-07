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
import SwiftUI

/// Eight-way edge and corner resize perimeter for `.normal` floating panes.
/// Implemented as a single AppKit `NSView` (`setAccessibilityElement(false)`) that only hits
/// inside the 8 edge/corner handle strips for both pointer `hitTest` and `accessibilityHitTest`,
/// so no full-pane AXGroup ever intercepts header buttons or terminal AX hit-testing.
struct FloatingPaneResizeHandlesView: NSViewRepresentable {
    let surfaceId: UUID
    let paneRect: CGRect
    let workArea: CGRect
    let onActivate: () -> Void
    let onResizeMove: (CGRect) -> Void
    let onResizeCommit: () -> Void

    static let edgeHitThickness: CGFloat = 6
    static let cornerHitSize: CGFloat = 12

    func makeNSView(context: Context) -> FloatingPaneResizePerimeterNSView {
        let view = FloatingPaneResizePerimeterNSView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ nsView: FloatingPaneResizePerimeterNSView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: FloatingPaneResizePerimeterNSView) {
        view.configure(
            uuidKey: surfaceId.uuidString.lowercased(),
            paneRect: paneRect,
            workArea: workArea,
            onActivate: onActivate,
            onResizeMove: onResizeMove,
            onResizeCommit: onResizeCommit
        )
    }
}

final class FloatingPaneResizePerimeterNSView: NSView {
    private static let edgeOrder: [FloatingPaneResizeEdge] = [
        .top, .bottom, .leading, .trailing,
        .topLeading, .topTrailing, .bottomLeading, .bottomTrailing
    ]

    private let handleViews: [FloatingPaneResizeEdge: FloatingPaneResizeHandleNSView]
    private let orderedHandles: [FloatingPaneResizeHandleNSView]

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        var map: [FloatingPaneResizeEdge: FloatingPaneResizeHandleNSView] = [:]
        var list: [FloatingPaneResizeHandleNSView] = []
        for edge in Self.edgeOrder {
            let handle = FloatingPaneResizeHandleNSView(frame: .zero)
            handle.edge = edge
            map[edge] = handle
            list.append(handle)
        }
        self.handleViews = map
        self.orderedHandles = list
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        for handle in list {
            addSubview(handle)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func configure(
        uuidKey: String,
        paneRect: CGRect,
        workArea: CGRect,
        onActivate: @escaping () -> Void,
        onResizeMove: @escaping (CGRect) -> Void,
        onResizeCommit: @escaping () -> Void
    ) {
        for edge in Self.edgeOrder {
            guard let handle = handleViews[edge] else { continue }
            handle.setAccessibilityIdentifier("FloatingPaneResize-\(edge.rawValue)-\(uuidKey)")
            handle.setAccessibilityLabel("Resize \(edge.rawValue)")
            handle.edge = edge
            handle.paneRect = paneRect
            handle.workArea = workArea
            handle.onActivate = onActivate
            handle.onResizeMove = onResizeMove
            handle.onResizeCommit = onResizeCommit
            handle.window?.invalidateCursorRects(for: handle)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        let e = FloatingPaneResizeHandlesView.edgeHitThickness
        let c = FloatingPaneResizeHandlesView.cornerHitSize

        handleViews[.top]?.frame = CGRect(x: c, y: 0, width: max(0, w - 2 * c), height: e)
        handleViews[.bottom]?.frame = CGRect(x: c, y: max(0, h - e), width: max(0, w - 2 * c), height: e)
        handleViews[.leading]?.frame = CGRect(x: 0, y: c, width: e, height: max(0, h - 2 * c))
        handleViews[.trailing]?.frame = CGRect(x: max(0, w - e), y: c, width: e, height: max(0, h - 2 * c))
        handleViews[.topLeading]?.frame = CGRect(x: 0, y: 0, width: c, height: c)
        handleViews[.topTrailing]?.frame = CGRect(x: max(0, w - c), y: 0, width: c, height: c)
        handleViews[.bottomLeading]?.frame = CGRect(x: 0, y: max(0, h - c), width: c, height: c)
        handleViews[.bottomTrailing]?.frame = CGRect(x: max(0, w - c), y: max(0, h - c), width: c, height: c)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for handle in orderedHandles.reversed() where handle.frame.contains(local) {
            return handle
        }
        return nil
    }

    override func accessibilityChildren() -> [Any]? {
        orderedHandles
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard let window else { return nil }
        let winPt = window.convertPoint(fromScreen: point)
        let local = convert(winPt, from: nil)
        guard bounds.contains(local) else { return nil }
        for handle in orderedHandles.reversed() where handle.frame.contains(local) {
            return handle
        }
        return nil
    }
}

private final class FloatingPaneResizeHandleNSView: NSView {
    var edge: FloatingPaneResizeEdge = .bottomTrailing
    var paneRect: CGRect = .zero
    var workArea: CGRect = .zero
    var onActivate: (() -> Void)?
    var onResizeMove: ((CGRect) -> Void)?
    var onResizeCommit: (() -> Void)?

    private var startWindowPoint: NSPoint?
    private var startRect: CGRect = .zero
    private var didResize = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        let cursor: NSCursor = switch edge {
        case .leading, .trailing: .resizeLeftRight
        case .top, .bottom: .resizeUpDown
        case .topLeading, .bottomTrailing, .topTrailing, .bottomLeading: .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        startWindowPoint = event.locationInWindow
        startRect = paneRect
        didResize = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startWindowPoint else { return }
        let current = event.locationInWindow
        let delta = CGSize(width: current.x - start.x, height: -(current.y - start.y))
        guard hypot(delta.width, delta.height) >= 1 || didResize else { return }
        didResize = true
        let updated = edge.applying(delta: delta, to: startRect, within: workArea)
        onResizeMove?(updated)
    }

    override func mouseUp(with event: NSEvent) {
        let shouldCommit = didResize
        startWindowPoint = nil
        didResize = false
        if shouldCommit {
            onResizeCommit?()
        }
    }
}
