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

        // 2. Reference (core.js / app.js / windows.js): panes tile by default. A directed split
        //    from the sole maximized tile returns it to the grid so both tiles are visible;
        //    floating is only the explicit icon, which keeps its own free rect. Surface/PTY stay.
        let (controller, window) = makeLoadedDesktopWindow(canvasWidth: 1000, height: 700)
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        let store = controller.floatingCanvas
        store.lastValidCanvasSize = canvas

        let p1 = try #require(controller.focusedSurface)
        let p1InitialId = p1.id
        let p1InitialPTY = p1.pty
        #expect(store.state(for: p1.id)?.mode == .maximized, "a sole pane starts maximized")
        let soleCard = store.presentedFrame(of: p1.id, in: canvas)

        let p2 = try #require(controller.newSplit(at: p1, direction: .right))
        let p2InitialPTY = p2.pty
        #expect(p1.id == p1InitialId && p1.pty === p1InitialPTY)
        #expect(store.state(for: p1.id)?.mode == .normal && store.isTiled(p1.id), "the maximized tile returns to the grid")
        #expect(store.state(for: p2.id)?.mode == .normal && store.isTiled(p2.id))
        let tiles = store.presentedFrames(in: canvas)
        let f1 = try #require(tiles[p1.id]), f2 = try #require(tiles[p2.id])
        #expect(!f1.intersects(f2) && f1.maxX < f2.minX, "a right split sits beside its anchor")
        #expect(abs(f2.minX - f1.maxX - DesktopCanvasMetrics.paneGap) < 0.5, "tiles are 8 pt apart")
        #expect(f1.minX - area.minX >= DesktopCanvasMetrics.paneGap - 0.5, "tiled normal panes keep the 8 pt inset")
        // A tab's only terminal (maximized) sits in the very card its tiles share: same
        // inset on every side as the grid the tiles were cut from.
        #expect(soleCard == FloatingCanvasStore.gridArea(in: area), "the only terminal keeps the tiles' 8 pt inset")
        #expect(abs(soleCard.minX - f1.minX) < 0.5 && abs(soleCard.minY - f1.minY) < 0.5 && abs(soleCard.maxX - f2.maxX) < 0.5,
                "one terminal and two tiles have the same outer edges")

        // The explicit float icon detaches p2 to a free rect and keeps it across round trips.
        controller.togglePaneFloating(p2, in: canvas)
        #expect(!store.isTiled(p2.id) && store.state(for: p2.id)?.mode == .normal)
        #expect((store.state(for: p2.id)?.zOrder ?? 0) > (store.state(for: p1.id)?.zOrder ?? 0))
        let free = store.presentedFrame(of: p2.id, in: canvas)
        #expect(free.width >= FloatingPaneGeometry.minSize.width && free.height >= FloatingPaneGeometry.minSize.height)
        controller.togglePaneFloating(p2, in: canvas)
        #expect(store.isTiled(p2.id))
        controller.togglePaneFloating(p2, in: canvas)
        #expect(store.presentedFrame(of: p2.id, in: canvas) == free, "the free rect is kept")
        #expect(p2.pty === p2InitialPTY)

        // Maximize on its own: the maximized pane fills the grid -- the same 8 pt inset card
        // as a sole tiled pane, so one terminal looks like one among several.
        controller.togglePaneFloating(p2, in: canvas)
        controller.toggleMaximizeFloatingPane(p1, in: canvas)
        #expect(store.state(for: p1.id)?.mode == .maximized)
        #expect(store.presentedFrame(of: p1.id, in: canvas) == FloatingCanvasStore.gridArea(in: area))
        #expect(p1.pty === p1InitialPTY && p2.pty === p2InitialPTY)

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

    @Test func header28ptZeroMaximizedInsets22ptControlsDisjointFromResizeHandlesAndDiagonalCursors() throws {
        // Reference header 28 pt with a 3 pt top resize strip (DesktopCanvasMetrics).
        #expect(FloatingPaneGeometry.headerHeight == 28)
        #expect(FloatingPaneGeometry.minSize == CGSize(width: 260, height: 150))
        #expect(FloatingPaneGeometry.cornerRadius == 10)
        // One frame for every shown pane: a maximized one (a tab's only terminal) is rounded
        // and outlined exactly as a tiled or floating one.
        #expect(FloatingPaneGeometry.cardRadius(for: .maximized) == 10)
        #expect(FloatingPaneGeometry.cardRadius(for: .normal) == 10)
        #expect(FloatingPaneGeometry.cardRadius(for: .minimized) == 0)
        #expect(FloatingPaneGeometry.shelfCardHeight == 30)
        #expect(FloatingPaneGeometry.shelfBandHeight == 44)
        #expect(FloatingPaneResizeHandlesView.topEdgeHitThickness == 3)
        #expect(FloatingPaneGeometry.bodySize(for: CGRect(x: 0, y: 0, width: 600, height: 400)) == CGSize(width: 600, height: 372))

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

        // The split tiled both (reference grid); maximizing p1 on its own makes it the sole
        // maximized pane: the whole grid, with the 8 pt gutter all round a tiled pane has.
        controller.toggleMaximizeFloatingPane(p1, in: canvas)
        #expect(controller.floatingCanvas.state(for: p1.id)?.mode == .maximized)
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        let p1Key = p1.id.uuidString.lowercased()
        let p2Key = p2.id.uuidString.lowercased()
        let p1Container = try #require(findView(identifier: "FloatingPane-\(p1Key)", in: contentView))
        let p1MaxRect = p1Container.convert(p1Container.bounds, to: nil)
        let gap = DesktopCanvasMetrics.paneGap
        #expect(abs(p1MaxRect.minX - (sidebarWidth + gap)) <= 1.5)
        #expect(abs(p1MaxRect.minY - gap) <= 1.5)
        #expect(abs(p1MaxRect.width - (1000 - 2 * gap)) <= 1.5)
        #expect(abs(p1MaxRect.height - (contentView.bounds.height - 2 * gap)) <= 1.5)

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
                #expect(topOffset >= FloatingPaneResizeHandlesView.topEdgeHitThickness - 0.5,
                        "Button top offset (\(topOffset)) must clear the \(FloatingPaneResizeHandlesView.topEdgeHitThickness)pt top resize strip")
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

    @Test func referenceSidebarTopAlwaysShownSearchEscapeAndPreservedAX() throws {
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

        // Reference A01: a 44 pt header with keys / settings / + icons, the
        // «Filter sessions… ⌘K» field always shown, «All» beside the counters,
        // and the first workspace header at 116 pt from the top.
        #expect(findView(identifier: "SessionSidebarHeader", in: contentView) != nil)
        #expect(findView(identifier: "SessionSidebarKeys", in: contentView) != nil)
        #expect(findView(identifier: "SessionSidebarSettings", in: contentView) != nil)
        #expect(findView(identifier: "SessionSidebarHeaderNewSession", in: contentView) != nil)
        #expect(findView(identifier: "SessionSidebarNewSession", in: contentView) == nil, "no footer in the reference")
        #expect(findView(identifier: "SessionSidebarSearchButton", in: contentView) == nil, "no separate search button")
        let searchField = try #require(findView(identifier: "SessionSidebarSearchField", in: contentView) as? SidebarSearchNSTextField)

        let wsViewIdle = try #require(findView(identifier: "SessionSidebarWorkspace-\(wsName)", in: contentView))
        let idleTopDistance = topDistanceFromWindowContentTop(of: wsViewIdle, in: contentView)
        #expect(idleTopDistance >= 104 && idleTopDistance <= 128,
                "Expected the first workspace about 116pt from the top (reference A01), got \(idleTopDistance)pt")

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
        #expect(findView(identifier: "SessionSidebarSearchField", in: contentView) != nil, "the field stays")
        let wsViewAfterCollapse = try #require(findView(identifier: "SessionSidebarWorkspace-\(wsName)", in: contentView))
        let collapsedTopDistance = topDistanceFromWindowContentTop(of: wsViewAfterCollapse, in: contentView)
        #expect(collapsedTopDistance == idleTopDistance, "clearing does not move the list")

        // The TerminalWindow keeps the same top, SidebarWindowDragRegion & SessionSidebarResizeHandle intact
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
            #expect(termTopDist >= 104 && termTopDist <= 128,
                    "Expected TerminalWindow first workspace about 116pt from top (reference A01), got \(termTopDist)pt")
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
        #expect(ghostView.dotFrame == CGRect(x: 14, y: (FloatingPaneGeometry.headerHeight - 7) / 2, width: 7, height: 7))
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
        let settledBodyHeight = contentView.bounds.height - 2 * DesktopCanvasMetrics.paneGap - FloatingPaneGeometry.headerHeight
        #expect(abs(p2.bounds.height - settledBodyHeight) <= 2,
                "Restored/maximized SurfaceView must mount immediately at settled final height (\(settledBodyHeight)), got \(p2.bounds.height)")

        // Interactive drag immediately cancels any active morph animation
        store.setInteractiveRect(CGRect(x: 120, y: 100, width: 550, height: 420), for: p2.id, in: canvas)
        #expect(store.activeTransition == nil)
    }
}
