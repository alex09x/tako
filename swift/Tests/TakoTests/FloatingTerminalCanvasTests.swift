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
struct FloatingTerminalCanvasTests {
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

    @Test func singlePaneDefaultsToMaximizedAndPreservesRestoreModeAcrossMinimizeCycles() throws {
        let canvas = CGSize(width: 1000, height: 700)
        let id = UUID()
        let store = FloatingCanvasStore()
        let surface = Tako.SurfaceView(Tako.App())
        let tree = SplitTree<Tako.SurfaceView>(view: surface)
        store.sync(with: tree, fallbackSize: canvas)

        let initial = try #require(store.state(for: surface.id))
        #expect(initial.mode == .maximized)
        #expect(initial.restoreMode == .maximized)
        _ = id

        // Maximize -> Minimize -> Restore returns .maximized
        store.minimize(surface.id)
        #expect(store.state(for: surface.id)?.mode == .minimized)
        #expect(store.state(for: surface.id)?.restoreMode == .maximized)
        #expect(store.restore(surface.id, in: canvas) == .maximized)
        #expect(store.state(for: surface.id)?.mode == .maximized)

        // Toggle to .normal, move & 8-way resize, then Normal -> Minimize -> Restore preserves exact rect
        store.toggleMaximize(surface.id, in: canvas)
        #expect(store.state(for: surface.id)?.mode == .normal)
        let custom = CGRect(x: 84, y: 62, width: 520, height: 360)
        let resized = FloatingPaneResizeEdge.bottomTrailing.applying(
            delta: CGSize(width: 40, height: 30),
            to: custom,
            within: FloatingPaneGeometry.workArea(in: canvas, hasMinimizedPanes: false)
        )
        store.setInteractiveRect(resized, for: surface.id, in: canvas)
        store.commitInteractiveRect(for: surface.id, in: canvas)

        store.minimize(surface.id)
        #expect(store.state(for: surface.id)?.mode == .minimized)
        #expect(store.state(for: surface.id)?.restoreMode == .normal)
        #expect(store.restore(surface.id, in: canvas) == .normal)
        #expect(store.state(for: surface.id)?.rect == CGRect(x: 84, y: 62, width: 560, height: 390))
    }

    @Test func shelfOverlayKeepsFullWorkAreaAndIgnoresZeroCanvasSizes() throws {
        let canvas = CGSize(width: 1000, height: 700)
        let app = Tako.App()
        let a = Tako.SurfaceView(app)
        let b = Tako.SurfaceView(app)
        let tree = try SplitTree<Tako.SurfaceView>(view: a).inserting(view: b, at: a, direction: .right)

        let store = FloatingCanvasStore()
        store.sync(with: tree, fallbackSize: canvas)

        // Without minimized panes, maximized takes the whole 700pt canvas but its 8 pt gutters
        store.toggleMaximize(a.id, in: canvas)
        let fullFrame = FloatingPaneGeometry.presentedFrame(
            for: try #require(store.state(for: a.id)),
            in: canvas,
            hasMinimizedPanes: store.hasMinimizedPanes
        )
        #expect(fullFrame == CGRect(x: 8, y: 8, width: 984, height: 684))

        // The shelf overlays the canvas without shrinking maximized or normal panes.
        store.minimize(b.id)
        #expect(store.hasMinimizedPanes)
        let shelfAwareMax = FloatingPaneGeometry.presentedFrame(
            for: try #require(store.state(for: a.id)),
            in: canvas,
            hasMinimizedPanes: store.hasMinimizedPanes
        )
        #expect(shelfAwareMax == fullFrame)

        store.toggleMaximize(a.id, in: canvas)
        store.setInteractiveRect(CGRect(x: 100, y: 500, width: 500, height: 300), for: a.id, in: canvas)
        let clampedRect = try #require(store.state(for: a.id)).rect
        #expect(clampedRect.maxY == 700)

        // Zero-size GeometryReader passes must never overwrite or corrupt rects
        store.updateCanvasSize(.zero, tree: tree)
        store.setInteractiveRect(CGRect(x: 0, y: 0, width: 10, height: 10), for: a.id, in: .zero)
        #expect(store.state(for: a.id)?.rect == clampedRect)
    }

