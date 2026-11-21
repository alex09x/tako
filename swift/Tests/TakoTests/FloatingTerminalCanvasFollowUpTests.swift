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
import Testing
@testable import Tako

@Suite(.serialized)
@MainActor
struct FloatingTerminalCanvasFollowUpTests {
    private func findAppKitView(identifier targetId: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == targetId {
            return root
        }
        for subview in root.subviews {
            if let match = findAppKitView(identifier: targetId, in: subview) {
                return match
            }
        }
        return nil
    }

    @Test func preferredNormalRectSurvivesShelfRestoreAndSnapshotRoundTrip() throws {
        let canvas = CGSize(width: 1000, height: 700)
        let app = Tako.App()
        let pA = Tako.SurfaceView(app)
        let pB = Tako.SurfaceView(app)
        var tree = SplitTree<Tako.SurfaceView>(view: pA)
        tree = try tree.inserting(view: pB, at: pA, direction: .right)

        let store = FloatingCanvasStore()
        store.sync(with: tree, fallbackSize: canvas)

        let preferredA = CGRect(x: 8, y: 8, width: 480, height: 684)
        store.setInteractiveRect(preferredA, for: pA.id, in: canvas)
        store.commitInteractiveRect(for: pA.id, in: canvas)
        #expect(store.state(for: pA.id)?.rect == preferredA)

        // Maximize A -> minimize A & B -> snapshot roundtrip while shelf is active ->
        // restore A while B is still minimized (full work area) -> restore B -> toggle A to .normal
        store.toggleMaximize(pA.id, in: canvas)
        store.minimize(pA.id)
        store.minimize(pB.id)

        let encoded = try JSONEncoder().encode(store.snapshot())
        let decoded = try JSONDecoder().decode(FloatingCanvasSnapshot.self, from: encoded)
        let reloaded = FloatingCanvasStore()
        reloaded.loadRestoredSnapshot(decoded, for: tree, fallbackSize: canvas)
        #expect(reloaded.state(for: pA.id)?.rect == preferredA)

        #expect(reloaded.restore(pA.id, in: canvas) == .maximized)
        #expect(reloaded.state(for: pA.id)?.rect == preferredA)

        // B's shelf card does not alter A's preferred or presented geometry.
        reloaded.toggleMaximize(pA.id, in: canvas)
        let clampedPresented = FloatingPaneGeometry.presentedFrame(
            for: try #require(reloaded.state(for: pA.id)),
            in: canvas,
            hasMinimizedPanes: reloaded.hasMinimizedPanes
        )
        #expect(clampedPresented == preferredA)
        #expect(reloaded.state(for: pA.id)?.rect == preferredA)

        #expect(reloaded.restore(pB.id, in: canvas) == .normal)
        let fullPresented = FloatingPaneGeometry.presentedFrame(
            for: try #require(reloaded.state(for: pA.id)),
            in: canvas,
            hasMinimizedPanes: reloaded.hasMinimizedPanes
        )
        #expect(reloaded.state(for: pA.id)?.rect == preferredA)
        #expect(fullPresented == preferredA)
    }

    @Test func cyclicPreviousNextIsRaiseInvariantAndStrictlyTransitive() throws {
        let canvas = CGSize(width: 1000, height: 700)
        let app = Tako.App()
        let pA = Tako.SurfaceView(app)
        let pB = Tako.SurfaceView(app)
        let pC = Tako.SurfaceView(app)
        var tree = SplitTree<Tako.SurfaceView>(view: pA)
        tree = try tree.inserting(view: pB, at: pA, direction: .right)
        tree = try tree.inserting(view: pC, at: pB, direction: .right)

        let store = FloatingCanvasStore()
        store.sync(with: tree, fallbackSize: canvas)
        store.toggleMaximize(pA.id, in: canvas)
        store.toggleMaximize(pB.id, in: canvas)
        store.toggleMaximize(pC.id, in: canvas)

        // All three panes share identical maximized frames; raising on focus must never trap previous/next in a 2-pane loop.
        let step1 = try #require(store.spatialFocusTarget(direction: .previous, from: pC.id, in: canvas))
        store.bringToFront(step1)
        let step2 = try #require(store.spatialFocusTarget(direction: .previous, from: step1, in: canvas))
        store.bringToFront(step2)
        let step3 = try #require(store.spatialFocusTarget(direction: .previous, from: step2, in: canvas))
        #expect(Set([step1, step2, step3]) == Set([pA.id, pB.id, pC.id]))
        #expect(step3 == pC.id)

        // Near-collinear y offsets (0, 5, 10) must still form a strict deterministic cycle with zero zOrder perturbation.
        store.toggleMaximize(pA.id, in: canvas)
        store.toggleMaximize(pB.id, in: canvas)
        store.toggleMaximize(pC.id, in: canvas)
        store.setInteractiveRect(CGRect(x: 500, y: 0, width: 300, height: 250), for: pA.id, in: canvas)
        store.setInteractiveRect(CGRect(x: 300, y: 5, width: 300, height: 250), for: pB.id, in: canvas)
        store.setInteractiveRect(CGRect(x: 100, y: 10, width: 300, height: 250), for: pC.id, in: canvas)
        let n1 = try #require(store.spatialFocusTarget(direction: .next, from: pA.id, in: canvas))
        store.bringToFront(n1)
        let n2 = try #require(store.spatialFocusTarget(direction: .next, from: n1, in: canvas))
        store.bringToFront(n2)
        let n3 = try #require(store.spatialFocusTarget(direction: .next, from: n2, in: canvas))
        #expect(Set([n1, n2, n3]) == Set([pA.id, pB.id, pC.id]))
    }

