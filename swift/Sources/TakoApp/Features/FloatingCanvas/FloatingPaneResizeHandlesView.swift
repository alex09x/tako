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
/// inside the resize handles for both pointer `hitTest` and `accessibilityHitTest`,
/// so no full-pane AXGroup ever intercepts header buttons or terminal AX hit-testing.
struct FloatingPaneResizeHandlesView: NSViewRepresentable {
    let surfaceId: UUID
    let paneRect: CGRect
    let workArea: CGRect
    let onActivate: () -> Void
    let onResizeMove: (CGRect) -> Void
    let onResizeCommit: () -> Void

    /// Equals the header's top control margin, so the top resize strip never reaches the 22pt controls.
    static let topEdgeHitThickness = DesktopCanvasMetrics.headerControlInset
    static let edgeHitThickness: CGFloat = 6
    static let cornerHitSize: CGFloat = 12

    private static let nwseFallbackCursor: NSCursor = makeDiagonalCursor(angleDegrees: -45)
    private static let neswFallbackCursor: NSCursor = makeDiagonalCursor(angleDegrees: 45)

    static func resizeCursor(for edge: FloatingPaneResizeEdge) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition = switch edge {
            case .top: .top
            case .bottom: .bottom
            case .leading: .left
            case .trailing: .right
            case .topLeading: .topLeft
            case .topTrailing: .topRight
            case .bottomLeading: .bottomLeft
            case .bottomTrailing: .bottomRight
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        return switch edge {
        case .leading, .trailing: .resizeLeftRight
        case .top, .bottom: .resizeUpDown
        case .topLeading, .bottomTrailing: nwseFallbackCursor
        case .topTrailing, .bottomLeading: neswFallbackCursor
        }
    }

    private static func makeDiagonalCursor(angleDegrees: CGFloat) -> NSCursor {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: 9, y: 9)
            ctx.rotate(by: angleDegrees * .pi / 180)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: -6.5))
            path.line(to: NSPoint(x: 0, y: 6.5))
            path.move(to: NSPoint(x: -2.6, y: -3.8))
            path.line(to: NSPoint(x: 0, y: -6.8))
            path.line(to: NSPoint(x: 2.6, y: -3.8))
            path.move(to: NSPoint(x: -2.6, y: 3.8))
            path.line(to: NSPoint(x: 0, y: 6.8))
            path.line(to: NSPoint(x: 2.6, y: 3.8))
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.white.setStroke()
            path.lineWidth = 3.0
            path.stroke()
            NSColor.black.setStroke()
            path.lineWidth = 1.5
            path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 9, y: 9))
    }

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
    private let headerCorner = FloatingPaneResizeHandleNSView(edge: .topTrailing, suffix: "-header")
    private let headerSide = FloatingPaneResizeHandleNSView(edge: .trailing, suffix: "-header")

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        var map: [FloatingPaneResizeEdge: FloatingPaneResizeHandleNSView] = [:]
        var list: [FloatingPaneResizeHandleNSView] = []
        for edge in Self.edgeOrder {
            let handle = FloatingPaneResizeHandleNSView(edge: edge)
            map[edge] = handle
            list.append(handle)
        }
        self.handleViews = map
        self.orderedHandles = list + [headerCorner, headerSide]
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        for handle in orderedHandles {
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
        for handle in orderedHandles {
            handle.setAccessibilityIdentifier("FloatingPaneResize-\(handle.identifierPart)-\(uuidKey)")
            handle.setAccessibilityLabel("Resize \(handle.edge.rawValue)")
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
        let topEdge = FloatingPaneResizeHandlesView.topEdgeHitThickness
        let e = FloatingPaneResizeHandlesView.edgeHitThickness
        let c = FloatingPaneResizeHandlesView.cornerHitSize
        let controlsBottom = topEdge + DesktopCanvasMetrics.controlSize

        handleViews[.top]?.frame = CGRect(x: c, y: 0, width: max(0, w - 2 * c), height: topEdge)
        handleViews[.bottom]?.frame = CGRect(x: c, y: max(0, h - e), width: max(0, w - 2 * c), height: e)
        handleViews[.leading]?.frame = CGRect(x: 0, y: c, width: e, height: max(0, h - 2 * c))
        handleViews[.trailing]?.frame = CGRect(x: max(0, w - e), y: controlsBottom, width: e, height: max(0, h - c - controlsBottom))
        handleViews[.topLeading]?.frame = CGRect(x: 0, y: 0, width: c, height: c)
        handleViews[.topTrailing]?.frame = CGRect(x: max(0, w - c), y: 0, width: c, height: topEdge)
        handleViews[.bottomLeading]?.frame = CGRect(x: 0, y: max(0, h - c), width: c, height: c)
        handleViews[.bottomTrailing]?.frame = CGRect(x: max(0, w - c), y: max(0, h - c), width: c, height: c)

        // Beside Close, the narrow gutter handles keep their own cursor and accessibility frames.
        // The first extends the diagonal corner and the second extends the horizontal resize edge.
        let gutter = DesktopCanvasMetrics.headerControlInset
        headerCorner.frame = CGRect(x: w - gutter, y: topEdge, width: gutter, height: c - topEdge)
        headerSide.frame = CGRect(x: w - gutter, y: c, width: gutter, height: controlsBottom - c)
    }

    private func handle(at local: NSPoint) -> NSView? {
        guard bounds.contains(local) else { return nil }
        return orderedHandles.reversed().first { $0.frame.contains(local) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        handle(at: convert(point, from: superview))
    }

    override func accessibilityChildren() -> [Any]? {
        orderedHandles
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard let window else { return nil }
        let winPt = window.convertPoint(fromScreen: point)
        let local = convert(winPt, from: nil)
        return handle(at: local)
    }
}

private final class FloatingPaneResizeHandleNSView: NSView {
    let edge: FloatingPaneResizeEdge
    let identifierPart: String
    var paneRect: CGRect = .zero
    var workArea: CGRect = .zero
    var onActivate: (() -> Void)?
    var onResizeMove: ((CGRect) -> Void)?
    var onResizeCommit: (() -> Void)?

    private var trackingAreaRef: NSTrackingArea?
    private var startWindowPoint: NSPoint?
    private var startRect: CGRect = .zero
    private var didResize = false

    init(edge: FloatingPaneResizeEdge, suffix: String = "") {
        self.edge = edge
        self.identifierPart = edge.rawValue + suffix
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func cursorUpdate(with event: NSEvent) {
        FloatingPaneResizeHandlesView.resizeCursor(for: edge).set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: FloatingPaneResizeHandlesView.resizeCursor(for: edge))
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
