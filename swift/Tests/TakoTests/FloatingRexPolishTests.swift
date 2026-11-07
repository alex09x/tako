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
import QuartzCore
import SwiftUI
import Testing
@testable import Tako

@Suite(.serialized)
@MainActor
struct FloatingRexPolishTests {
    private func findView(identifier: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier {
            return root
        }
        for sub in root.subviews {
            if let found = findView(identifier: identifier, in: sub) {
                return found
            }
        }
        return nil
    }

    private func findFirst<T: NSView>(of type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for sub in root.subviews {
            if let found = findFirst(of: type, in: sub) { return found }
        }
        return nil
    }

    private func makeLoadedDesktopWindow(canvasWidth: CGFloat = 1000, height: CGFloat = 700) -> (TerminalController, TerminalWindow) {
        TerminalTestSupport.preventQuitting()
        let app = Tako.App()
        let sidebarWidth = SessionSidebarWidth.current()
        let controller = TerminalController(app, withBaseConfig: nil, withSurfaceTree: nil)
        let window = TerminalWindow(
            contentRect: NSRect(x: 80, y: 80, width: canvasWidth + sidebarWidth, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        controller.window = window
        window.windowController = controller
        controller.windowDidLoad()
        window.setFrame(NSRect(x: 80, y: 80, width: canvasWidth + sidebarWidth, height: height), display: true)
        controller.showWindow(nil)
        return (controller, window)
    }

    @Test func defaultNormalProportionsFreeFloatSplitOverMaximizedAndSavedRectPreservation() throws {
        let canvas = CGSize(width: 1000, height: 700)
        let area = FloatingPaneGeometry.workArea(in: canvas, hasMinimizedPanes: false)

        // 1. Default normal proportions: 55% x 60% centered, 24pt cascade, min-size guards
        let def0 = FloatingPaneGeometry.defaultNormalRect(in: area, cascadeIndex: 0)
        #expect(def0 == CGRect(x: 225, y: 140, width: 550, height: 420))
        let def1 = FloatingPaneGeometry.defaultNormalRect(in: area, cascadeIndex: 1)
        #expect(def1 == CGRect(x: 249, y: 164, width: 550, height: 420))
        let tinyArea = CGRect(x: 0, y: 0, width: 320, height: 220)
        let minGuarded = FloatingPaneGeometry.defaultNormalRect(in: tinyArea, cascadeIndex: 0)
        #expect(minGuarded.width >= FloatingPaneGeometry.minSize.width)
        #expect(minGuarded.height >= FloatingPaneGeometry.minSize.height)

        // 2. Creating a new pane over a .maximized pane preserves background .maximized mode/rect & PTY/UUID
        let (controller, window) = makeLoadedDesktopWindow(canvasWidth: 1000, height: 700)
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        controller.floatingCanvas.lastValidCanvasSize = canvas

        let p1 = try #require(controller.focusedSurface)
        let p1InitialId = p1.id
        let p1InitialPTY = p1.pty
        let p1Before = try #require(controller.floatingCanvas.state(for: p1.id))
        #expect(p1Before.mode == .maximized)

        let p2 = try #require(controller.newSplit(at: p1, direction: .right))
        let p1After = try #require(controller.floatingCanvas.state(for: p1.id))
        let p2State = try #require(controller.floatingCanvas.state(for: p2.id))

        #expect(p1.id == p1InitialId && p1.pty === p1InitialPTY)
        #expect(p1After.mode == .maximized, "Background maximized pane must NOT be turned into 2 tall split tiles")
        #expect(p1After.rect == p1Before.rect)
        #expect(p2State.mode == .normal)
        #expect(p2State.zOrder > p1After.zOrder)
        #expect(p2State.rect == CGRect(x: 225, y: 140, width: 550, height: 420))

        // Splitting from .normal p2 cascades +24pt while p1 still remains .maximized underneath
        let p3 = try #require(controller.newSplit(at: p2, direction: .down))
        let p3State = try #require(controller.floatingCanvas.state(for: p3.id))
        #expect(p3State.mode == .normal)
        #expect(p3State.rect == CGRect(x: 249, y: 164, width: 550, height: 420))
        #expect(controller.floatingCanvas.state(for: p1.id)?.mode == .maximized)

        // 3. Existing saved preferred rects/modes (including valid 260..279 x 150..179 floors) are preserved untouched
        let customSavedRect = CGRect(x: 36, y: 42, width: 780, height: 540)
        let compactSavedRect = CGRect(x: 48, y: 52, width: 264, height: 156)
        let savedSnapshot = FloatingCanvasSnapshot(
            version: 1,
            panes: [
                FloatingPaneState(surfaceId: p1.id, mode: .maximized, restoreMode: .maximized, rect: customSavedRect, zOrder: 1),
                FloatingPaneState(surfaceId: p2.id, mode: .normal, restoreMode: .normal, rect: compactSavedRect, zOrder: 2)
            ]
        )
        let restored = FloatingCanvasStore()
        restored.loadRestoredSnapshot(savedSnapshot, for: controller.surfaceTree, fallbackSize: canvas)
        #expect(restored.state(for: p1.id)?.mode == .maximized)
        #expect(restored.state(for: p1.id)?.rect == customSavedRect)
        #expect(restored.state(for: p2.id)?.mode == .normal)
        #expect(restored.state(for: p2.id)?.rect == compactSavedRect)
    }

    @Test func header32ptZeroMaximizedInsets22ptControlsDisjointFromResizeHandlesAndDiagonalCursors() throws {
        #expect(FloatingPaneGeometry.headerHeight == 32)
        #expect(FloatingPaneGeometry.minSize == CGSize(width: 260, height: 150))
        #expect(FloatingPaneGeometry.cornerRadius == 10)
        #expect(FloatingPaneGeometry.shelfCardHeight == 30)
        #expect(FloatingPaneGeometry.shelfBandHeight == 44)
        #expect(FloatingPaneResizeHandlesView.topEdgeHitThickness == 4)
        #expect(FloatingPaneGeometry.bodySize(for: CGRect(x: 0, y: 0, width: 600, height: 400)) == CGSize(width: 600, height: 368))

        // Real diagonal cursors on all 4 corners (never .crosshair)
        for corner in [FloatingPaneResizeEdge.topLeading, .topTrailing, .bottomLeading, .bottomTrailing] {
            let cursor = FloatingPaneResizeHandlesView.resizeCursor(for: corner)
            #expect(cursor !== NSCursor.crosshair, "Corner \(corner) must use a real diagonal resize cursor, not crosshair")
        }

        let sidebarWidth = SessionSidebarWidth.current()
        let (controller, window) = makeLoadedDesktopWindow(canvasWidth: 1000, height: 700)
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }

        let p1 = try #require(controller.focusedSurface)
        let p2 = try #require(controller.newSplit(at: p1, direction: .right))
        let contentView = try #require(window.contentView)
        let canvas = CGSize(width: 1000, height: contentView.bounds.height)

        // Check maximized p1 is strictly edge-to-edge (0 outer gutters)
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        let p1Key = p1.id.uuidString.lowercased()
        let p2Key = p2.id.uuidString.lowercased()
        let p1Container = try #require(findView(identifier: "FloatingPane-\(p1Key)", in: contentView))
        let p1MaxRect = p1Container.convert(p1Container.bounds, to: nil)
        #expect(abs(p1MaxRect.minX - sidebarWidth) <= 1.5)
        #expect(abs(p1MaxRect.minY - 0) <= 1.5)
        #expect(abs(p1MaxRect.width - 1000) <= 1.5)
        #expect(abs(p1MaxRect.height - contentView.bounds.height) <= 1.5)

        // Position both panes as non-overlapping .normal windows (p1 focused, p2 background)
        controller.floatingCanvas.setInteractiveRect(CGRect(x: 24, y: 30, width: 430, height: 340), for: p1.id, in: canvas)
        controller.floatingCanvas.commitInteractiveRect(for: p1.id, in: canvas)
        controller.floatingCanvas.setInteractiveRect(CGRect(x: 490, y: 60, width: 430, height: 340), for: p2.id, in: canvas)
        controller.floatingCanvas.commitInteractiveRect(for: p2.id, in: canvas)
        controller.activateFloatingPane(p1)

        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        for key in [p1Key, p2Key] {
            let paneView = try #require(findView(identifier: "FloatingPane-\(key)", in: contentView))
            let paneRectInWin = paneView.convert(paneView.bounds, to: nil)

            var controlRects: [CGRect] = []
            for prefix in ["FloatingPaneMinimize-", "FloatingPaneMaximize-", "FloatingPaneClose-"] {
                let btn = try #require(findView(identifier: "\(prefix)\(key)", in: contentView))
                let r = btn.convert(btn.bounds, to: nil)
                #expect(abs(r.width - 22) <= 0.5 && abs(r.height - 22) <= 0.5,
                        "Expected 22x22pt target for \(prefix)\(key), got \(r.size)")
                let topOffset = paneRectInWin.maxY - r.maxY
                #expect(topOffset >= 4.5, "Button top offset (\(topOffset)) must clear 4pt top resize strip")
                if prefix == "FloatingPaneClose-" {
                    let rightGap = paneRectInWin.maxX - r.maxX
                    #expect(rightGap >= 13.5, "Close right gap (\(rightGap)) must clear 12pt corner resize handle")
                }
                controlRects.append(r)
            }

            for edge in FloatingPaneResizeEdge.allCases {
                let handle = try #require(findView(identifier: "FloatingPaneResize-\(edge.rawValue)-\(key)", in: contentView))
                let handleRect = handle.convert(handle.bounds, to: nil)
                for btnRect in controlRects {
                    #expect(!handleRect.intersects(btnRect),
                            "Resize handle \(edge.rawValue) (\(handleRect)) must not overlap header control (\(btnRect))")
                }
            }
        }

