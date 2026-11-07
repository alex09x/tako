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
import Testing
@testable import Tako

private final class ZoomSpyTerminalWindow: TerminalWindow {
    var zoomCalls = 0
    override func performZoom(_ sender: Any?) {
        zoomCalls += 1
    }
}

private final class DragZoomSpyHiddenWindow: HiddenTitlebarTerminalWindow {
    var dragCalls = 0
    var zoomCalls = 0
    override func performDrag(with event: NSEvent) { dragCalls += 1 }
    override func performZoom(_ sender: Any?) { zoomCalls += 1 }
}

private final class ClickSpyView: NSView {
    var mouseDownCount = 0
    var mouseDraggedCount = 0
    var mouseUpCount = 0
    var rightDownCount = 0
    var rightDraggedCount = 0
    var rightUpCount = 0
    var otherDownCount = 0
    var otherDraggedCount = 0
    var otherUpCount = 0
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { mouseDownCount += 1 }
    override func mouseDragged(with event: NSEvent) { mouseDraggedCount += 1 }
    override func mouseUp(with event: NSEvent) { mouseUpCount += 1 }
    override func rightMouseDown(with event: NSEvent) { rightDownCount += 1 }
    override func rightMouseDragged(with event: NSEvent) { rightDraggedCount += 1 }
    override func rightMouseUp(with event: NSEvent) { rightUpCount += 1 }
    override func otherMouseDown(with event: NSEvent) { otherDownCount += 1 }
    override func otherMouseDragged(with event: NSEvent) { otherDraggedCount += 1 }
    override func otherMouseUp(with event: NSEvent) { otherUpCount += 1 }
}

@Suite(.serialized)
@MainActor
struct PermanentSidebarChromeRoutingTests {
    private func findFirst<T: NSView>(of type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for sub in root.subviews {
            if let found = findFirst(of: type, in: sub) { return found }
        }
        return nil
    }

    @Test func topEdgeMouseEventsRouteBalancedAcrossButtonsAndSidebarDragStripZooms() throws {
        let window = ZoomSpyTerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        Tako.TabBarController.install(in: window)
        defer { window.close() }

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        let dragStrip = SidebarTitlebarDragView(frame: NSRect(x: 0, y: 468, width: 280, height: 32))
        let rightPane = ClickSpyView(frame: NSRect(x: 280, y: 0, width: 620, height: 500))
        root.addSubview(dragStrip)
        root.addSubview(rightPane)
        window.contentView = root
        root.layoutSubtreeIfNeeded()

        // Standard traffic lights remain native hit targets and are never intercepted.
        if let closeButton = window.standardWindowButton(.closeButton) {
            let center = closeButton.convert(NSPoint(x: closeButton.bounds.midX, y: closeButton.bounds.midY), to: nil)
            #expect(window.hitsStandardWindowButton(at: center))
        }

        // Free sidebar header (x=180, y=488 in top 28pt band): double-click zooms the window.
        let headerDoubleDown = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 180, y: 488), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 2, pressure: 1
        ))
        window.sendEvent(headerDoubleDown)
        #expect(window.zoomCalls == 1)

        func postMouse(_ type: NSEvent.EventType, at pt: NSPoint, clicks: Int = 1, seq: Int) throws {
            let isUp = type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp
            let ev = try #require(NSEvent.mouseEvent(
                with: type, location: pt, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: seq, clickCount: clicks, pressure: isUp ? 0 : 1
            ))
            window.sendEvent(ev)
        }

        // Left button: down in top band -> dragged outside top band -> up outside top band; never zooms.
        try postMouse(.leftMouseDown, at: NSPoint(x: 520, y: 490), clicks: 2, seq: 2)
        try postMouse(.leftMouseDragged, at: NSPoint(x: 560, y: 240), clicks: 2, seq: 2)
        try postMouse(.leftMouseUp, at: NSPoint(x: 560, y: 240), clicks: 2, seq: 2)
        #expect((rightPane.mouseDownCount, rightPane.mouseDraggedCount, rightPane.mouseUpCount) == (1, 1, 1))
        #expect(window.zoomCalls == 1, "double-clicking inside top terminal rows must not zoom the window")

        // Right button: down in top band -> dragged outside top band -> up outside top band.
        try postMouse(.rightMouseDown, at: NSPoint(x: 520, y: 490), seq: 3)
        try postMouse(.rightMouseDragged, at: NSPoint(x: 540, y: 220), seq: 3)
        try postMouse(.rightMouseUp, at: NSPoint(x: 540, y: 220), seq: 3)
        #expect((rightPane.rightDownCount, rightPane.rightDraggedCount, rightPane.rightUpCount) == (1, 1, 1))

        // Middle/other button: down in top band -> dragged outside top band -> up outside top band.
        try postMouse(.otherMouseDown, at: NSPoint(x: 520, y: 490), seq: 4)
        try postMouse(.otherMouseDragged, at: NSPoint(x: 550, y: 180), seq: 4)
        try postMouse(.otherMouseUp, at: NSPoint(x: 550, y: 180), seq: 4)
        #expect((rightPane.otherDownCount, rightPane.otherDraggedCount, rightPane.otherUpCount) == (1, 1, 1))
    }

    @Test func hiddenTitlebarWindowDragRegionAndTrackedTitlebarClear() throws {
        TerminalTestSupport.preventQuitting()
        let app = Tako.App()
        let controller = TerminalController(app)
        let window = DragZoomSpyHiddenWindow(
            contentRect: NSRect(x: 80, y: 80, width: 960, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        controller.window = window
        window.awakeFromNib()
        controller.windowDidLoad()
        Tako.TabBarController.install(in: window)
        defer { TerminalTestSupport.tearDown(controller, window) }

        let contentView = try #require(window.contentView)
        contentView.layoutSubtreeIfNeeded()
        #expect(Tako.TabBarController.isInstalled(in: window))
        #expect(!window.isMovable)

        let surfaceView = try #require(findFirst(of: Tako.SurfaceView.self, in: contentView))
        let surfaceRect = surfaceView.convert(surfaceView.bounds, to: contentView)
        #expect(abs(surfaceRect.maxY - contentView.bounds.maxY) < 1)

        let dragRegion = try #require(findFirst(of: SidebarTitlebarDragView.self, in: contentView))
        #expect(dragRegion.accessibilityIdentifier() == "SidebarWindowDragRegion")
        #expect(abs(dragRegion.bounds.height - SessionSidebarChrome.hiddenTitlebarStripHeight) < 0.5)

        for clicks in [1, 2] {
            let ev = try #require(NSEvent.mouseEvent(
                with: .leftMouseDown, location: NSPoint(x: 120, y: 492), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 30 + clicks, clickCount: clicks, pressure: 1
            ))
            window.sendEvent(ev)
        }
        #expect(window.dragCalls == 1)
        #expect(window.zoomCalls == 1)

        let (stdController, stdWindow) = TerminalTestSupport.loaded()
        Tako.TabBarController.install(in: stdWindow)
        defer { TerminalTestSupport.tearDown(stdController, stdWindow) }
        if let themeFrame = stdWindow.contentView?.superview,
           let container = themeFrame.firstDescendant(withClassName: "NSTitlebarContainerView") {
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.red.cgColor
            Tako.TabBarController.refreshAll()
            #expect(container.layer?.backgroundColor == NSColor.clear.cgColor)
        }
    }
}
