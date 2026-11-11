/*
 * tako — Free windows remain selected, undocked and above the session grid
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Testing
@testable import Tako

@MainActor @Suite(.serialized)
struct FreeFloatingModeTests {
    private func panes() throws -> (FloatingCanvasStore, [Tako.SurfaceView], SplitTree<Tako.SurfaceView>) {
        let app = Tako.App()
        let a = Tako.SurfaceView(app), b = Tako.SurfaceView(app), c = Tako.SurfaceView(app)
        let tree = try SplitTree<Tako.SurfaceView>(view: a).inserting(view: b, at: a, direction: .right)
            .inserting(view: c, at: b, direction: .down)
        let store = FloatingCanvasStore()
        store.reduceMotionProvider = { true }
        store.sync(with: tree, fallbackSize: CGSize(width: 1000, height: 700))
        return (store, [a, b, c], tree)
    }

    @Test func freeDragRejectsEdgeAndPeerTargetsAndKeepsItsModeOnRelease() throws {
        let (store, panes, _) = try self.panes()
        let id = panes[1].id
        let canvas = CGSize(width: 1000, height: 700)
        store.toggleFloating(id, in: canvas)
        let size = try #require(store.state(for: id)).rect.size
        store.setHeaderDragRect(CGRect(origin: CGPoint(x: -30, y: 60), size: size), for: id, in: canvas)
        #expect(!store.canDockHeaderDrag(id) && !store.isTiled(id))
        let edge = CanvasDropTarget(anchor: nil, side: .left, frame: .zero)
        store.updateHeaderDropTarget(edge, for: id)
        #expect(store.dropTarget == nil)
        let peer = CanvasDropTarget(anchor: panes[0].id, side: .top, frame: .zero)
        store.updateHeaderDropTarget(peer, for: id)
        #expect(store.dropTarget == nil)
        let dragged = store.presentedFrame(of: id, in: canvas)
        #expect(dragged.minX == 0 && dragged.size == size)
        store.finishHeaderDrag(for: id, docked: false)
        store.commitInteractiveRect(for: id, in: canvas)
        #expect(!store.isTiled(id) && store.headerDragSession == nil && store.dropTarget == nil)
        #expect(store.presentedFrame(of: id, in: canvas) == dragged)
    }

    @Test func tiledDragOffersTargetsUntilDropAndRetainsItsPreferredFreeRectWhenDocked() throws {
        let (store, panes, _) = try self.panes()
        let id = panes[1].id, canvas = CGSize(width: 1000, height: 700)
        let preferred = try #require(store.state(for: id)).rect
        let drag = CGRect(x: 40, y: 60, width: 400, height: 300)
        store.setHeaderDragRect(drag, for: id, in: canvas)
        #expect(store.isTiled(id) && store.canDockHeaderDrag(id))
        #expect(store.presentedFrame(of: id, in: canvas) == drag)
        let target = CanvasDropTarget(anchor: panes[0].id, side: .left, frame: .zero)
        store.updateHeaderDropTarget(target, for: id)
        #expect(store.dropTarget == target)
        store.finishHeaderDrag(for: id, docked: true)
        #expect(store.isTiled(id) && store.state(for: id)?.rect == preferred)
        #expect(store.dropTarget == nil && store.headerDragSession == nil)
        store.setHeaderDragRect(drag, for: id, in: canvas)
        store.finishHeaderDrag(for: id, docked: false)
        #expect(!store.isTiled(id), "Releasing a tile outside the grid enters persistent free mode")
    }

    @Test func freeLayerStaysAboveRepeatedGridFocusAndMaximizeAndRaisesWithinItself() throws {
        let (store, panes, tree) = try self.panes()
        let a = panes[0].id, b = panes[1].id, c = panes[2].id
        let canvas = CGSize(width: 1000, height: 700)
        store.toggleFloating(b, in: canvas)
        store.toggleFloating(c, in: canvas)
        for _ in 0..<50 { store.bringToFront(a) }
        #expect(store.visiblePanesSortedByZ.map(\.surfaceId) == [a, b, c])
        store.toggleMaximize(a, in: canvas)
        #expect(store.visiblePanesSortedByZ.last?.surfaceId == c)
        store.bringToFront(b)
        #expect(store.visiblePanesSortedByZ.last?.surfaceId == b)
        let rect = try #require(store.state(for: b)).rect
        store.minimize(b)
        #expect(store.visiblePanesSortedByZ.last?.surfaceId == c)
        _ = store.restore(b, in: canvas)
        #expect(!store.isTiled(b) && store.state(for: b)?.rect == rect)
        #expect(store.visiblePanesSortedByZ.last?.surfaceId == b)
        let restored = FloatingCanvasStore()
        restored.loadRestoredSnapshot(store.snapshot(), for: tree, fallbackSize: canvas)
        restored.bringToFront(a)
        #expect(!restored.isTiled(b) && restored.visiblePanesSortedByZ.last?.surfaceId == b)
    }

    @Test func freeMaximizedDragNeverGainsDockIntentAndModeChangesClearStaleTargets() throws {
        let (store, panes, _) = try self.panes()
        let id = panes[1].id, canvas = CGSize(width: 1000, height: 700)
        store.toggleFloating(id, in: canvas)
        store.toggleMaximize(id, in: canvas)
        store.beginHeaderDrag(for: id)
        let detached = try #require(store.detachMaximizedForDrag(id, pointerXInCanvas: 400, pointerYInHeader: 14, in: canvas))
        // Grabbed 14 pt into the maximized card's header, the pane comes off where that
        // header was: at the card's inset top (8 pt here), not the work area's edge above it.
        let cardTop = FloatingPaneGeometry.gridArea(in: FloatingPaneGeometry.workArea(in: canvas, hasMinimizedPanes: false)).minY
        #expect(cardTop == 8)
        #expect(detached.minY == cardTop)
        #expect(!store.canDockHeaderDrag(id) && !store.isTiled(id))
        store.finishHeaderDrag(for: id, docked: false)
        store.toggleFloating(id, in: canvas)
        store.beginHeaderDrag(for: id)
        store.updateHeaderDropTarget(.init(anchor: nil, side: .right, frame: .zero), for: id)
        #expect(store.dropTarget != nil)
        store.toggleFloating(id, in: canvas)
        #expect(!store.isTiled(id) && store.dropTarget == nil && store.headerDragSession == nil)
    }

    @Test func replacingEnteredTrackingAreaClearsHoverWithoutAnExitEvent() async throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let button = FloatingActionButtonNSView(frame: CGRect(x: 10, y: 10, width: 22, height: 22))
        window.contentView?.addSubview(button)
        var changes: [Bool] = []
        button.onHoverChange = { changes.append($0) }
        let entered = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        button.mouseEntered(with: entered)
        #expect(changes == [true])
        button.updateTrackingAreas()
        try await Task.sleep(for: .milliseconds(40))
        #expect(changes == [true, false], "A hidden/repositioned button cannot retain an entered tracking area's hover")
    }

    @Test func renderedFreeWindowsWinOverlapHitTestingAfterGridFocusAndExposeSelectedToggle() async throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        window.setContentSize(NSSize(width: 1280, height: 700))
        controller.showWindow(nil)
        let a = try #require(controller.focusedSurface)
        let b = try #require(controller.newSplit(at: a, direction: .right))
        let c = try #require(controller.newSplit(at: a, direction: .down))
        controller.floatingCanvas.reduceMotionProvider = { true }
        controller.togglePaneFloating(b)
        controller.togglePaneFloating(c)
        let content = try #require(window.contentView)
        func settle() async {
            content.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(80))
            content.layoutSubtreeIfNeeded()
        }
        func owns(_ surface: Tako.SurfaceView, point: CGPoint) -> Bool {
            guard let hit = window.contentHitTarget(at: point) else { return false }
            return hit === surface || hit.isDescendant(of: surface)
        }
        func find(_ root: NSView, id: String) -> NSView? {
            if root.accessibilityIdentifier() == id { return root }
            return root.subviews.lazy.compactMap { find($0, id: id) }.first
        }
        await settle()
        controller.activateFloatingPane(a)
        await settle()
        let overlap = b.convert(b.bounds, to: nil).intersection(c.convert(c.bounds, to: nil))
        // The two terminals share a region to hit-test in. Each sits in its card's 6 pt
        // side margin, so in this fixture they share 40 pt across: room enough for a point.
        #expect(!overlap.isNull && overlap.width > 20 && overlap.height > 20)
        let point = CGPoint(x: overlap.midX, y: overlap.midY)
        #expect(owns(c, point: point), "The grid cannot cover a free terminal after gaining focus")
        controller.activateFloatingPane(b)
        await settle()
        #expect(owns(b, point: point), "Clicking a free terminal raises it above its free siblings")
        controller.toggleMaximizeFloatingPane(a)
        await settle()
        #expect(owns(b, point: point), "A maximized grid terminal stays below the free layer")
        let toggle = try #require(find(content, id: "FloatingPaneFloat-\(b.id.uuidString.lowercased())"))
        #expect(toggle.isAccessibilitySelected())
        #expect(toggle.accessibilityValue() as? String == "floating")
    }
}
