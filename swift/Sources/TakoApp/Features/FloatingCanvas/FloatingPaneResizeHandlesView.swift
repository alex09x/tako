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
struct FloatingPaneResizeHandlesView: View {
    let surfaceId: UUID
    let paneRect: CGRect
    let workArea: CGRect
    let onActivate: () -> Void
    let onResizeMove: (CGRect) -> Void
    let onResizeCommit: () -> Void

    private static let edgeHitThickness: CGFloat = 6
    private static let cornerHitSize: CGFloat = 12

    private var uuidKey: String {
        surfaceId.uuidString.lowercased()
    }

    var body: some View {
        ZStack {
            handle(.top)
                .frame(maxWidth: .infinity)
                .frame(height: Self.edgeHitThickness)
                .padding(.horizontal, Self.cornerHitSize)
                .frame(maxHeight: .infinity, alignment: .top)

            handle(.bottom)
                .frame(maxWidth: .infinity)
                .frame(height: Self.edgeHitThickness)
                .padding(.horizontal, Self.cornerHitSize)
                .frame(maxHeight: .infinity, alignment: .bottom)

            handle(.leading)
                .frame(width: Self.edgeHitThickness)
                .frame(maxHeight: .infinity)
                .padding(.vertical, Self.cornerHitSize)
                .frame(maxWidth: .infinity, alignment: .leading)

            handle(.trailing)
                .frame(width: Self.edgeHitThickness)
                .frame(maxHeight: .infinity)
                .padding(.vertical, Self.cornerHitSize)
                .frame(maxWidth: .infinity, alignment: .trailing)

            handle(.topLeading)
                .frame(width: Self.cornerHitSize, height: Self.cornerHitSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            handle(.topTrailing)
                .frame(width: Self.cornerHitSize, height: Self.cornerHitSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            handle(.bottomLeading)
                .frame(width: Self.cornerHitSize, height: Self.cornerHitSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

            handle(.bottomTrailing)
                .frame(width: Self.cornerHitSize, height: Self.cornerHitSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("FloatingPaneResize-\(uuidKey)")
    }

    private func handle(_ edge: FloatingPaneResizeEdge) -> some View {
        FloatingPaneResizeHandleStrip(
            edge: edge,
            identifier: "FloatingPaneResize-\(edge.rawValue)-\(uuidKey)",
            paneRect: paneRect,
            workArea: workArea,
            onActivate: onActivate,
            onResizeMove: onResizeMove,
            onResizeCommit: onResizeCommit
        )
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

private struct FloatingPaneResizeHandleStrip: NSViewRepresentable {
    let edge: FloatingPaneResizeEdge
    let identifier: String
    let paneRect: CGRect
    let workArea: CGRect
    let onActivate: () -> Void
    let onResizeMove: (CGRect) -> Void
    let onResizeCommit: () -> Void

    func makeNSView(context: Context) -> FloatingPaneResizeHandleNSView {
        let view = FloatingPaneResizeHandleNSView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ nsView: FloatingPaneResizeHandleNSView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: FloatingPaneResizeHandleNSView) {
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel("Resize \(edge.rawValue)")
        view.edge = edge
        view.paneRect = paneRect
        view.workArea = workArea
        view.onActivate = onActivate
        view.onResizeMove = onResizeMove
        view.onResizeCommit = onResizeCommit
        view.window?.invalidateCursorRects(for: view)
    }
}
