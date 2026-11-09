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

/// AppKit drag/double-click view for the floating pane header.
/// Setting `mouseDownCanMoveWindow = false` prevents AppKit from dragging the outer `NSWindow`.
final class FloatingPaneHeaderDragNSView: NSView {
    var paneMode: FloatingPaneMode = .normal
    var paneRect: CGRect = .zero
    var canvasSize: CGSize = .zero
    var canMoveToNewWindow = false
    var onHoverChange: ((Bool) -> Void)?
    var onDragStateChange: ((Bool) -> Void)?
    var onActivate: (() -> Void)?
    var onDragMove: ((CGRect) -> Void)?
    var onDetachMaximized: ((CGFloat, CGFloat) -> CGRect?)?
    var onDragCommit: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onMoveToNewWindow: (() -> Void)?
    /// The pane's «Appearance ▸», built when the menu opens.
    var appearanceMenuItem: (() -> NSMenuItem?)?
    /// The pane's own actions, first in the menu, built when it opens.
    var paneMenuItems: (() -> [NSMenuItem])?

    private var trackingAreaRef: NSTrackingArea?
    private var dragStartWindowPoint: NSPoint?
    private var dragStartRect: CGRect = .zero
    private var didDrag = false
    private var pendingMaximizedDetach = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

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
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        if event.clickCount == 2 {
            dragStartWindowPoint = nil
            didDrag = false
            pendingMaximizedDetach = false
            onDragStateChange?(false)
            onDoubleClick?()
            return
        }
        dragStartWindowPoint = event.locationInWindow
        dragStartRect = paneRect
        didDrag = false
        pendingMaximizedDetach = (paneMode == .maximized)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartWindowPoint else { return }
        let current = event.locationInWindow
        let dx = current.x - start.x
        let dy = -(current.y - start.y)

        if pendingMaximizedDetach {
            guard hypot(dx, dy) >= 4 else { return }
            pendingMaximizedDetach = false
            let localInSelf = convert(current, from: nil)
            let sidebarOffset = (window?.contentView?.bounds.width ?? canvasSize.width) - canvasSize.width
            let pointerXInCanvas = max(0, current.x - max(0, sidebarOffset))
            if let detached = onDetachMaximized?(pointerXInCanvas, FloatingPaneGeometry.headerHeight - localInSelf.y) {
                dragStartWindowPoint = current
                dragStartRect = detached
                didDrag = true
                onDragStateChange?(true)
            }
            return
        }

        guard hypot(dx, dy) >= 1 || didDrag else { return }
        if !didDrag {
            didDrag = true
            onDragStateChange?(true)
        }
        let next = CGRect(
            x: (dragStartRect.origin.x + dx).rounded(),
            y: (dragStartRect.origin.y + dy).rounded(),
            width: dragStartRect.width,
            height: dragStartRect.height
        )
        onDragMove?(next)
    }

    override func mouseUp(with event: NSEvent) {
        let shouldCommit = didDrag
        dragStartWindowPoint = nil
        didDrag = false
        pendingMaximizedDetach = false
        onDragStateChange?(false)
        if shouldCommit {
            onDragCommit?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onActivate?()
        let menu = NSMenu()
        menu.autoenablesItems = false
        // Reference header.js winMenu: split, maximize, float, minimize, close.
        if let items = paneMenuItems?(), !items.isEmpty {
            items.forEach(menu.addItem)
            menu.addItem(.separator())
        }
        let moveItem = NSMenuItem(
            title: "Move Pane to New Window",
            action: #selector(movePaneToNewWindowAction(_:)),
            keyEquivalent: ""
        )
        moveItem.target = self
        moveItem.isEnabled = canMoveToNewWindow
        menu.addItem(moveItem)
        if let appearance = appearanceMenuItem?() {
            menu.addItem(.separator())
            menu.addItem(appearance)
        }
        return menu
    }

    @objc private func movePaneToNewWindowAction(_ sender: Any?) {
        guard canMoveToNewWindow else { return }
        onMoveToNewWindow?()
    }
}

struct FloatingPaneHeaderDragStrip: NSViewRepresentable {
    let accessibilityIdentifier: String
    let accessibilityLabel: String
    let accessibilityValue: String
    let paneMode: FloatingPaneMode
    let paneRect: CGRect
    let canvasSize: CGSize
    let canMoveToNewWindow: Bool
    let onHoverChange: (Bool) -> Void
    let onDragStateChange: (Bool) -> Void
    let onActivate: () -> Void
    let onDragMove: (CGRect) -> Void
    let onDetachMaximized: (CGFloat, CGFloat) -> CGRect?
    let onDragCommit: () -> Void
    let onDoubleClick: () -> Void
    let onMoveToNewWindow: () -> Void
    var appearanceMenuItem: (() -> NSMenuItem?)? = nil
    var paneMenuItems: (() -> [NSMenuItem])? = nil

    func makeNSView(context: Context) -> FloatingPaneHeaderDragNSView {
        let view = FloatingPaneHeaderDragNSView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ nsView: FloatingPaneHeaderDragNSView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: FloatingPaneHeaderDragNSView) {
        view.setAccessibilityIdentifier(accessibilityIdentifier)
        view.setAccessibilityLabel(accessibilityLabel)
        view.setAccessibilityValue(accessibilityValue)
        view.paneMode = paneMode
        view.paneRect = paneRect
        view.canvasSize = canvasSize
        view.canMoveToNewWindow = canMoveToNewWindow
        view.onHoverChange = onHoverChange
        view.onDragStateChange = onDragStateChange
        view.onActivate = onActivate
        view.onDragMove = onDragMove
        view.onDetachMaximized = onDetachMaximized
        view.onDragCommit = onDragCommit
        view.onDoubleClick = onDoubleClick
        view.onMoveToNewWindow = onMoveToNewWindow
        view.appearanceMenuItem = appearanceMenuItem
        view.paneMenuItems = paneMenuItems
    }
}
