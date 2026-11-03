// tako — Split pane drag handle
// Copyright (c) 2026 Alexander Panasenko
// Contact: alex@prod.codes
// Author: https://prod.codes/about/
// Project: https://github.com/alex09x/tako
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PaneDragHandle: NSViewRepresentable {
    let surfaceView: Tako.SurfaceView
    var draggingChanged: (Bool) -> Void

    func makeNSView(context: Context) -> PaneDragHandleView {
        let view = PaneDragHandleView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: PaneDragHandleView, context: Context) {
        let surface = surfaceView
        view.paneID = surface.id
        view.fillColor = NSColor(cgColor: surface.theme.background) ?? .clear
        view.gripColor = (NSColor(cgColor: surface.theme.foreground) ?? .labelColor).withAlphaComponent(0.25)
        view.draggingChanged = draggingChanged
        view.activate = { [weak surface] in
            if let surface { Tako.moveFocus(to: surface) }
        }
        view.detach = { [weak surface] point in
            guard let surface else { return }
            NotificationCenter.default.post(name: .takoSurfaceDragEndedNoTarget, object: surface,
                userInfo: [Notification.Name.takoSurfaceDragEndedNoTargetPointKey: point])
        }
        view.setAccessibilityIdentifier("pane-drag-handle-\(surface.id)")
        view.needsDisplay = true
    }
}

final class PaneDragHandleView: NSView, NSDraggingSource {
    var paneID = UUID()
    var fillColor = NSColor.clear
    var gripColor = NSColor.labelColor.withAlphaComponent(0.25)
    var activate: () -> Void = {}
    var detach: (NSPoint) -> Void = { _ in }
    var draggingChanged: (Bool) -> Void = { _ in }
    private var start: NSPoint?
    private var dragging = false
    private var cancelled = false
    private var cancelMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Move pane")
        setAccessibilityHelp("Drag onto another pane to move it, or outside the window to detach it. Escape cancels.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func isAccessibilityEnabled() -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        bounds.fill()
        gripColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 12, y: bounds.midY - 1, width: 24, height: 2),
                     xRadius: 1, yRadius: 1).fill()
    }

    override func accessibilityPerformPress() -> Bool {
        activate()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        start = event.locationInWindow
        cancelled = false
        activate()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let start,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 4 else { return }
        let payload = NSPasteboardItem()
        payload.setData(Data(paneID.uuidString.utf8), forType: .init(UTType.takoSurfaceId.identifier))
        let item = NSDraggingItem(pasteboardWriter: payload)
        item.setDraggingFrame(NSRect(x: bounds.midX - 12, y: bounds.midY - 8, width: 24, height: 16),
                              contents: NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil))
        dragging = true
        draggingChanged(true)
        cancelMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancelOperation(nil) }
            return event
        }
        beginDraggingSession(with: [item], event: event, source: self)
            .animatesToStartingPositionsOnCancelOrFail = false
    }

    override func mouseUp(with event: NSEvent) { start = nil }
    override func cancelOperation(_ sender: Any?) { cancelled = true }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if NSApp.currentEvent?.type == .keyDown, NSApp.currentEvent?.keyCode == 53 { cancelled = true }
        completeDrag(at: screenPoint, operation: operation, mouseButtons: NSEvent.pressedMouseButtons)
    }

    func completeDrag(at point: NSPoint, operation: NSDragOperation, mouseButtons: Int) {
        if let cancelMonitor { NSEvent.removeMonitor(cancelMonitor) }
        cancelMonitor = nil
        dragging = false
        start = nil
        draggingChanged(false)
        // No destination accepts an outside drop. Escape also reports .none,
        // so it must be distinguished from a released mouse before detaching.
        if operation.isEmpty, !cancelled, mouseButtons & 1 == 0 { detach(point) }
        cancelled = false
    }
}
