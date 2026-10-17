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

/// The session sidebar's width: 280 pt as in the design (4a), dragged wider
/// or narrower by its right edge, remembered across launches.
enum SessionSidebarWidth {
    static let standard: CGFloat = 280
    static let range: ClosedRange<CGFloat> = 260...720
    static let defaultsKey = "TakoSessionSidebarWidth"

    static func clamped(_ width: CGFloat) -> CGFloat {
        min(max(width, range.lowerBound), range.upperBound)
    }

    /// The width the sidebar has now, as the user left it. The terminal
    /// beside it is sized from this; a guess here pushes the terminal's
    /// right edge, its scrollbar with it, out of the window.
    static func current(in defaults: UserDefaults = .tako) -> CGFloat {
        let stored = defaults.object(forKey: defaultsKey) as? Double
        return clamped(stored.map { CGFloat($0) } ?? standard)
    }
}

/// The strip on the sidebar's right edge that changes its width: drag it,
/// double-click it for the standard width. An AppKit view rather than a
/// SwiftUI gesture: the terminal beside the sidebar is an AppKit view too and
/// took every press near the edge, and a SwiftUI hover cursor did not hold
/// against it. The edge lights up in Ember while it can be dragged, as the
/// active row's bar does.
struct SessionSidebarResizeHandle: NSViewRepresentable {
    @Binding var width: Double

    /// 8 pt inside the sidebar, 4 pt over the terminal.
    static let hitWidth: CGFloat = 12
    static let overhang: CGFloat = 4

    func makeNSView(context: Context) -> SessionSidebarGripView {
        let grip = SessionSidebarGripView()
        updateNSView(grip, context: context)
        return grip
    }

    func updateNSView(_ grip: SessionSidebarGripView, context: Context) {
        let binding = $width
        grip.currentWidth = { binding.wrappedValue }
        grip.setWidth = { binding.wrappedValue = $0 }
    }
}

final class SessionSidebarGripView: NSView {
    var currentWidth: () -> Double = { Double(SessionSidebarWidth.standard) }
    var setWidth: (Double) -> Void = { _ in }

    private var dragStart: (mouseX: CGFloat, width: Double)?
    private var isHovered = false
    private let edge = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        edge.backgroundColor = Tako.LivingTokens.ember.cgColor
        edge.opacity = 0
        layer?.addSublayer(edge)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Resize session sidebar")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        // On the sidebar's edge, which is `overhang` from this view's right.
        let x = bounds.width - SessionSidebarResizeHandle.overhang - 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edge.frame = CGRect(x: x, y: 0, width: 2, height: bounds.height)
        CATransaction.commit()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        NSCursor.resizeLeftRight.set()
        light()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        light()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            setWidth(Double(SessionSidebarWidth.standard))
            return
        }
        dragStart = (event.locationInWindow.x, currentWidth())
        NSCursor.resizeLeftRight.set()
        light()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let width = CGFloat(start.width) + event.locationInWindow.x - start.mouseX
        setWidth(Double(SessionSidebarWidth.clamped(width)))
        NSCursor.resizeLeftRight.set()
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        light()
    }

    private func light() {
        let lit = isHovered || dragStart != nil
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.duration = 0.12
        fade.fromValue = edge.presentation()?.opacity ?? edge.opacity
        edge.opacity = lit ? 1 : 0
        edge.add(fade, forKey: "opacity")
    }
}