    @Test func attachDrivenPendingFocusMinimizedPausePolicyAndAllMinimizedReflowPreservation() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        window.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 800), display: false)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)

        let paneA = try #require(controller.focusedSurface)
        let paneB = try #require(controller.newSplit(at: paneA, direction: .right))
        let idA = paneA.id

        // Host A at a known non-zero terminal viewport, then minimize BOTH panes
        let hostA = SurfaceHostingView(surfaceView: paneA)
        hostA.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        window.contentView?.addSubview(hostA)
        hostA.layout()
        let preservedSize = paneA.frame.size
        #expect(preservedSize == CGSize(width: 480, height: 320))

        hostA.removeFromSuperview()
        controller.minimizeFloatingPane(paneA)
        controller.minimizeFloatingPane(paneB)

        #expect(paneA.id == idA)
        #expect(paneA.isPresentationPaused)
        #expect(!paneA.isWindowVisible)
        #expect(Tako.surfaces(in: window).contains(where: { $0 === paneA }))
        #expect((try? ControlLayout.controller(of: paneA)) === controller)

        // Reflow while all panes are minimized must NEVER overwrite minimized PTY frame sizes
        controller.reflowSurfaces(forcePtyResize: true)
        #expect(paneA.frame.size == preservedSize)

        // Request restore on A, then explicitly switch focus to B before A attaches: stale pendingFocus for A is cancelled
        controller.revealAndFocusFloatingPane(paneA, in: CGSize(width: 960, height: 760))
        #expect(controller.floatingCanvas.pendingFocus?.surfaceId == paneA.id)

        let hostB = SurfaceHostingView(surfaceView: paneB)
        hostB.frame = NSRect(x: 500, y: 0, width: 440, height: 320)
        controller.revealAndFocusFloatingPane(paneB, in: CGSize(width: 960, height: 760))
        window.contentView?.addSubview(hostB)
        hostB.layout()
        #expect(window.firstResponder === paneB)

        // Attaching A now must NOT steal firstResponder from B because B superseded A's pendingFocus
        let remountedA = SurfaceHostingView(surfaceView: paneA)
        remountedA.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        window.contentView?.addSubview(remountedA)
        remountedA.layout()
        #expect(window.firstResponder === paneB)

        // Now explicitly focus A via attach-driven path: firstResponder becomes A and pendingFocus is consumed
        remountedA.removeFromSuperview()
        controller.minimizeFloatingPane(paneA)
        controller.revealAndFocusFloatingPane(paneA, in: CGSize(width: 960, height: 760))
        let finalHostA = SurfaceHostingView(surfaceView: paneA)
        finalHostA.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        window.contentView?.addSubview(finalHostA)
        finalHostA.layout()
        #expect(window.firstResponder === paneA)
        #expect(controller.focusedSurface === paneA)
        #expect(controller.floatingCanvas.pendingFocus == nil)
        #expect(paneA.isPresentationPaused == !Tako.SurfaceVisibilityWatch.isShowing(window))
    }

    @Test func emptySessionCanvasKeepsSidebarAliveSupportsNewPaneAndPreservesCloseKeybindSemantics() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        controller.showWindow(nil)

        let initial = try #require(controller.focusedSurface)

        // All-minimized: Cmd+W (`close(_:)`) is disabled and is a safe no-op rather than killing a minimized pane
        controller.minimizeFloatingPane(initial)
        let closeMenu = NSMenuItem(title: "", action: #selector(BaseTerminalController.close(_:)), keyEquivalent: "w")
        #expect(!controller.validateMenuItem(closeMenu))
        controller.close(window)
        #expect(controller.surfaceTree.contains(initial))

        // Restore and close the last visible pane: session remains open on empty canvas with permanent sidebar intact
        controller.revealAndFocusFloatingPane(initial, in: CGSize(width: 900, height: 650))
        controller.close(window)
        #expect(controller.surfaceTree.isEmpty)
        #expect(window.isVisible)
        #expect(controller.sessionSidebarIsShowing)
        #expect(controller.validateMenuItem(closeMenu))
        #expect(closeMenu.title == "Close Session")

        // takoctl tree includes the empty session with its stableTabId and panes == []
        let treeJSON = ControlCommands.tree(ControlCommands.panes(), active: nil)
        let windowsJSON = treeJSON["windows"]?.array ?? []
        let matchingEmptyTab = windowsJSON
            .flatMap { $0.object?["tabs"]?.array ?? [] }
            .first { $0.object?["stableTabId"]?.string == window.stableTabIdentifier }
        #expect(matchingEmptyTab?.object?["panes"]?.array?.isEmpty == true)

        // Creating a new terminal inside the empty session populates a fresh .maximized pane
        let fresh = try #require(controller.createSurfaceInCurrentSession())
        #expect(controller.surfaceTree.contains(fresh))
        #expect(controller.floatingCanvas.state(for: fresh.id)?.mode == .maximized)

        // Closing that pane returns to empty canvas, and a second `close(_:)` (Cmd+W) closes the empty session
        controller.closeFloatingPane(fresh)
        #expect(controller.surfaceTree.isEmpty)
        #expect(window.isVisible)
        controller.close(window)
        #expect(!window.isVisible)
    }

    @Test func restorableStateLayoutJournalMigrationSpatialFocusAndLiveStatusAccessibility() async throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        window.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 800), display: false)
        controller.showWindow(nil)

        let p1 = try #require(controller.focusedSurface)
        let p2 = try #require(controller.newSplit(at: p1, direction: .right))
        let p3 = try #require(controller.newSplit(at: p2, direction: .down))
        let canvas = CGSize(width: 960, height: 720)

        controller.floatingCanvas.setInteractiveRect(CGRect(x: 20, y: 30, width: 420, height: 500), for: p1.id, in: canvas)
        controller.floatingCanvas.setInteractiveRect(CGRect(x: 480, y: 30, width: 420, height: 500), for: p2.id, in: canvas)
        controller.toggleMaximizeFloatingPane(p3, in: canvas)
        controller.minimizeFloatingPane(p3)

        // Spatial focus skips minimized p3 and navigates geometrically between p1 and p2
        #expect(controller.floatingCanvas.spatialFocusTarget(direction: .right, from: p1.id, in: canvas) == p2.id)
        #expect(controller.floatingCanvas.spatialFocusTarget(direction: .left, from: p2.id, in: canvas) == p1.id)

        // Encode TerminalRestorableState into LayoutJournal and verify leaf count + full round-trip
        let stateData = try JSONEncoder().encode(TerminalRestorableState(from: controller))
        let tabObj = try #require(JSONSerialization.jsonObject(with: stateData) as? [String: Any])
        let journalData = try LayoutJournal.encode(.init(
            generation: 7,
            windows: [.init(frame: CGRect(x: 0, y: 0, width: 1200, height: 800), isKey: true, selectedTab: 0, tabs: [tabObj])]
        ))
        #expect(LayoutJournal.check(journalData, expected: 7).0 == .valid)

        let decoded = try JSONDecoder().decode(TerminalRestorableState.self, from: stateData)
        let restoredStore = FloatingCanvasStore()
        restoredStore.loadRestoredSnapshot(decoded.floatingCanvas, for: controller.surfaceTree, fallbackSize: canvas)
        #expect(restoredStore.state(for: p1.id)?.rect == CGRect(x: 20, y: 30, width: 420, height: 500))
        #expect(restoredStore.state(for: p3.id)?.mode == .minimized)
        #expect(restoredStore.state(for: p3.id)?.restoreMode == .maximized)

        // Legacy 2-pane SplitTree with nil floatingCanvas migrates into non-overlapping .normal rects
        let migratedStore = FloatingCanvasStore()
        migratedStore.loadRestoredSnapshot(nil, for: controller.surfaceTree, fallbackSize: canvas)
        #expect(migratedStore.panes.allSatisfy { $0.mode == .normal })

        // Live PaneStatus accessibility on FloatingPaneHeader-<uuid> and FloatingMinimizedCard-<uuid>,
        // plus unmounted minimized SurfaceView and shelf card press-to-restore inside the real TerminalWindow
        p1.crab.setStatus(.working, text: nil)
        p3.crab.setStatus(.working, text: nil)
        let hostView = try #require(window.contentView)
        hostView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        hostView.layoutSubtreeIfNeeded()

        let p1Id = p1.id.uuidString.lowercased()
        let p3Id = p3.id.uuidString.lowercased()
        let paneHeader = try #require(findAppKitView(identifier: "FloatingPaneHeader-\(p1Id)", in: hostView))
        #expect(paneHeader.accessibilityRole() == .group)
        #expect(paneHeader.accessibilityRole() != .window)
        #expect((paneHeader.accessibilityValue() as? String) == "Working")
        #expect(findAppKitView(identifier: "FloatingPaneHeader-\(p3Id)", in: hostView) == nil)
        #expect(p3.superview == nil)

        let cardButton = try #require(findAppKitView(identifier: "FloatingMinimizedCard-\(p3Id)", in: hostView) as? FloatingActionButtonNSView)
        #expect(cardButton.accessibilityRole() == .button)
        #expect(cardButton.isAccessibilityEnabled())
        #expect(cardButton.accessibilityRole() != .window)
        #expect((cardButton.accessibilityValue() as? String) == "Working")

        p1.crab.setStatus(.done, text: nil)
        p3.crab.setStatus(.done, text: nil)
        try await Task.sleep(for: .milliseconds(30))
        hostView.layoutSubtreeIfNeeded()
        #expect((paneHeader.accessibilityValue() as? String) == "Done")
        #expect((cardButton.accessibilityValue() as? String) == "Done")
        #expect(FloatingPaneGeometry.accessibilityStatusValue(for: .needsApproval) == "Needs approval")

        // Pressing minimized shelf card restores p3 to .maximized (preserving restoreMode)
        // and acknowledges CrabTracker's .done -> .idle upon focusing p3
        #expect(cardButton.accessibilityPerformPress() == true)
        try await Task.sleep(for: .milliseconds(30))
        hostView.layoutSubtreeIfNeeded()
        #expect(controller.floatingCanvas.state(for: p3.id)?.mode == .maximized)
        let restoredHeader = try #require(findAppKitView(identifier: "FloatingPaneHeader-\(p3Id)", in: hostView))
        #expect((restoredHeader.accessibilityValue() as? String) == "Idle")
        p3.crab.setStatus(.needsApproval, text: nil)
        try await Task.sleep(for: .milliseconds(30))
        hostView.layoutSubtreeIfNeeded()
        #expect((restoredHeader.accessibilityValue() as? String) == "Needs approval")

        // Close confirmation via X button + Cancel keeps pane alive and restores firstResponder to surface
        SubagentHierarchyStore.shared.registerChild(childId: p2.id, parentId: p3.id, label: "worker")
        defer {
            SubagentHierarchyStore.shared.unregister(paneId: p2.id)
            SubagentHierarchyStore.shared.unregister(paneId: p3.id)
        }
        let closeBtn = try #require(findAppKitView(identifier: "FloatingPaneClose-\(p3Id)", in: hostView) as? FloatingActionButtonNSView)
        _ = window.makeFirstResponder(window)
        #expect(closeBtn.accessibilityPerformPress() == true)
        for _ in 0..<10 where TerminalDialogView.pending(in: window) == nil {
            await Task.yield()
        }
        let dialog = try #require(TerminalDialogView.pending(in: window))
        #expect(dialog.press("Cancel") == true)
        for _ in 0..<10 where window.firstResponder !== p3 {
            await Task.yield()
        }
        #expect(controller.surfaceTree.contains(p3))
        #expect(window.firstResponder === p3)
    }
}