        // Dragging FloatingPaneHeaderDragNSView moves internal pane rect without moving outer NSWindow
        let outerWindowFrameBefore = window.frame
        let headerDrag = try #require(findView(identifier: "FloatingPaneHeader-\(p1Key)", in: contentView) as? FloatingPaneHeaderDragNSView)
        let startPt = headerDrag.convert(NSPoint(x: 80, y: 16), to: nil)
        let downEv = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: startPt, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let dragEv = try #require(NSEvent.mouseEvent(
            with: .leftMouseDragged, location: NSPoint(x: startPt.x + 36, y: startPt.y - 24), modifierFlags: [], timestamp: 0.02,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let upEv = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: NSPoint(x: startPt.x + 36, y: startPt.y - 24), modifierFlags: [], timestamp: 0.04,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        headerDrag.mouseDown(with: downEv)
        headerDrag.mouseDragged(with: dragEv)
        headerDrag.mouseUp(with: upEv)

        #expect(controller.floatingCanvas.state(for: p1.id)?.rect.origin == CGPoint(x: 60, y: 54))
        #expect(window.frame == outerWindowFrameBefore, "Dragging a floating pane header must never move outer NSWindow")
    }

    @Test func compactSidebarIdleWorkspaceTopOffsetCollapsibleSearchEscapeAndPreservedAX() throws {
        func topDistanceFromWindowContentTop(of view: NSView, in contentView: NSView) -> CGFloat {
            let r = view.convert(view.bounds, to: contentView)
            return contentView.isFlipped ? r.minY : (contentView.bounds.maxY - r.maxY)
        }

        let scene = WorkspaceSwitchVisualScene()
        defer { scene.tearDown() }
        scene.populate()
        scene.settle()

        let win = scene.sidebarWindow
        win.makeKeyAndOrderFront(nil)
        let contentView = try #require(win.contentView)
        let wsName = scene.main.name

        // Idle state: compact header present, search field collapsed, first workspace <= 72pt from window top
        #expect(findView(identifier: "SessionSidebarHeader", in: contentView) != nil)
        #expect(findView(identifier: "SessionSidebarHeaderNewSession", in: contentView) != nil)
        #expect(findView(identifier: "SessionSidebarNewSession", in: contentView) != nil)
        let searchButton = try #require(findView(identifier: "SessionSidebarSearchButton", in: contentView) as? FloatingActionButtonNSView)
        #expect(searchButton.accessibilityLabel() == "Search sessions")
        #expect(findView(identifier: "SessionSidebarAttentionToggle", in: contentView) != nil)
        #expect(findView(identifier: "SessionSidebarSearchField", in: contentView) == nil,
                "Search editor must stay collapsed in idle when query and filters are empty")

        let wsViewIdle = try #require(findView(identifier: "SessionSidebarWorkspace-\(wsName)", in: contentView))
        let idleTopDistance = topDistanceFromWindowContentTop(of: wsViewIdle, in: contentView)
        #expect(idleTopDistance > 0 && idleTopDistance <= 72,
                "Expected idle first workspace top <= 72pt from window top, got \(idleTopDistance)pt")

        // Expanding search via header Search button reveals Filter sessions field & segments and focuses the field
        #expect(searchButton.accessibilityPerformPress() == true)
        scene.settle()
        let searchField = try #require(findView(identifier: "SessionSidebarSearchField", in: contentView) as? SidebarSearchNSTextField)

        // Typing query updates filter for targetWindow; real Escape key press in field editor clears & collapses back to idle
        _ = win.makeFirstResponder(searchField)
        if let editor = win.firstResponder as? NSTextView {
            editor.insertText("Legal", replacementRange: NSRange(location: 0, length: 0))
        } else {
            searchField.stringValue = "Legal"
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: searchField)
        }
        scene.settle()
        #expect(scene.store.filterText(for: scene.anchor) == "Legal")

        let escDown = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: win.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))
        win.sendEvent(escDown)
        scene.settle()
        #expect(scene.store.filterText(for: scene.anchor).isEmpty)
        #expect(findView(identifier: "SessionSidebarSearchField", in: contentView) == nil)
        let wsViewAfterCollapse = try #require(findView(identifier: "SessionSidebarWorkspace-\(wsName)", in: contentView))
        let collapsedTopDistance = topDistanceFromWindowContentTop(of: wsViewAfterCollapse, in: contentView)
        #expect(collapsedTopDistance > 0 && collapsedTopDistance <= 72)

        // Verify full TerminalWindow also keeps idle top <= 72pt, SidebarWindowDragRegion & SessionSidebarResizeHandle intact
        let (controller, termWin) = makeLoadedDesktopWindow(canvasWidth: 900, height: 640)
        defer { termWin.close(); TerminalTestSupport.tearDown(controller, termWin) }
        let termContent = try #require(termWin.contentView)
        termContent.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        termContent.layoutSubtreeIfNeeded()
        #expect(controller.sessionSidebarIsShowing)
        #expect(findFirst(of: SidebarTitlebarDragView.self, in: termContent) != nil)
        #expect(findFirst(of: SessionSidebarGripView.self, in: termContent) != nil)
        if let termWs = findView(identifier: "SessionSidebarWorkspace-\(WorkspaceStore.shared.activeWorkspace.name)", in: termContent) {
            let termWsInWin = termWs.convert(termWs.bounds, to: nil)
            let termTopDist = termWin.frame.height - termWsInWin.maxY
            #expect(termTopDist > 0 && termTopDist <= 72,
                    "Expected TerminalWindow idle first workspace <= 72pt from top, got \(termTopDist)pt")
        }
    }

    @Test func transformOnlyMotionRespectsReduceMotionCancelsRapidGenerationsAndPreservesSingleSurfaceFocusAndPTY() throws {
        let (controller, window) = makeLoadedDesktopWindow(canvasWidth: 1000, height: 700)
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        window.makeKeyAndOrderFront(nil)

        let store = controller.floatingCanvas
        let canvas = CGSize(width: 1000, height: 700)
        store.lastValidCanvasSize = canvas

        let p1 = try #require(controller.focusedSurface)
        let p2 = try #require(controller.newSplit(at: p1, direction: .right))
        let initialP2PTY = p2.pty
        let p2Key = p2.id.uuidString.lowercased()
        let contentView = try #require(window.contentView)

        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        contentView.layoutSubtreeIfNeeded()

        // 1. Reduce Motion == true: zero transitions & zero CALayer morph animations
        store.reduceMotionProvider = { true }
        controller.minimizeFloatingPane(p2)
        #expect(store.activeTransition == nil)
        controller.revealAndFocusFloatingPane(p2, in: canvas)
        #expect(store.activeTransition == nil)
        controller.toggleMaximizeFloatingPane(p2, in: canvas)
        #expect(store.activeTransition == nil)

        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        contentView.layoutSubtreeIfNeeded()
        let p2ContainerRM = try #require(findView(identifier: "FloatingPane-\(p2Key)", in: contentView))
        #expect(p2ContainerRM.layer?.animation(forKey: FloatingCanvasMotion.layerAnimationKey) == nil)

        // 2. Reduce Motion == false: transform-only 190ms transitions + rapid cancellation safety
        store.reduceMotionProvider = { false }
        controller.toggleMaximizeFloatingPane(p2, in: canvas) // maximized -> normal
        let gen1 = try #require(store.activeTransition?.generation)
        #expect(store.activeTransition?.kind == .modeMorph)

        // Outgoing minimize ghost mounts at 1:1 unstretched departing rect (10pt/32pt/11pt/7pt) and animates Identity -> shelf
        let p2NormalFrame = try #require(store.activeTransition?.toRect)
        controller.minimizeFloatingPane(p2)
        let gen2 = try #require(store.activeTransition?.generation)
        #expect(gen2 > gen1 && store.activeTransition?.kind == .minimizing)
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        contentView.layoutSubtreeIfNeeded()
        let ghostView = try #require(findFirst(of: FloatingPaneGhostNSView.self, in: contentView))
        #expect(ghostView.bounds.size == p2NormalFrame.size,
                "Ghost model bounds must match departing pane size (\(p2NormalFrame.size)), not 168x30 shelf pill")
        #expect(ghostView.cardCornerRadius == FloatingPaneGeometry.cornerRadius)
        #expect(ghostView.headerHeightUsed == FloatingPaneGeometry.headerHeight)
        #expect(ghostView.dotFrame == CGRect(x: 14, y: 12.5, width: 7, height: 7))
        #expect(ghostView.titleFontSize == 11)

        // Rapid sequence: minimize -> restore -> toggleMaximize cancels prior generations cleanly
        controller.revealAndFocusFloatingPane(p2, in: canvas)
        let gen3 = try #require(store.activeTransition?.generation)
        #expect(gen3 > gen2 && store.activeTransition?.kind == .restoring)

        controller.toggleMaximizeFloatingPane(p2, in: canvas)
        let gen4 = try #require(store.activeTransition?.generation)
        #expect(gen4 > gen3 && store.activeTransition?.kind == .modeMorph)

        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        contentView.layoutSubtreeIfNeeded()

        // Single live SurfaceView instance, unchanged PTY, settled final frame (zero intermediate grid shrink), and focus intact
        let p2Container = try #require(findView(identifier: "FloatingPane-\(p2Key)", in: contentView))
        #expect(p2Container.layer?.animation(forKey: FloatingCanvasMotion.layerAnimationKey) != nil)
        #expect(p2.pty === initialP2PTY)
        #expect(controller.focusedSurface === p2)
        #expect(p2.window === window)
        let settledBodyHeight = contentView.bounds.height - FloatingPaneGeometry.headerHeight
        #expect(abs(p2.bounds.height - settledBodyHeight) <= 2,
                "Restored/maximized SurfaceView must mount immediately at settled final height (\(settledBodyHeight)), got \(p2.bounds.height)")

        // Interactive drag immediately cancels any active morph animation
        store.setInteractiveRect(CGRect(x: 120, y: 100, width: 550, height: 420), for: p2.id, in: canvas)
        #expect(store.activeTransition == nil)
    }
}
