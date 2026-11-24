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
import Testing
@testable import Tako

/// The canvas's transform-only motion, kept beside the polish suite it belongs to.
extension FloatingRexPolishTests {
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
            - FloatingPaneGeometry.bodyInsets.top - FloatingPaneGeometry.bodyInsets.bottom
        #expect(abs(p2.bounds.height - settledBodyHeight) <= 2,
                "Restored/maximized SurfaceView must mount immediately at settled final height (\(settledBodyHeight)), got \(p2.bounds.height)")

        // Interactive drag immediately cancels any active morph animation
        store.setInteractiveRect(CGRect(x: 120, y: 100, width: 550, height: 420), for: p2.id, in: canvas)
        #expect(store.activeTransition == nil)
    }
}