    @Test func shelfCardsAlignToBottomRightInHostedCanvas() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        let sidebarWidth = SessionSidebarWidth.current()
        window.setContentSize(NSSize(width: 1000 + sidebarWidth, height: 700))
        controller.showWindow(nil)

        let p1 = try #require(controller.focusedSurface)
        let p2 = try #require(controller.newSplit(at: p1, direction: .right))
        let p3 = try #require(controller.newSplit(at: p2, direction: .right))
        controller.minimizeFloatingPane(p1)
        controller.minimizeFloatingPane(p2)

        let contentView = try #require(window.contentView)
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        let c1 = try #require(findAppKitView(identifier: "FloatingMinimizedCard-\(p1.id.uuidString.lowercased())", in: contentView))
        let c2 = try #require(findAppKitView(identifier: "FloatingMinimizedCard-\(p2.id.uuidString.lowercased())", in: contentView))
        let r1 = c1.convert(c1.bounds, to: contentView)
        let r2 = c2.convert(c2.bounds, to: contentView)
        let rightmostMaxX = max(r1.maxX, r2.maxX)
        let expectedMaxX = contentView.bounds.maxX - 12

        #expect(abs(rightmostMaxX - expectedMaxX) <= 6,
                "Expected rightmost shelf card maxX ≈ \(expectedMaxX), got \(rightmostMaxX) (r1=\(r1), r2=\(r2), bounds=\(contentView.bounds))")
        #expect(min(r1.minY, r2.minY) <= 16,
                "Expected shelf cards in bottom 44pt band of AppKit contentView, got r1=\(r1), r2=\(r2)")
        _ = p3
    }

    @Test func forgedExtremeZOrderNormalizesWithoutOverflow() throws {
        let canvas = CGSize(width: 960, height: 640)
        let app = Tako.App()
        let p1 = Tako.SurfaceView(app)
        let p2 = Tako.SurfaceView(app)
        var tree = SplitTree<Tako.SurfaceView>(view: p1)
        tree = try tree.inserting(view: p2, at: p1, direction: .right)

        let forged = FloatingCanvasSnapshot(
            version: 1,
            panes: [
                FloatingPaneState(surfaceId: p1.id, mode: .normal, restoreMode: .normal,
                                  rect: CGRect(x: 20, y: 20, width: 400, height: 300), zOrder: Int.max)
            ]
        )
        let store = FloatingCanvasStore()
        store.loadRestoredSnapshot(forged, for: tree, fallbackSize: canvas)
        store.bringToFront(p1.id)
        store.bringToFront(p2.id)

        let z1 = try #require(store.state(for: p1.id)?.zOrder)
        let z2 = try #require(store.state(for: p2.id)?.zOrder)
        #expect(z2 > z1)
        #expect(z2 < 100)
    }

    @Test func statusColorsUseCanonicalDotKeysAndHeaderMenuDetachesPane() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }

        let p1 = try #require(controller.focusedSurface)
        let workingColor = FloatingPaneGeometry.statusNSColor(for: .working, surface: p1)
        let approvalColor = FloatingPaneGeometry.statusNSColor(for: .needsApproval, surface: p1)
        let doneColor = FloatingPaneGeometry.statusNSColor(for: .done, surface: p1)
        let errorColor = FloatingPaneGeometry.statusNSColor(for: .error, surface: p1)
        let idleColor = FloatingPaneGeometry.statusNSColor(for: .idle, surface: p1)

        #expect(workingColor == Tako.tabStatusColor(for: "ember", surface: p1))
        #expect(approvalColor == Tako.tabStatusColor(for: "claw", surface: p1))
        #expect(doneColor == Tako.tabStatusColor(for: "ok", surface: p1))
        #expect(errorColor == Tako.tabStatusColor(for: "error", surface: p1))
        #expect(idleColor == Tako.tabStatusColor(for: "dim", surface: p1))
        #expect(workingColor != doneColor)
        #expect(errorColor != doneColor)
        #expect(idleColor != doneColor)

        let contentView = try #require(window.contentView)
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        contentView.layoutSubtreeIfNeeded()

        let h1 = try #require(
            findAppKitView(identifier: "FloatingPaneHeader-\(p1.id.uuidString.lowercased())", in: contentView)
                as? FloatingPaneHeaderDragNSView
        )
        let fakeEvent = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let singleMenu = try #require(h1.menu(for: fakeEvent))
        #expect(singleMenu.item(withTitle: "Move Pane to New Window")?.isEnabled == false)

        let p2 = try #require(controller.newSplit(at: p1, direction: .right))
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        contentView.layoutSubtreeIfNeeded()

        let h2 = try #require(
            findAppKitView(identifier: "FloatingPaneHeader-\(p2.id.uuidString.lowercased())", in: contentView)
                as? FloatingPaneHeaderDragNSView
        )
        let splitMenu = try #require(h2.menu(for: fakeEvent))
        let moveItem = try #require(splitMenu.item(withTitle: "Move Pane to New Window"))
        #expect(moveItem.isEnabled == true)
    }
}
